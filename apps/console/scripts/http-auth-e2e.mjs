#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import postgres from "postgres";
import {
  claimBootstrap,
  initialiseBootstrap,
} from "./bootstrap.mjs";

const databaseUrl = process.env.TEST_DATABASE_URL;
if (!databaseUrl) throw new Error("TEST_DATABASE_URL is required");
const hmacSecret = "test-http-auth-hmac-secret-at-least-32-bytes";
const authSecret = "test-http-better-auth-secret-at-least-32-bytes";
const owner = {
  email: "owner.http@example.test",
  name: "HTTP Test Owner",
  password: "owner-http-test-password",
  organisation: "BlakPath HTTP Test",
};
const migrations = [
  "0000_init.sql",
  "0001_auth_membership_constraints.sql",
  "0002_account_issuer.sql",
  "0003_secure_bootstrap.sql",
];

async function listen(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return address.port;
}

async function close(server) {
  if (!server.listening) return;
  await new Promise((resolve, reject) =>
    server.close((error) => (error ? reject(error) : resolve())),
  );
}

async function resetDatabase(sql) {
  await sql.unsafe("DROP SCHEMA public CASCADE; CREATE SCHEMA public");
  for (const migration of migrations) {
    const source = await readFile(
      new URL(`../drizzle/${migration}`, import.meta.url),
      "utf8",
    );
    for (const statement of source.split("--> statement-breakpoint")) {
      if (statement.trim()) await sql.unsafe(statement);
    }
  }
}

function cookies(response) {
  const values = response.headers.getSetCookie?.() ?? [];
  const source = values.length ? values : [response.headers.get("set-cookie") ?? ""];
  return source
    .filter(Boolean)
    .map((value) => value.split(";", 1)[0])
    .join("; ");
}

async function jsonRequest(baseUrl, path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method ?? "POST",
    headers: {
      origin: options.origin ?? baseUrl,
      "content-type": "application/json",
      ...(options.cookie ? { cookie: options.cookie } : {}),
    },
    body: options.body === undefined ? undefined : JSON.stringify(options.body),
    redirect: "manual",
  });
  let body = null;
  try {
    body = await response.json();
  } catch {
    // Empty 204 responses are expected.
  }
  return { response, body };
}

async function waitForConsole(baseUrl, child, log) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`console exited early: ${log.value.slice(-2000)}`);
    }
    try {
      const response = await fetch(`${baseUrl}/sign-in`);
      if (response.status === 200) return;
    } catch {
      // Startup race.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`console did not become ready: ${log.value.slice(-2000)}`);
}

async function stopChild(child) {
  if (child.exitCode !== null) return;
  child.kill("SIGTERM");
  await Promise.race([
    new Promise((resolve) => child.once("exit", resolve)),
    new Promise((resolve) => setTimeout(resolve, 5000)),
  ]);
  if (child.exitCode === null) child.kill("SIGKILL");
}

const sql = postgres(databaseUrl, {
  max: 10,
  prepare: false,
  onnotice: () => {},
});
const coordinator = createServer(async (request, response) => {
  let raw = "";
  for await (const chunk of request) raw += chunk;
  if (request.url === "/v1/orgs") {
    const body = JSON.parse(raw);
    response.writeHead(202, { "content-type": "application/json" });
    response.end(JSON.stringify({ id: body.id, name: body.name }));
    return;
  }
  const match = request.url?.match(
    /^\/v1\/orgs\/([^/]+)\/bootstrap-commit$/u,
  );
  assert.ok(match);
  response.writeHead(201, { "content-type": "application/json" });
  response.end(JSON.stringify({ id: match[1], name: owner.organisation }));
});
let consoleProcess;
const consoleLog = { value: "" };

