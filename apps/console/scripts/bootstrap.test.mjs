import { createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createServer } from "node:http";
import { test } from "node:test";
import assert from "node:assert/strict";
import postgres from "postgres";
import {
  bootstrapStatus,
  claimBootstrap,
  hashSecret,
  initialiseBootstrap,
  signServiceAssertion,
} from "./bootstrap.mjs";

const TEST_SECRET = "test-bootstrap-hmac-secret-at-least-32-bytes";
const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const migrations = [
  "0000_init.sql",
  "0001_auth_membership_constraints.sql",
  "0002_account_issuer.sql",
  "0003_secure_bootstrap.sql",
];

async function resetThrough(sql, selectedMigrations) {
  await sql.unsafe("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
  for (const migration of selectedMigrations) {
    const source = await readFile(
      new URL(`../drizzle/${migration}`, import.meta.url),
      "utf8",
    );
    for (const statement of source.split("--> statement-breakpoint")) {
      if (statement.trim()) await sql.unsafe(statement);
    }
  }
}

function decodeAssertion(value) {
  const [payload, signature] = value.split(".");
  assert.ok(payload && signature);
  const expected = createHmac("sha256", TEST_SECRET)
    .update(payload)
    .digest("base64url");
  assert.equal(signature, expected);
  return JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
}

test("service assertions bind actor, audience, action, lifetime, and nonce", () => {
  const assertion = signServiceAssertion({
    organisationId: "75cafc98-6f14-476f-b349-7d7e41df1cab",
    action: "bootstrap.prepare",
    actorEmail: "owner@example.test",
    now: 1_800_000_000,
    jti: "f39ce5f5-7605-410d-854b-a98f187134f9",
    secret: TEST_SECRET,
  });
  assert.deepEqual(decodeAssertion(assertion), {
    sub: "operator-cli",
    org_id: "75cafc98-6f14-476f-b349-7d7e41df1cab",
    role: "service",
    name: "BlakTail operator",
    email: "owner@example.test",
    iss: "blaktail-console",
    aud: "blaktail-coord",
    iat: 1_800_000_000,
    exp: 1_800_000_060,
    jti: "f39ce5f5-7605-410d-854b-a98f187134f9",
    action: "bootstrap.prepare",
  });
});

test("secret hashes are deterministic without retaining source material", () => {
  const source = "btb_do-not-store-this-value";
  assert.equal(hashSecret(source), hashSecret(source));
  assert.equal(hashSecret(source).length, 64);
  assert.equal(hashSecret(source).includes(source), false);
});

test(
  "concurrent bootstrap claims create one owner, lock once, and reject replay",
  { skip: !TEST_DATABASE_URL },
  async () => {
    const sql = postgres(TEST_DATABASE_URL, {
      max: 10,
      prepare: false,
      onnotice: () => {},
    });
    const coordinatorRequests = [];
    let expireNextClaim = false;
    let failNextPreparation = false;
    const server = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      const authorization = request.headers.authorization ?? "";
      const claims = decodeAssertion(authorization.replace(/^Bearer\s+/u, ""));
      let id;
      let name;
      let status;
      if (request.url === "/v1/orgs") {
        const body = JSON.parse(raw);
        id = body.id;
        name = body.name;
        status = 202;
        assert.equal(claims.action, "bootstrap.prepare");
        if (failNextPreparation) {
          failNextPreparation = false;
          response.writeHead(503, { "content-type": "application/json" });
          response.end(JSON.stringify({ error: "temporary coordinator failure" }));
          return;
        }
        if (expireNextClaim) {
          expireNextClaim = false;
          await sql`
            UPDATE bootstrap_state
            SET token_expires_at = now() - interval '1 second'
            WHERE id = 'primary'
          `;
        }
      } else {
        const match = request.url?.match(
          /^\/v1\/orgs\/([^/]+)\/bootstrap-commit$/u,
        );
        assert.ok(match);
        id = match[1];
        name = "BlakPath Test";
        status = 201;
        assert.equal(claims.action, "bootstrap.commit");
      }
      assert.equal(claims.org_id, id);
      coordinatorRequests.push({ action: claims.action, id });
      response.writeHead(status, {
        "content-type": "application/json",
      });
      response.end(JSON.stringify({ id, name }));
    });

    await resetThrough(sql, migrations);
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const address = server.address();
    assert.ok(address && typeof address === "object");
    process.env.COORD_BASE_URL = `http://127.0.0.1:${address.port}`;
    process.env.BLAKTAIL_AUTH_HMAC_SECRET = TEST_SECRET;

    try {
      const token = "btb_test-concurrent-claim-token-with-enough-entropy";
      const password = "test-password-not-for-production";
      await initialiseBootstrap(sql, { token, ttlSeconds: 600 });
      const input = {
        token,
        password,
        email: "first.owner@example.test",
        ownerName: "First Owner",
        organisationName: "BlakPath Test",
      };
      const claims = await Promise.allSettled([
        claimBootstrap(sql, input),
        claimBootstrap(sql, input),
      ]);
      const claimResults = claims.map((result) =>
        result.status === "fulfilled"
          ? "fulfilled"
          : result.reason instanceof Error
            ? result.reason.message
            : "unknown rejection",
      );
      assert.equal(
        claims.filter((result) => result.status === "fulfilled").length,
        1,
        JSON.stringify(claimResults),
      );
      assert.equal(
        claims.filter((result) => result.status === "rejected").length,
        1,
      );

      const [counts] = await sql`
      SELECT
        (SELECT count(*)::int FROM "user") AS users,
        (SELECT count(*)::int FROM account) AS accounts,
        (SELECT count(*)::int FROM organisation) AS organisations,
        (SELECT count(*)::int FROM membership WHERE role = 'owner') AS owners
    `;
      assert.deepEqual(
        {
          users: counts.users,
          accounts: counts.accounts,
          organisations: counts.organisations,
          owners: counts.owners,
        },
        { users: 1, accounts: 1, organisations: 1, owners: 1 },
      );
      const status = await bootstrapStatus(sql);
      assert.equal(status.status, "locked");
      assert.equal(status.orphanedOrganisations.length, 0);
      await assert.rejects(
        () => claimBootstrap(sql, input),
        /consumed or invalid/u,
      );

      const audit =
        await sql`SELECT * FROM console_audit_event ORDER BY created_at, id`;
      const serializedAudit = JSON.stringify(audit);
      assert.equal(serializedAudit.includes(token), false);
      assert.equal(serializedAudit.includes(password), false);
      assert.ok(audit.some((event) => event.action === "bootstrap.created"));
      assert.ok(audit.some((event) => event.action === "bootstrap.completed"));
      assert.ok(
        audit
          .filter((event) => event.action.startsWith("bootstrap."))
          .every((event) => event.organisation_id !== null),
      );
      assert.ok(coordinatorRequests.length >= 1);

      await resetThrough(sql, migrations);
      const expiringToken = "btb_test-expiring-during-provisioning-token";
      await initialiseBootstrap(sql, { token: expiringToken, ttlSeconds: 600 });
      expireNextClaim = true;
      await assert.rejects(
        () =>
          claimBootstrap(sql, {
            ...input,
            token: expiringToken,
            email: "expired.owner@example.test",
          }),
        /consumed or state changed/u,
      );
      const [expiredState] = await sql`
        SELECT status,
          (SELECT count(*)::int FROM account) AS accounts,
          (SELECT count(*)::int FROM "user") AS users,
          (SELECT count(*)::int FROM organisation) AS organisations,
          (SELECT count(*)::int FROM membership) AS memberships
        FROM bootstrap_state WHERE id = 'primary'
      `;
      assert.equal(expiredState.status, "provisioning");
      assert.equal(expiredState.accounts, 0);
      assert.equal(expiredState.users, 0);
      assert.equal(expiredState.organisations, 0);
      assert.equal(expiredState.memberships, 0);

      await resetThrough(sql, migrations);
      const retryToken = "btb_test-retry-after-coordinator-failure-token";
      await initialiseBootstrap(sql, { token: retryToken, ttlSeconds: 600 });
      const retryInput = {
        ...input,
        token: retryToken,
        email: "retry.owner@example.test",
      };
      failNextPreparation = true;
      await assert.rejects(
        () => claimBootstrap(sql, retryInput),
        /preparation failed with HTTP 503/u,
      );
      const [beforeRetry] = await sql`
        SELECT
          (SELECT count(*)::int FROM "user") AS users,
          (SELECT count(*)::int FROM organisation) AS organisations,
          (SELECT count(*)::int FROM membership) AS memberships,
          (SELECT count(*)::int FROM account) AS accounts
      `;
      assert.deepEqual(beforeRetry, {
        users: 0,
        organisations: 0,
        memberships: 0,
        accounts: 0,
      });
      await claimBootstrap(sql, retryInput);
      assert.equal((await bootstrapStatus(sql)).status, "locked");
    } finally {
      await new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
      await sql.end({ timeout: 5 });
    }
  },
);

