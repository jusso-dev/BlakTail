#!/usr/bin/env bun

import { SQL } from "bun";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { hashPassword } from "better-auth/crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
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
const secondOwner = {
  id: "second-owner-http-e2e",
  email: "second-owner.http@example.test",
  name: "Second HTTP Test Owner",
  password: "second-owner-http-test-password",
  organisationId: "second-org-http-e2e",
  organisation: "Ranger Operations",
  coordOrgId: "22222222-2222-4222-8222-222222222222",
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
  "0005_oidc_and_membership_lifecycle.sql",
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

function cookieValue(cookieHeader, names) {
  for (const part of cookieHeader.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (names.includes(name)) return part.slice(separator + 1).trim();
  }
  return null;
}

async function jsonRequest(baseUrl, path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: options.method ?? "POST",
    headers: {
      origin: options.origin ?? baseUrl,
      "content-type": "application/json",
      ...(options.cookie ? { cookie: options.cookie } : {}),
      ...(options.bearer ? { authorization: `Bearer ${options.bearer}` } : {}),
      ...(options.organisationId
        ? { "x-blaktail-organisation": options.organisationId }
        : {}),
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
