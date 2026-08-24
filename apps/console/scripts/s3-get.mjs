import { createHash, createHmac } from "node:crypto";
import { open } from "node:fs/promises";

const EMPTY_SHA256 =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const TASK_CREDENTIALS_ORIGIN = "http://169.254.170.2";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hmac(key, value, encoding) {
  return createHmac("sha256", key).update(value).digest(encoding);
}

function awsEncode(value) {
  return encodeURIComponent(value).replace(/[!'()*]/gu, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  );
}

function canonicalObjectPath(key) {
  return `/${key.split("/").map(awsEncode).join("/")}`;
}

function signingTimestamp(now) {
  return now.toISOString().replace(/[:-]|\.\d{3}/gu, "");
}

export function signS3Get({ bucket, key, region, credentials, now = new Date() }) {
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/u.test(bucket)) {
    throw new Error("S3 bucket name is invalid");
  }
  if (!key || key.startsWith("/") || key.includes("\0")) {
    throw new Error("S3 object key is invalid");
  }
  if (!/^[a-z]{2}(?:-gov)?-[a-z]+-\d$/u.test(region)) {
    throw new Error("AWS region is invalid");
  }
  if (!credentials?.accessKeyId || !credentials.secretAccessKey) {
    throw new Error("task credentials are incomplete");
  }

  const host = `${bucket}.s3.${region}.amazonaws.com`;
  const pathname = canonicalObjectPath(key);
  const amzDate = signingTimestamp(now);
  const date = amzDate.slice(0, 8);
  const headers = {
    host,
    "x-amz-content-sha256": EMPTY_SHA256,
    "x-amz-date": amzDate,
  };
  if (credentials.sessionToken) {
    headers["x-amz-security-token"] = credentials.sessionToken;
  }
  const signedHeaders = Object.keys(headers).sort().join(";");
  const canonicalHeaders = Object.keys(headers)
    .sort()
    .map((name) => `${name}:${headers[name].trim()}\n`)
    .join("");
  const canonicalRequest = [
    "GET",
    pathname,
    "",
    canonicalHeaders,
    signedHeaders,
    EMPTY_SHA256,
  ].join("\n");
  const scope = `${date}/${region}/s3/aws4_request`;
  const stringToSign = [
    "AWS4-HMAC-SHA256",
    amzDate,
    scope,
    sha256(canonicalRequest),
  ].join("\n");
  const dateKey = hmac(`AWS4${credentials.secretAccessKey}`, date);
  const regionKey = hmac(dateKey, region);
  const serviceKey = hmac(regionKey, "s3");
  const signingKey = hmac(serviceKey, "aws4_request");
  const signature = hmac(signingKey, stringToSign, "hex");
  headers.authorization =
    `AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/${scope},` +
    `SignedHeaders=${signedHeaders},Signature=${signature}`;

  return {
    url: `https://${host}${pathname}`,
    headers,
    canonicalRequest,
  };
}

export async function loadTaskCredentials({
  environment = process.env,
  request = fetch,
} = {}) {
  const relativeUri = environment.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
  if (!relativeUri || !relativeUri.startsWith("/") || relativeUri.startsWith("//")) {
    throw new Error("ECS task credentials are unavailable");
  }
  const url = new URL(relativeUri, TASK_CREDENTIALS_ORIGIN);
  if (url.origin !== TASK_CREDENTIALS_ORIGIN) {
    throw new Error("ECS task credentials endpoint is invalid");
  }
  const response = await request(url, {
    redirect: "error",
    signal: AbortSignal.timeout(5_000),
  });
  if (!response.ok) {
    throw new Error(`ECS task credentials request failed (${response.status})`);
  }
  const payload = await response.json();
  if (!payload.AccessKeyId || !payload.SecretAccessKey || !payload.Token) {
    throw new Error("ECS task credentials response is incomplete");
  }
  return {
    accessKeyId: payload.AccessKeyId,
    secretAccessKey: payload.SecretAccessKey,
    sessionToken: payload.Token,
  };
}

export async function downloadS3Object({
  bucket,
  key,
  destination,
  region,
  environment = process.env,
  request = fetch,
}) {
  const credentials = await loadTaskCredentials({ environment, request });
  const signed = signS3Get({ bucket, key, region, credentials });
  const response = await request(signed.url, {
    headers: signed.headers,
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) {
    throw new Error(`S3 object request failed (${response.status})`);
  }

  const file = await open(destination, "wx", 0o600);
  try {
    await file.writeFile(new Uint8Array(await response.arrayBuffer()));
    await file.sync();
  } finally {
    await file.close();
  }
}

async function main() {
  const [bucket, key, destination] = process.argv.slice(2);
  const region = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION;
  if (!bucket || !key || !destination || !region) {
    throw new Error("usage: s3-get.mjs <bucket> <key> <destination>");
  }
  await downloadS3Object({ bucket, key, destination, region });
}

if (import.meta.main) {
  await main().catch((error) => {
    console.error(error instanceof Error ? error.message : "S3 download failed");
    process.exitCode = 1;
  });
}
