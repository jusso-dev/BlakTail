import { asc, eq } from "drizzle-orm";
import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth, type Session } from "./auth";
import { requireBootstrapLocked } from "./bootstrap-state";
import { db } from "./db/client";
import { membership, organisation } from "./db/schema";
import type { OrgRole } from "./roles";

export type { OrgRole } from "./roles";
export { canMutateTailnet, roleLabel } from "./roles";

export const ACTIVE_ORGANISATION_COOKIE = "blaktail.active_organisation";

export const activeOrganisationCookieOptions = {
  httpOnly: true,
  sameSite: "lax" as const,
  secure: process.env.NODE_ENV === "production",
  path: "/",
  maxAge: 60 * 60 * 24 * 365,
};

export type OrganisationContext = {
  organisationId: string;
  organisationName: string;
  coordOrgId: string;
  role: OrgRole;
};

export type ConsoleContext = OrganisationContext & {
  userId: string;
  email: string;
  name: string;
  sessionExpiresAt: Date;
  organisations: OrganisationContext[];
};

export class OrganisationAccessError extends Error {}

export async function requireSession() {
  const session = await auth.api.getSession({
    headers: await headers(),
  });
  if (!session) {
    redirect("/sign-in");
  }
  return session;
}

export function activeOrganisationIdFromRequest(
  request: Request,
): string | undefined {
  const headerSelection = request.headers
    .get("x-blaktail-organisation")
    ?.trim();
  if (headerSelection) return headerSelection;

  for (const part of (request.headers.get("cookie") ?? "").split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    if (part.slice(0, separator).trim() !== ACTIVE_ORGANISATION_COOKIE) continue;
    try {
      return decodeURIComponent(part.slice(separator + 1).trim()) || undefined;
    } catch {
      return undefined;
    }
  }
  return undefined;
}

export async function consoleContextFromSession(
  session: Session,
  selectedOrganisationId?: string,
  requireExactSelection = false,
): Promise<ConsoleContext> {
  await requireBootstrapLocked();
  const organisations = await db()
    .select({
      organisationId: organisation.id,
      organisationName: organisation.name,
      coordOrgId: organisation.coordOrgId,
      role: membership.role,
    })
    .from(membership)
    .innerJoin(organisation, eq(membership.organisationId, organisation.id))
    .where(eq(membership.userId, session.user.id))
    .orderBy(asc(organisation.name), asc(organisation.id));

  if (organisations.length === 0) {
    throw new OrganisationAccessError(
      "Your account is signed in, but it is not linked to an organisation yet.",
    );
  }

  const selected = selectedOrganisationId
    ? organisations.find(
        (candidate) => candidate.organisationId === selectedOrganisationId,
      )
    : undefined;
  if (requireExactSelection && selectedOrganisationId && !selected) {
    throw new OrganisationAccessError(
      "Your account does not have access to that organisation.",
    );
  }
  const active = selected ?? organisations[0]!;

  const sessionExpiresAt = new Date(session.session.expiresAt);
  if (sessionExpiresAt.getTime() <= Date.now()) {
    throw new Error("Session has expired.");
  }

  return {
    userId: session.user.id,
    email: session.user.email,
    name: session.user.name,
    sessionExpiresAt,
    ...active,
    organisations,
  };
}

export async function requireConsoleContext(): Promise<ConsoleContext> {
  const session = await requireSession();
  const selectedOrganisationId = (await cookies()).get(
    ACTIVE_ORGANISATION_COOKIE,
  )?.value;
  return consoleContextFromSession(session, selectedOrganisationId);
}

export async function requireConsoleContextForOrganisation(
  organisationId: string,
): Promise<ConsoleContext> {
  if (!organisationId) {
    throw new OrganisationAccessError("Choose an organisation.");
  }
  return consoleContextFromSession(
    await requireSession(),
    organisationId,
    true,
  );
}

export function contextForOrganisation(
  ctx: ConsoleContext,
  organisationId: string,
): ConsoleContext {
  const selected = ctx.organisations.find(
    (candidate) => candidate.organisationId === organisationId,
  );
  if (!selected) {
    throw new OrganisationAccessError(
      "Your account does not have access to that organisation.",
    );
  }
  return { ...ctx, ...selected };
}
