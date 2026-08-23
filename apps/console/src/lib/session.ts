import { createHmac } from "node:crypto";
import { eq } from "drizzle-orm";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth } from "./auth";
import { db } from "./db/client";
import { membership, organisation } from "./db/schema";
import type { OrgRole } from "./roles";

export type { OrgRole } from "./roles";
export { canMutateTailnet, roleLabel } from "./roles";

export type ConsoleContext = {
  userId: string;
  email: string;
  name: string;
  coordAssertion: string;
  sessionExpiresAt: Date;
  organisationId: string;
  organisationName: string;
  coordOrgId: string;
  role: OrgRole;
};

export async function requireSession() {
  const session = await auth.api.getSession({
    headers: await headers(),
  });
  if (!session) {
    redirect("/sign-in");
  }
  return session;
}

export async function requireConsoleContext(): Promise<ConsoleContext> {
  const session = await requireSession();
  const rows = await db()
    .select({
      organisationId: organisation.id,
      organisationName: organisation.name,
      coordOrgId: organisation.coordOrgId,
      role: membership.role,
    })
    .from(membership)
    .innerJoin(organisation, eq(membership.organisationId, organisation.id))
    .where(eq(membership.userId, session.user.id))
    .limit(1);

  const row = rows[0];
  if (!row) {
    throw new Error(
      "Your account is signed in, but it is not linked to an organisation yet.",
    );
  }

  const sessionExpiresAt = new Date(session.session.expiresAt);
  const expiresAt = Math.min(
    Math.floor(sessionExpiresAt.getTime() / 1000),
    Math.floor(Date.now() / 1000) + 60,
  );
  if (expiresAt <= Math.floor(Date.now() / 1000)) {
    throw new Error("Session has expired.");
  }
  const secret = process.env.BLAKTAIL_AUTH_HMAC_SECRET;
  if (!secret || Buffer.byteLength(secret) < 32) {
    throw new Error("BLAKTAIL_AUTH_HMAC_SECRET must be at least 32 bytes.");
  }
  const payload = Buffer.from(
    JSON.stringify({
      sub: session.user.id,
      org_id: row.coordOrgId,
      role: row.role,
      name: session.user.name,
      email: session.user.email,
      exp: expiresAt,
    }),
  ).toString("base64url");
  const signature = createHmac("sha256", secret)
    .update(payload)
    .digest("base64url");

  return {
    userId: session.user.id,
    email: session.user.email,
    name: session.user.name,
    coordAssertion: payload + "." + signature,
    sessionExpiresAt,
    organisationId: row.organisationId,
    organisationName: row.organisationName,
    coordOrgId: row.coordOrgId,
    role: row.role,
  };
}
