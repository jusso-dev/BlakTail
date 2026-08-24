import "server-only";

import { createHmac, randomUUID } from "node:crypto";
import type { OrgRole } from "./roles";

export type CoordAssertionActor = {
  userId: string;
  email: string;
  name: string;
  coordOrgId: string;
  role: OrgRole;
  sessionExpiresAt: Date;
};

function assertionSecret(): string {
  const secret = process.env.BLAKTAIL_AUTH_HMAC_SECRET;
  if (!secret || Buffer.byteLength(secret) < 32) {
    throw new Error("BLAKTAIL_AUTH_HMAC_SECRET must be at least 32 bytes.");
  }
  return secret;
}

/** Mint one coordinator assertion for one outbound request. Never reuse it. */
export function signCoordAssertion(actor: CoordAssertionActor): string {
  const issuedAt = Math.floor(Date.now() / 1000);
  const expiresAt = Math.min(
    Math.floor(actor.sessionExpiresAt.getTime() / 1000),
    issuedAt + 60,
  );
  if (expiresAt <= issuedAt) {
    throw new Error("Session has expired.");
  }
  const payload = Buffer.from(
    JSON.stringify({
      sub: actor.userId,
      org_id: actor.coordOrgId,
      role: actor.role,
      name: actor.name,
      email: actor.email,
      iss: "blaktail-console",
      aud: "blaktail-coord",
      iat: issuedAt,
      exp: expiresAt,
      jti: randomUUID(),
    }),
  ).toString("base64url");
  const signature = createHmac("sha256", assertionSecret())
    .update(payload)
    .digest("base64url");
  return `${payload}.${signature}`;
}