try {
  await resetDatabase(sql);
  const coordinatorPort = await listen(coordinator);
  process.env.COORD_BASE_URL = `http://127.0.0.1:${coordinatorPort}`;
  process.env.BLAKTAIL_AUTH_HMAC_SECRET = hmacSecret;
  const bootstrapToken = "btb_http-e2e-token-never-written-to-database";
  await initialiseBootstrap(sql, { token: bootstrapToken, ttlSeconds: 600 });
  await claimBootstrap(sql, {
    token: bootstrapToken,
    password: owner.password,
    email: owner.email,
    ownerName: owner.name,
    organisationName: owner.organisation,
  });

  const probe = createServer();
  const consolePort = await listen(probe);
  await close(probe);
  const baseUrl = `http://127.0.0.1:${consolePort}`;
  const nextBinary = new URL("../node_modules/next/dist/bin/next", import.meta.url);
  consoleProcess = spawn(process.execPath, [nextBinary.pathname, "start", "-H", "127.0.0.1", "-p", String(consolePort)], {
    cwd: new URL("..", import.meta.url),
    env: {
      ...process.env,
      NODE_ENV: "production",
      DATABASE_URL: databaseUrl,
      BETTER_AUTH_SECRET: authSecret,
      BETTER_AUTH_URL: baseUrl,
      BETTER_AUTH_TRUSTED_ORIGINS: baseUrl,
      COORD_BASE_URL: process.env.COORD_BASE_URL,
      BLAKTAIL_AUTH_HMAC_SECRET: hmacSecret,
      NEXT_TELEMETRY_DISABLED: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (const stream of [consoleProcess.stdout, consoleProcess.stderr]) {
    stream.on("data", (chunk) => {
      consoleLog.value = (consoleLog.value + chunk.toString()).slice(-20_000);
    });
  }
  await waitForConsole(baseUrl, consoleProcess, consoleLog);

  const signup = await jsonRequest(baseUrl, "/api/auth/sign-up/email", {
    body: {
      email: "public.signup@example.test",
      name: "Public Signup",
      password: "public-signup-password",
    },
  });
  assert.equal(signup.response.status, 400);
  assert.match(JSON.stringify(signup.body), /EMAIL_PASSWORD_SIGN_UP_DISABLED|not enabled/u);

  const ownerSignIn = await jsonRequest(baseUrl, "/api/auth/sign-in/email", {
    body: { email: owner.email, password: owner.password },
  });
  assert.equal(ownerSignIn.response.status, 200, JSON.stringify(ownerSignIn.body));
  const ownerCookie = cookies(ownerSignIn.response);
  assert.match(ownerCookie, /better-auth\.session_token/u);
  const ownerContext = await fetch(`${baseUrl}/api/invitations`, {
    headers: { cookie: ownerCookie },
    redirect: "manual",
  });
  assert.equal(
    ownerContext.status,
    200,
    `owner context failed: ${await ownerContext.text()}`,
  );

  const crossOrigin = await jsonRequest(baseUrl, "/api/invitations", {
    cookie: ownerCookie,
    origin: "https://attacker.example",
    body: { email: "member@example.test", role: "member" },
  });
  assert.equal(crossOrigin.response.status, 403);

  const created = await jsonRequest(baseUrl, "/api/invitations", {
    cookie: ownerCookie,
    body: { email: "member@example.test", role: "member" },
  });
  assert.equal(
    created.response.status,
    201,
    `${JSON.stringify(created.body)}\n${consoleLog.value.slice(-3000)}`,
  );
  const invitationUrl = new URL(created.body.url);
  const invitationToken = invitationUrl.searchParams.get("token");
  assert.ok(invitationToken?.startsWith("bti_"));

  const mismatch = await jsonRequest(baseUrl, "/api/invitations/accept", {
    body: {
      token: invitationToken,
      email: "different@example.test",
      name: "Wrong Recipient",
      password: "wrong-recipient-password",
    },
  });
  assert.equal(mismatch.response.status, 400);

  const accepted = await jsonRequest(baseUrl, "/api/invitations/accept", {
    body: {
      token: invitationToken,
      email: "member@example.test",
      name: "Invited Member",
      password: "invited-member-password",
    },
  });
  assert.equal(accepted.response.status, 201, JSON.stringify(accepted.body));
  const replay = await jsonRequest(baseUrl, "/api/invitations/accept", {
    body: {
      token: invitationToken,
      email: "member@example.test",
      name: "Invited Member",
      password: "invited-member-password",
    },
  });
  assert.equal(replay.response.status, 400);

  const memberSignIn = await jsonRequest(baseUrl, "/api/auth/sign-in/email", {
    body: {
      email: "member@example.test",
      password: "invited-member-password",
    },
  });
  assert.equal(memberSignIn.response.status, 200);
  const memberCookie = cookies(memberSignIn.response);
  const memberInvite = await jsonRequest(baseUrl, "/api/invitations", {
    cookie: memberCookie,
    body: { email: "forbidden@example.test", role: "member" },
  });
  assert.equal(memberInvite.response.status, 403);

  const revokeCandidate = await jsonRequest(baseUrl, "/api/invitations", {
    cookie: ownerCookie,
    body: { email: "revoked@example.test", role: "admin" },
  });
  assert.equal(revokeCandidate.response.status, 201);
  const revokedToken = new URL(revokeCandidate.body.url).searchParams.get("token");
  const revoked = await jsonRequest(baseUrl, "/api/invitations", {
    method: "DELETE",
    cookie: ownerCookie,
    body: { invitationId: revokeCandidate.body.id },
  });
  assert.equal(revoked.response.status, 204);
  const revokedAcceptance = await jsonRequest(baseUrl, "/api/invitations/accept", {
    body: {
      token: revokedToken,
      email: "revoked@example.test",
      name: "Revoked Recipient",
      password: "revoked-recipient-password",
    },
  });
  assert.equal(revokedAcceptance.response.status, 400);

  const [memberUser] = await sql`SELECT id FROM "user" WHERE email = 'member@example.test'`;
  await sql`UPDATE session SET expires_at = now() - interval '1 minute' WHERE user_id = ${memberUser.id}`;
  const expiredSession = await fetch(`${baseUrl}/api/invitations`, {
    headers: { cookie: memberCookie },
    redirect: "manual",
  });
  assert.equal(expiredSession.status, 401);

  let rateLimited = false;
  for (let attempt = 0; attempt < 11; attempt += 1) {
    const response = await jsonRequest(baseUrl, "/api/invitations/accept", {
      body: {
        token: "bti_invalid-token-with-stable-rate-limit-key-000000000000",
        email: "unknown@example.test",
        name: "Unknown Recipient",
        password: "unknown-recipient-password",
      },
    });
    if (response.response.status === 429) rateLimited = true;
  }
  assert.equal(rateLimited, true);

  let signInRateLimited = false;
  for (let attempt = 0; attempt < 11; attempt += 1) {
    const response = await jsonRequest(baseUrl, "/api/auth/sign-in/email", {
      body: {
        email: "unknown-sign-in@example.test",
        password: "invalid-sign-in-password",
      },
    });
    if (response.response.status === 429) signInRateLimited = true;
  }
  assert.equal(signInRateLimited, true);

  const [scope] = await sql`
    SELECT i.organisation_id AS invitation_org, m.organisation_id AS member_org,
      m.role, i.status
    FROM invitation i JOIN "user" u ON u.email = i.email
    JOIN membership m ON m.user_id = u.id
    WHERE i.email = 'member@example.test'
  `;
  assert.equal(scope.invitation_org, scope.member_org);
  assert.equal(scope.role, "member");
  assert.equal(scope.status, "accepted");

  const audit = await sql`SELECT action, result, details FROM console_audit_event ORDER BY created_at, id`;
  for (const action of [
    "bootstrap.completed",
    "invitation.created",
    "invitation.accepted",
    "invitation.revoked",
    "role.assigned",
  ]) {
    assert.ok(audit.some((event) => event.action === action), `missing ${action}`);
  }
  assert.ok(audit.some((event) => event.result === "denied"));
  const evidence = JSON.stringify(audit) + consoleLog.value;
  for (const secret of [
    bootstrapToken,
    owner.password,
    invitationToken,
    "invited-member-password",
  ]) {
    assert.equal(evidence.includes(secret), false);
  }

  process.stdout.write(
    `${JSON.stringify({
      publicSignup: "disabled",
      csrf: "enforced",
      invitationReplay: "rejected",
      invitationRevocation: "enforced",
      memberAuthorisation: "denied",
      sessionExpiry: "enforced",
      invitationRateLimit: "enforced",
      signInRateLimit: "enforced",
      audit: "redacted",
    })}\n`,
  );
} finally {
  if (consoleProcess) await stopChild(consoleProcess);
  await close(coordinator);
  await sql.end({ timeout: 5 });
}
