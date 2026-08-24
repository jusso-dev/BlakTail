import { cookies, headers } from "next/headers";
import { redirect } from "next/navigation";
import { auth, type Session } from "./auth";
import { requireBootstrapLocked } from "./bootstrap-state";
import { rawSqlClient } from "./db/client";
import type { OrgRole } from "./roles";

export type { OrgRole } from "./roles";
export { canMutateTailnet, roleLabel } from "./roles";

export const ORGANISATION_COOKIE = "blaktail.organisation";

export type OrganisationAccess = {
  organisationId: string;
  organisationName: string;
  coordOrgId: string;
  role: OrgRole;
  membershipIds: string[];
  networkAccountIds: string[];
  networkAccountNames: string[];
  identityUserIds: string[];
};

export type PersonSessionContext = {
  personId: string;
  userId: string;
  sessionId: string;
  email: string;
  name: string;
  identityName: string;
  sessionExpiresAt: Date;
  organisations: OrganisationAccess[];
};

export type ConsoleContext = PersonSessionContext &
  OrganisationAccess & {
    networkAccountId: string;
    networkAccountName: string;
  };

type AccessRow = {
  membership_id: string;
  network_account_id: string;
  network_account_name: string;
  identity_user_id: string;
  organisation_id: string;
  organisation_name: string;
  coord_org_id: string;
  role: OrgRole;
  effective_role: OrgRole | null;
  membership_signature: string | null;
};

function membershipSignature(rows: AccessRow[]): string {
  return rows
    .map((row) => `${row.membership_id}:${row.role}`)
    .sort()
    .join("|");
}

/**
 * Resolve the live person/identity/membership graph for every request. No
 * organisation or role is retained in the Better Auth session.
 */
export async function resolveSessionContext(
  session: Session,
): Promise<PersonSessionContext> {
  await requireBootstrapLocked();
  const sessionExpiresAt = new Date(session.session.expiresAt);
  if (sessionExpiresAt.getTime() <= Date.now()) {
    throw new Error("Session has expired.");
  }

  const sql = rawSqlClient();
  const [identity] = await sql`
    SELECT pli.person_id, p.display_name
    FROM person_login_identity pli
    JOIN person p ON p.id = pli.person_id
    WHERE pli.user_id = ${session.user.id} AND pli.status = 'active'
    LIMIT 1
  `;
  if (!identity) {
    throw new Error(
      "This sign-in identity is suspended or requires account recovery.",
    );
  }

  const rows = (await sql`
    SELECT m.id AS membership_id, na.id AS network_account_id,
      na.name AS network_account_name, pli.user_id AS identity_user_id,
      o.id AS organisation_id, o.name AS organisation_name,
      o.coord_org_id, m.role, mrr.effective_role,
      mrr.membership_signature
    FROM person_login_identity pli
    JOIN membership m ON m.user_id = pli.user_id
    JOIN network_account na ON na.membership_id = m.id
      AND na.login_identity_user_id = pli.user_id
      AND na.organisation_id = m.organisation_id
      AND na.status = 'active'
    JOIN organisation o ON o.id = m.organisation_id
    LEFT JOIN membership_role_resolution mrr
      ON mrr.person_id = pli.person_id
      AND mrr.organisation_id = m.organisation_id
    WHERE pli.person_id = ${identity.person_id}
      AND pli.status = 'active'
    ORDER BY o.name, o.id, m.id
  `) as unknown as AccessRow[];

  if (rows.length === 0) {
    throw new Error(
      "Your account is signed in, but it has no active network accounts.",
    );
  }

  const grouped = new Map<string, AccessRow[]>();
  for (const row of rows) {
    const group = grouped.get(row.organisation_id) ?? [];
    group.push(row);
    grouped.set(row.organisation_id, group);
  }

  const organisations: OrganisationAccess[] = [];
  for (const group of grouped.values()) {
    const first = group[0]!;
    const distinctRoles = new Set(group.map((row) => row.role));
    let role = first.role;
    if (distinctRoles.size > 1) {
      const signature = membershipSignature(group);
      if (
        !first.effective_role ||
        first.membership_signature !== signature ||
        !distinctRoles.has(first.effective_role)
      ) {
        throw new Error(
          `Access to ${first.organisation_name} requires an audited owner role-conflict decision.`,
        );
      }
      role = first.effective_role;
    }
    organisations.push({
      organisationId: first.organisation_id,
      organisationName: first.organisation_name,
      coordOrgId: first.coord_org_id,
      role,
      membershipIds: group.map((row) => row.membership_id),
      networkAccountIds: group.map((row) => row.network_account_id),
      networkAccountNames: group.map((row) => row.network_account_name),
      identityUserIds: [...new Set(group.map((row) => row.identity_user_id))],
    });
  }

  return {
    personId: identity.person_id,
    userId: session.user.id,
    sessionId: session.session.id,
    email: session.user.email,
    name: identity.display_name,
    identityName: session.user.name,
    sessionExpiresAt,
    organisations,
  };
}

export async function requireSession() {
  const session = await auth.api.getSession({
    headers: await headers(),
  });
  if (!session) {
    redirect("/sign-in");
  }
  return session;
}

export async function requirePersonSessionContext(): Promise<PersonSessionContext> {
  return resolveSessionContext(await requireSession());
}

export function organisationContext(
  person: PersonSessionContext,
  organisationId: string,
): ConsoleContext {
  const organisation = person.organisations.find(
    (candidate) => candidate.organisationId === organisationId,
  );
  if (!organisation) {
    throw new Error("That network account is no longer accessible.");
  }
  return {
    ...person,
    ...organisation,
    networkAccountId: organisation.networkAccountIds[0]!,
    networkAccountName:
      organisation.networkAccountNames[0] ?? organisation.organisationName,
  };
}

/** Resolve an explicit organisation with a fresh membership check. */
export async function requireOrganisationContext(
  organisationId: string,
): Promise<ConsoleContext> {
  return organisationContext(
    await requirePersonSessionContext(),
    organisationId,
  );
}

/** Resolve the workspace cookie for organisation-scoped pages only. */
export async function requireConsoleContext(): Promise<ConsoleContext> {
  const person = await requirePersonSessionContext();
  const selected = (await cookies()).get(ORGANISATION_COOKIE)?.value;
  const organisationId = person.organisations.some(
    (organisation) => organisation.organisationId === selected,
  )
    ? selected!
    : person.organisations[0]!.organisationId;
  return organisationContext(person, organisationId);
}
