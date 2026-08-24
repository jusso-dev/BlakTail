import assert from "node:assert/strict";
import { test } from "node:test";
import { loadTaskCredentials, signS3Get } from "./s3-get.mjs";

test("SigV4 signs an encoded S3 GET with temporary task credentials", () => {
  const signed = signS3Get({
    bucket: "blaktail-e2e-artifacts",
    key: "bootstrap/run id/owner+password",
    region: "ap-southeast-2",
    now: new Date("2026-08-24T10:58:19.000Z"),
    credentials: {
      accessKeyId: "ASIATESTACCESSKEY",
      secretAccessKey: "test-secret-access-key",
      sessionToken: "test-session-token",
    },
  });

  assert.equal(
    signed.url,
    "https://blaktail-e2e-artifacts.s3.ap-southeast-2.amazonaws.com/bootstrap/run%20id/owner%2Bpassword",
  );
  assert.equal(signed.headers["x-amz-date"], "20260824T105819Z");
  assert.equal(signed.headers["x-amz-security-token"], "test-session-token");
  assert.equal(
    signed.headers.authorization,
    "AWS4-HMAC-SHA256 Credential=ASIATESTACCESSKEY/20260824/ap-southeast-2/s3/aws4_request," +
      "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token," +
      "Signature=c29aa71ac50a3bd2911290e84e48760685d753bce93563278d2183edf11f6268",
  );
  assert.equal(signed.canonicalRequest.includes("test-secret-access-key"), false);
  assert.equal(signed.canonicalRequest.includes("test-session-token"), true);
});

test("task credential lookup is pinned to the ECS link-local endpoint", async () => {
  let requestedUrl;
  const credentials = await loadTaskCredentials({
    environment: {
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: "/v2/credentials/task-id",
    },
    request: async (url) => {
      requestedUrl = url.toString();
      return new Response(
        JSON.stringify({
          AccessKeyId: "ASIATEST",
          SecretAccessKey: "secret",
          Token: "token",
        }),
      );
    },
  });
  assert.equal(requestedUrl, "http://169.254.170.2/v2/credentials/task-id");
  assert.deepEqual(credentials, {
    accessKeyId: "ASIATEST",
    secretAccessKey: "secret",
    sessionToken: "token",
  });

  await assert.rejects(
    () =>
      loadTaskCredentials({
        environment: {
          AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: "//attacker.invalid/credentials",
        },
      }),
    /endpoint is invalid|credentials are unavailable/u,
  );
});
