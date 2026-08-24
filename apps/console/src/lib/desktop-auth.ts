import { eq } from "drizzle-orm";
import { auth, type Session } from "@/lib/auth";
import { requireBootstrapLocked } from "@/lib/bootstrap-state";
import { db } from "@/lib/db/client";
import { membership, organisation } from "@/lib/db/schema";
import type { ConsoleContext } from "@/lib/session";
import type { OrgRole } from "@/lib/roles";

/**
 * Resolve a Better Auth session from an Authorization Bearer token issued to the Mac app.
 * Cookie name matches Better Auth defaults; try the Secure prefix used on HTTPS consoles.
 */
export async function sessionFromBearer(request: Request): Promise<Session | null> {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!match) {
    return null;
  }
  const token = match[1]!.trim();
  if (!token) {
    return null;
  }

  const cookieNames = [
    "better-auth.session_token",
    "__Secure-better-auth.session_token",
  ];
  for (const name of cookieNames) {
    const session = await auth.api.getSession({
      headers: new Headers({
        cookie: `${name}=${token}`,
      }),
    });
    if (session) {
      return session;
    }
  }
  return null;
}

export async function requireConsoleContextFromSession(
  session: Session,
): Promise<ConsoleContext> {
  await requireBootstrapLocked();
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
  if (sessionExpiresAt.getTime() <= Date.now()) {
    throw new Error("Session has expired.");
  }

  return {
    userId: session.user.id,
    email: session.user.email,
    name: session.user.name,
    sessionExpiresAt,
    organisationId: row.organisationId,
    organisationName: row.organisationName,
    coordOrgId: row.coordOrgId,
    role: row.role as OrgRole,
  };
}