test(
  "migration locks existing owners and reports ownerless organisations",
  { skip: !TEST_DATABASE_URL },
  async () => {
    const sql = postgres(TEST_DATABASE_URL, {
      max: 1,
      prepare: false,
      onnotice: () => {},
    });
    try {
      await resetThrough(sql, migrations.slice(0, 3));
      await sql`
        INSERT INTO organisation (id, name, coord_org_id)
        VALUES ('ownerless-org', 'Ownerless Organisation',
          '73bb4e5b-c676-4d3d-8f08-25f5361093df')
      `;
      const secureMigration = await readFile(
        new URL("../drizzle/0003_secure_bootstrap.sql", import.meta.url),
        "utf8",
      );
      for (const statement of secureMigration.split("--> statement-breakpoint")) {
        if (statement.trim()) await sql.unsafe(statement);
      }
      const ownerlessStatus = await bootstrapStatus(sql);
      assert.equal(ownerlessStatus.status, "uninitialised");
      assert.equal(ownerlessStatus.orphanedOrganisations.length, 1);

      await resetThrough(sql, migrations.slice(0, 3));
      await sql`
        INSERT INTO "user" (id, name, email, email_verified)
        VALUES ('existing-owner', 'Existing Owner', 'existing@example.test', true)
      `;
      await sql`
        INSERT INTO organisation (id, name, coord_org_id)
        VALUES ('existing-org', 'Existing Organisation',
          'fe369171-67b0-4531-a663-fe8076193dca')
      `;
      await sql`
        INSERT INTO membership (id, organisation_id, user_id, role)
        VALUES ('existing-membership', 'existing-org', 'existing-owner', 'owner')
      `;
      for (const statement of secureMigration.split("--> statement-breakpoint")) {
        if (statement.trim()) await sql.unsafe(statement);
      }
      const ownedStatus = await bootstrapStatus(sql);
      assert.equal(ownedStatus.status, "locked");
      assert.equal(ownedStatus.orphanedOrganisations.length, 0);
      await assert.rejects(() => initialiseBootstrap(sql), /already locked/u);

      await sql`
        UPDATE bootstrap_state
        SET status = 'uninitialised', locked_at = NULL
        WHERE id = 'primary'
      `;
      await assert.rejects(
        () => initialiseBootstrap(sql),
        /existing owner detected/u,
      );
      const repairedStatus = await bootstrapStatus(sql);
      assert.equal(repairedStatus.status, "locked");
    } finally {
      await sql.end({ timeout: 5 });
    }
  },
);

test(
  "bootstrap claim attempts are rate limited before secret verification",
  { skip: !TEST_DATABASE_URL },
  async () => {
    const sql = postgres(TEST_DATABASE_URL, {
      max: 1,
      prepare: false,
      onnotice: () => {},
    });
    try {
      await resetThrough(sql, migrations);
      await initialiseBootstrap(sql, {
        token: "btb_rate-limit-valid-token",
        ttlSeconds: 600,
      });
      const invalidClaim = {
        token: "btb_rate-limit-invalid-token",
        password: "rate-limit-test-password",
        email: "rate.limit@example.test",
        ownerName: "Rate Limit Test",
        organisationName: "Rate Limit Test",
      };
      for (let attempt = 0; attempt < 10; attempt += 1) {
        await assert.rejects(
          () => claimBootstrap(sql, invalidClaim),
          /expired, or invalid/u,
        );
      }
      await assert.rejects(
        () => claimBootstrap(sql, invalidClaim),
        /too many bootstrap claim attempts/u,
      );
    } finally {
      await sql.end({ timeout: 5 });
    }
  },
);
