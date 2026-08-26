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
