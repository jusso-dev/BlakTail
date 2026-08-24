import { auth, type Session } from "@/lib/auth";
import {
  organisationContext,
  resolveSessionContext,
  type ConsoleContext,
  type PersonSessionContext,
} from "@/lib/session";

/**
 * Resolve a Better Auth session from an Authorization Bearer token issued to the Mac app.
 * Cookie name matches Better Auth defaults; try the Secure prefix used on HTTPS consoles.
 */
export async function sessionFromBearer(
  request: Request,
): Promise<Session | null> {
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

export async function requirePersonContextFromSession(
  session: Session,
): Promise<PersonSessionContext> {
  return resolveSessionContext(session);
}

export async function requireConsoleContextFromSession(
  session: Session,
  organisationId?: string,
): Promise<ConsoleContext> {
  const person = await resolveSessionContext(session);
  return organisationContext(
    person,
    organisationId ?? person.organisations[0]!.organisationId,
  );
}
