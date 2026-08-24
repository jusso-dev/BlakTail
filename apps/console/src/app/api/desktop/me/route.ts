import { NextResponse } from "next/server";
import {
  requirePersonContextFromSession,
  sessionFromBearer,
} from "@/lib/desktop-auth";

export async function GET(request: Request) {
  try {
    const session = await sessionFromBearer(request);
    if (!session) {
      return NextResponse.json({ error: "Unauthorised" }, { status: 401 });
    }
    const ctx = await requirePersonContextFromSession(session);
    const primary = ctx.organisations[0]!;
    return NextResponse.json({
      email: ctx.email,
      organisationName: primary.organisationName,
      role: primary.role,
      organisations: ctx.organisations.map((organisation) => ({
        id: organisation.organisationId,
        name: organisation.organisationName,
        role: organisation.role,
        networkAccounts: organisation.networkAccountIds.map((id, index) => ({
          id,
          name:
            organisation.networkAccountNames[index] ??
            organisation.organisationName,
        })),
      })),
      coordinatorUrl: process.env.COORD_BASE_URL?.replace(/\/$/, "") ?? null,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Could not load desktop session.";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
