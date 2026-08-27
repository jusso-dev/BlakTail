import { createHmac, randomUUID } from "node:crypto";
import { chmod, writeFile } from "node:fs/promises";
import { SQL } from "bun";

const sql = new SQL(process.env.DATABASE_URL, { max: 1, prepare: false });
const secret = process.env.BLAKTAIL_AUTH_HMAC_SECRET;
const base = process.env.COORD_BASE_URL.replace(/\/$/u, "");
const keyDir = process.env.ACL_PROVE_KEY_DIR;

function sign(row) {
  const now = Math.floor(Date.now() / 1000);
  const payload = Buffer.from(
    JSON.stringify({
      sub: row.user_id,
      org_id: row.coord_org_id,
      role: "owner",
      name: row.name,
      email: row.email,
      iss: "blaktail-console",
      aud: "blaktail-coord",
      iat: now,
      exp: now + 60,
      jti: randomUUID(),
    }),
  ).toString("base64url");
  return `${payload}.${createHmac("sha256", secret).update(payload).digest("base64url")}`;
}

const [row] = await sql`
  SELECT u.id AS user_id, u.email, u.name, o.coord_org_id
  FROM "user" u
  JOIN membership m ON m.user_id = u.id
  JOIN organisation o ON o.id = m.organisation_id
  WHERE u.email = 'owner@homelab.test'
`;
if (!row) throw new Error("owner row missing");

const command = process.argv[2];
if (command === "identity") {
  process.stdout.write(
    `${JSON.stringify({ userId: row.user_id, email: row.email, coordOrgId: row.coord_org_id })}\n`,
  );
} else if (command === "put-acl") {
  const body = JSON.parse(process.argv[3] ?? "{}");
  const response = await fetch(`${base}/v1/orgs/${row.coord_org_id}/acl`, {
    method: "PUT",
    headers: {
      authorization: `Bearer ${sign(row)}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (response.status !== 204 && response.status !== 200) {
    throw new Error(`ACL PUT ${response.status} ${await response.text()}`);
  }
  process.stdout.write(`ok ACL PUT ${response.status}\n`);
} else if (command === "purge-nodes") {
  const wanted = new Set(["office-box", "store-box"]);
  const response = await fetch(`${base}/v1/orgs/${row.coord_org_id}/nodes`, {
    headers: { authorization: `Bearer ${sign(row)}` },
  });
  if (!response.ok) {
    throw new Error(`list nodes ${response.status} ${await response.text()}`);
  }
  const nodes = await response.json();
  let purged = 0;
  for (const node of nodes) {
    if (node.deleted || !wanted.has(node.name)) continue;
    const tombstone = await fetch(
      `${base}/v1/orgs/${row.coord_org_id}/nodes/${node.id}/tombstone`,
      {
        method: "POST",
        headers: { authorization: `Bearer ${sign(row)}` },
      },
    );
    if (!tombstone.ok && tombstone.status !== 404) {
      throw new Error(
        `tombstone ${node.name} ${tombstone.status} ${await tombstone.text()}`,
      );
    }
    purged += 1;
    process.stdout.write(`ok tombstoned leftover ${node.name}\n`);
  }
  if (purged === 0) process.stdout.write("ok no leftover prove nodes\n");
} else if (command === "mint") {
  if (!keyDir) throw new Error("ACL_PROVE_KEY_DIR is required");
  for (const tag of ["office", "store"]) {
    const response = await fetch(`${base}/v1/orgs/${row.coord_org_id}/join-keys`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${sign(row)}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        expires_in_seconds: 900,
        single_use: true,
        tags: [tag],
      }),
    });
    if (response.status !== 201) {
      throw new Error(`join key ${tag} ${response.status} ${await response.text()}`);
    }
    const minted = await response.json();
    const path = `${keyDir}/${tag}`;
    await writeFile(path, `${minted.key}\n`, { mode: 0o600 });
    await chmod(path, 0o600);
    process.stdout.write(`ok minted ${tag} key\n`);
  }
} else {
  throw new Error("usage: acl-prove.mjs identity|mint|put-acl|purge-nodes");
}

await sql.close({ timeout: 5 });
