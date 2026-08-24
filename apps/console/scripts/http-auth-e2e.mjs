#!/usr/bin/env node

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { hashPassword } from "better-auth/crypto";
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
const linkedIdentity = {
  email: "blue.identity@example.test",
  name: "Blue Identity",
  password: "blue-identity-test-password",
  organisation: "Blue Network",
};
const migrations = [
  "0000_init.sql",
  "0001_auth_membership_constraints.sql",
  "0002_account_issuer.sql",
  "0003_secure_bootstrap.sql",
  "0004_linked_identities.sql",
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
const coordinatorNodes = new Map();
const coordinatorMutations = [];
const coordinator = createServer(async (request, response) => {
  let raw = "";
  for await (const chunk of request) raw += chunk;
  if (request.url === "/v1/orgs") {
    const body = JSON.parse(raw);
    response.writeHead(202, { "content-type": "application/json" });
    response.end(JSON.stringify({ id: body.id, name: body.name }));
    return;
  }
  const commit = request.url?.match(
    /^\/v1\/orgs\/([^/]+)\/bootstrap-commit$/u,
  );
  if (commit) {
    response.writeHead(201, { "content-type": "application/json" });
    response.end(JSON.stringify({ id: commit[1], name: owner.organisation }));
    return;
  }
  const nodes = request.url?.match(/^\/v1\/orgs\/([^/]+)\/nodes$/u);
  if (nodes && request.method === "GET") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify(coordinatorNodes.get(nodes[1]) ?? []));
    return;
  }
  const mutation = request.url?.match(
    /^\/v1\/orgs\/([^/]+)\/nodes\/([^/]+)(?:\/(friendly-name|routes))?$/u,
  );
  if (mutation) {
    const [, orgId, nodeId, suffix] = mutation;
    const orgNodes = coordinatorNodes.get(orgId) ?? [];
    const node = orgNodes.find((candidate) => candidate.id === nodeId);
    if (!node) {
      response.writeHead(404, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: "Node not found." }));
      return;
    }
    const body = raw ? JSON.parse(raw) : {};
    const operation =
      request.method === "DELETE"
        ? "revoke"
        : suffix === "friendly-name"
          ? "rename"
          : "approve-routes";
    if (operation === "revoke") node.revoked = true;
    if (operation === "rename") node.display_name = body.friendly_name || null;
    if (operation === "approve-routes") {
      node.approved_routes = body.approved_routes ?? [];
    }
    coordinatorMutations.push({ orgId, nodeId, operation });
    response.writeHead(204);
    response.end();
    return;
  }
  response.writeHead(404, { "content-type": "application/json" });
  response.end(JSON.stringify({ error: "Not found." }));
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

  const linkedUserId = randomUUID();
  const linkedPersonId = randomUUID();
  const linkedOrganisationId = randomUUID();
  const linkedCoordinatorOrgId = randomUUID();
  const linkedMembershipId = randomUUID();
  const linkedPasswordHash = await hashPassword(linkedIdentity.password);
  await sql.begin("isolation level serializable", async (transaction) => {
    await transaction`
      INSERT INTO "user" (id, name, email, email_verified)
      VALUES (
        ${linkedUserId}, ${linkedIdentity.name}, ${linkedIdentity.email}, true
      )
    `;
    await transaction`
      INSERT INTO person (id, display_name)
      VALUES (${linkedPersonId}, ${linkedIdentity.name})
    `;
    await transaction`
      INSERT INTO person_login_identity (id, person_id, user_id)
      VALUES (${randomUUID()}, ${linkedPersonId}, ${linkedUserId})
    `;
    await transaction`
      INSERT INTO organisation (id, name, coord_org_id)
      VALUES (
        ${linkedOrganisationId}, ${linkedIdentity.organisation},
        ${linkedCoordinatorOrgId}
      )
    `;
    await transaction`
      INSERT INTO membership (id, organisation_id, user_id, role)
      VALUES (
        ${linkedMembershipId}, ${linkedOrganisationId}, ${linkedUserId}, 'owner'
      )
    `;
    await transaction`
      INSERT INTO network_account (
        id, membership_id, login_identity_user_id, organisation_id, name
      ) VALUES (
        ${randomUUID()}, ${linkedMembershipId}, ${linkedUserId},
        ${linkedOrganisationId}, ${linkedIdentity.organisation}
      )
    `;
    await transaction`
      INSERT INTO account (
        id, issuer, account_id, provider_id, user_id, password
      ) VALUES (
        ${randomUUID()}, 'local:credential', ${linkedUserId}, 'credential',
        ${linkedUserId}, ${linkedPasswordHash}
      )
    `;
  });

  const [ownerOrganisation] = await sql`
    SELECT id, coord_org_id FROM organisation WHERE name = ${owner.organisation}
  `;
  const ownerNodeId = randomUUID();
  const linkedNodeId = randomUUID();
  const credentialExpiry = Math.floor(Date.now() / 1000) + 86_400;
  const node = (id, name, route = null) => ({
    id,
    name,
    display_name: null,
    wg_public_key: `wg-${id}`,
    endpoint: null,
    allowed_ips: [],
    advertised_routes: route ? [route] : [],
    approved_routes: [],
    dns_name: `${name}.test`,
    user_id: "fixture-user",
    user_role: "owner",
    tags: [],
    created_at: Math.floor(Date.now() / 1000),
    credential_expires_at: credentialExpiry,
    expired: false,
    expires_soon: false,
    revoked: false,
  });
  coordinatorNodes.set(ownerOrganisation.coord_org_id, [
    node(ownerNodeId, "red-machine"),
  ]);
  coordinatorNodes.set(linkedCoordinatorOrgId, [
    node(linkedNodeId, "blue-machine", "10.24.0.0/24"),
  ]);

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

  const initialMe = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal(initialMe.status, 200);
  assert.equal((await initialMe.json()).organisations.length, 1);

  const linkCsrf = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    origin: "https://attacker.example",
    body: { operation: "start" },
  });
  assert.equal(linkCsrf.response.status, 403);

  const emailOnlyStart = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: { operation: "start" },
  });
  assert.equal(emailOnlyStart.response.status, 201);
  const emailOnly = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: emailOnlyStart.body.challenge,
      email: linkedIdentity.email,
      password: "not-the-linked-identity-password",
    },
  });
  assert.equal(emailOnly.response.status, 400);

  const expiringLink = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: { operation: "start" },
  });
  assert.equal(expiringLink.response.status, 201);
  await sql`
    UPDATE identity_link_challenge
    SET expires_at = now() - interval '1 second'
    WHERE status = 'pending'
  `;
  const expiredLink = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: expiringLink.body.challenge,
      email: linkedIdentity.email,
      password: linkedIdentity.password,
    },
  });
  assert.equal(expiredLink.response.status, 400);

  const staleSessionLink = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: { operation: "start" },
  });
  assert.equal(staleSessionLink.response.status, 201);
  const secondOwnerSignIn = await jsonRequest(
    baseUrl,
    "/api/auth/sign-in/email",
    { body: { email: owner.email, password: owner.password } },
  );
  assert.equal(secondOwnerSignIn.response.status, 200);
  const staleSessionAttempt = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: cookies(secondOwnerSignIn.response),
      body: {
        operation: "complete",
        challenge: staleSessionLink.body.challenge,
        email: linkedIdentity.email,
        password: linkedIdentity.password,
      },
    },
  );
  assert.equal(staleSessionAttempt.response.status, 400);

  const linkStart = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: { operation: "start" },
  });
  assert.equal(linkStart.response.status, 201);
  const linkChallenge = linkStart.body.challenge;
  const linked = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: linkChallenge,
      email: linkedIdentity.email,
      password: linkedIdentity.password,
    },
  });
  assert.equal(linked.response.status, 200, JSON.stringify(linked.body));

  const linkedMe = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal(linkedMe.status, 200);
  const linkedMeBody = await linkedMe.json();
  assert.deepEqual(
    linkedMeBody.organisations.map((organisation) => organisation.name).sort(),
    [linkedIdentity.organisation, owner.organisation].sort(),
  );
  const tokenMatch = ownerCookie.match(
    /(?:^|; )(?:__Secure-)?better-auth\.session_token=([^;]+)/u,
  );
  assert.ok(tokenMatch);
  const desktopMe = await fetch(`${baseUrl}/api/desktop/me`, {
    headers: { authorization: `Bearer ${decodeURIComponent(tokenMatch[1])}` },
  });
  assert.equal(desktopMe.status, 200);
  assert.equal((await desktopMe.json()).organisations.length, 2);

  const allDevices = await fetch(`${baseUrl}/api/devices`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal(allDevices.status, 200);
  const allDeviceRows = await allDevices.json();
  assert.deepEqual(
    allDeviceRows.map((device) => device.name).sort(),
    ["blue-machine", "red-machine"],
  );
  assert.deepEqual(
    allDeviceRows.map((device) => device.network_account_name).sort(),
    [linkedIdentity.organisation, owner.organisation].sort(),
  );

  const devicesPage = await fetch(`${baseUrl}/devices`, {
    headers: { cookie: ownerCookie },
  });
  const devicesHTML = await devicesPage.text();
  assert.equal(devicesPage.status, 200);
  assert.match(devicesHTML, /red-machine/u);
  assert.match(devicesHTML, /blue-machine/u);
  assert.match(devicesHTML, /Blue Network/u);

  const blueSettings = await fetch(`${baseUrl}/settings`, {
    headers: {
      cookie: `${ownerCookie}; blaktail.organisation=${linkedOrganisationId}`,
    },
  });
  assert.equal(blueSettings.status, 200);
  assert.match(await blueSettings.text(), /Blue Network/u);
  assert.equal(
    (blueSettings.headers.get("set-cookie") ?? "").includes(
      "better-auth.session_token",
    ),
    false,
  );
  const redSettings = await fetch(`${baseUrl}/settings`, {
    headers: {
      cookie: `${ownerCookie}; blaktail.organisation=${ownerOrganisation.id}`,
    },
  });
  assert.equal(redSettings.status, 200);
  assert.match(await redSettings.text(), /BlakPath HTTP Test/u);

  const renamed = await jsonRequest(baseUrl, "/api/devices", {
    method: "PATCH",
    cookie: ownerCookie,
    body: {
      operation: "rename",
      organisationId: ownerOrganisation.id,
      nodeId: ownerNodeId,
      friendlyName: "Red friendly machine",
    },
  });
  assert.equal(renamed.response.status, 204);
  const routesApproved = await jsonRequest(baseUrl, "/api/devices", {
    method: "PATCH",
    cookie: ownerCookie,
    body: {
      operation: "approve-routes",
      organisationId: linkedOrganisationId,
      nodeId: linkedNodeId,
      approvedRoutes: ["10.24.0.0/24"],
    },
  });
  assert.equal(routesApproved.response.status, 204);
  const crossTenantMutation = await jsonRequest(baseUrl, "/api/devices", {
    method: "PATCH",
    cookie: ownerCookie,
    body: {
      operation: "rename",
      organisationId: ownerOrganisation.id,
      nodeId: linkedNodeId,
      friendlyName: "Must not cross tenants",
    },
  });
  assert.equal(crossTenantMutation.response.status, 400);
  const nodeRevoked = await jsonRequest(baseUrl, "/api/devices", {
    method: "DELETE",
    cookie: ownerCookie,
    body: {
      organisationId: linkedOrganisationId,
      nodeId: linkedNodeId,
    },
  });
  assert.equal(nodeRevoked.response.status, 204);
  assert.deepEqual(coordinatorMutations, [
    { orgId: ownerOrganisation.coord_org_id, nodeId: ownerNodeId, operation: "rename" },
    { orgId: linkedCoordinatorOrgId, nodeId: linkedNodeId, operation: "approve-routes" },
    { orgId: linkedCoordinatorOrgId, nodeId: linkedNodeId, operation: "revoke" },
  ]);

  const linkReplay = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: linkChallenge,
      email: linkedIdentity.email,
      password: linkedIdentity.password,
    },
  });
  assert.equal(linkReplay.response.status, 400);

  const concurrentStarts = await Promise.all([
    jsonRequest(baseUrl, "/api/identity-links", {
      cookie: ownerCookie,
      body: { operation: "start" },
    }),
    jsonRequest(baseUrl, "/api/identity-links", {
      cookie: ownerCookie,
      body: { operation: "start" },
    }),
  ]);
  assert.deepEqual(
    concurrentStarts.map((result) => result.response.status).sort(),
    [201, 400],
  );
  const concurrentChallenge = concurrentStarts.find(
    (result) => result.response.status === 201,
  ).body.challenge;
  const alreadyOwned = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: concurrentChallenge,
      email: linkedIdentity.email,
      password: linkedIdentity.password,
    },
  });
  assert.equal(alreadyOwned.response.status, 400);

  const soleOwnerRevocation = await jsonRequest(baseUrl, "/api/identity-links", {
    method: "DELETE",
    cookie: ownerCookie,
    body: {
      operation: "revoke",
      identityUserId: linkedUserId,
      currentPassword: owner.password,
    },
  });
  assert.equal(soleOwnerRevocation.response.status, 400);

  const unlinked = await jsonRequest(baseUrl, "/api/identity-links", {
    method: "DELETE",
    cookie: ownerCookie,
    body: {
      operation: "unlink",
      identityUserId: linkedUserId,
      currentPassword: owner.password,
    },
  });
  assert.equal(unlinked.response.status, 204);
  const unlinkedMe = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal((await unlinkedMe.json()).organisations.length, 1);

  const unlinkedDevices = await fetch(`${baseUrl}/api/devices`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal(unlinkedDevices.status, 200);
  assert.deepEqual(
    (await unlinkedDevices.json()).map((device) => device.name),
    ["red-machine"],
  );
  const finalSignInUnlink = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      method: "DELETE",
      cookie: ownerCookie,
      body: {
        operation: "unlink",
        identityUserId: linkedMeBody.currentIdentity.userId,
        currentPassword: owner.password,
      },
    },
  );
  assert.equal(finalSignInUnlink.response.status, 400);

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

  const invitationCannotLink = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: ownerCookie,
      body: {
        operation: "complete",
        challenge: invitationToken,
        email: linkedIdentity.email,
        password: linkedIdentity.password,
      },
    },
  );
  assert.equal(invitationCannotLink.response.status, 400);

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

  const blueBackupOwnerMembershipId = randomUUID();
  await sql`
    INSERT INTO membership (id, organisation_id, user_id, role)
    VALUES (
      ${blueBackupOwnerMembershipId}, ${linkedOrganisationId},
      ${memberUser.id}, 'owner'
    )
  `;
  await sql`
    INSERT INTO network_account (
      id, membership_id, login_identity_user_id, organisation_id, name
    ) VALUES (
      ${randomUUID()}, ${blueBackupOwnerMembershipId}, ${memberUser.id},
      ${linkedOrganisationId}, ${linkedIdentity.organisation}
    )
  `;

  const linkedSignIn = await jsonRequest(
    baseUrl,
    "/api/auth/sign-in/email",
    {
      body: {
        email: linkedIdentity.email,
        password: linkedIdentity.password,
      },
    },
  );
  assert.equal(linkedSignIn.response.status, 200);
  const linkedCookie = cookies(linkedSignIn.response);

  const relinkStart = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: { operation: "start" },
  });
  assert.equal(relinkStart.response.status, 201);
  const relink = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: relinkStart.body.challenge,
      email: linkedIdentity.email,
      password: linkedIdentity.password,
    },
  });
  assert.equal(relink.response.status, 200);

  const identityRevoked = await jsonRequest(baseUrl, "/api/identity-links", {
    method: "DELETE",
    cookie: ownerCookie,
    body: {
      operation: "revoke",
      identityUserId: linkedUserId,
      currentPassword: owner.password,
    },
  });
  assert.equal(identityRevoked.response.status, 204);
  const revokedIdentitySession = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: linkedCookie },
  });
  assert.equal(revokedIdentitySession.status, 403);
  const afterIdentityRevocation = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal((await afterIdentityRevocation.json()).organisations.length, 1);

  const identityRecovered = await jsonRequest(baseUrl, "/api/identity-links", {
    method: "DELETE",
    cookie: ownerCookie,
    body: {
      operation: "recover",
      identityUserId: linkedUserId,
      currentPassword: owner.password,
    },
  });
  assert.equal(identityRecovered.response.status, 204);
  const afterIdentityRecovery = await fetch(`${baseUrl}/api/me`, {
    headers: { cookie: ownerCookie },
  });
  assert.equal((await afterIdentityRecovery.json()).organisations.length, 2);

  const foreignGraphStart = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: memberCookie,
      body: { operation: "start" },
    },
  );
  assert.equal(foreignGraphStart.response.status, 201);
  const foreignGraphLink = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: memberCookie,
      body: {
        operation: "complete",
        challenge: foreignGraphStart.body.challenge,
        email: owner.email,
        password: owner.password,
      },
    },
  );
  assert.equal(foreignGraphLink.response.status, 400);

  const roleConflictStart = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: ownerCookie,
      body: { operation: "start" },
    },
  );
  assert.equal(roleConflictStart.response.status, 201);
  const roleConflict = await jsonRequest(baseUrl, "/api/identity-links", {
    cookie: ownerCookie,
    body: {
      operation: "complete",
      challenge: roleConflictStart.body.challenge,
      email: "member@example.test",
      password: "invited-member-password",
    },
  });
  assert.equal(roleConflict.response.status, 202);
  assert.equal(roleConflict.body.ownerResolutionRequired, true);
  const [pendingConflict] = await sql`
    SELECT c.id
    FROM identity_link_conflict c
    JOIN identity_link_challenge ch ON ch.id = c.challenge_id
    WHERE ch.status = 'awaiting_owner'
  `;
  assert.ok(pendingConflict);
  const conflictResolution = await jsonRequest(
    baseUrl,
    "/api/identity-links",
    {
      cookie: ownerCookie,
      body: {
        operation: "resolve-role",
        conflictId: pendingConflict.id,
        resolvedRole: "owner",
      },
    },
  );
  assert.equal(conflictResolution.response.status, 200);
  assert.equal(conflictResolution.body.linked, true);
  const preservedRoles = await sql`
    SELECT role FROM membership
    WHERE organisation_id = ${ownerOrganisation.id}
    ORDER BY role
  `;
  assert.deepEqual(
    preservedRoles.map((membership) => membership.role),
    ["member", "owner"],
  );

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
    JOIN membership m
      ON m.user_id = u.id
      AND m.organisation_id = i.organisation_id
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
    "identity_link.requested",
    "identity_link.succeeded",
    "identity_link.rejected",
    "identity_link.unlinked",
    "identity_link.revoked",
    "identity_link.recovered",
    "identity_link.role_conflict",
    "identity_link.role_conflict_resolved",
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
    linkedIdentity.password,
    linkChallenge,
    emailOnlyStart.body.challenge,
    relinkStart.body.challenge,
    expiringLink.body.challenge,
    staleSessionLink.body.challenge,
    concurrentChallenge,
    foreignGraphStart.body.challenge,
    roleConflictStart.body.challenge,
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
      identityLinkFreshAuth: "enforced",
      identityLinkReplay: "rejected",
      concurrentIdentityLink: "fail-closed",
      sameSessionNetworks: 2,
      identityRevocationRecovery: "enforced",
      linkExpiry: "rejected",
      staleLinkSession: "rejected",
      roleConflictOwnerDecision: "enforced",
      aggregateDevices: 2,
      owningOrganisationMutations: "isolated",
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
