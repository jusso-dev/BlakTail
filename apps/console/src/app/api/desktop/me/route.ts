import { NextResponse } from "next/server";
import {
  requireConsoleContextFromSession,
  sessionFromBearer,
} from "@/lib/desktop-auth";
import { activeOrganisationIdFromRequest } from "@/lib/session";

export async function GET(request: Request) {
  try {
    const session = await sessionFromBearer(request);
    if (!session) {
      return NextResponse.json({ error: "Unauthorised" }, { status: 401 });
    }
    const ctx = await requireConsoleContextFromSession(
      session,
      activeOrganisationIdFromRequest(request),
    );
    return NextResponse.json({
      email: ctx.email,
      organisationId: ctx.organisationId,
      organisationName: ctx.organisationName,
      role: ctx.role,
      organisations: ctx.organisations.map((organisation) => ({
        id: organisation.organisationId,
        name: organisation.organisationName,
        role: organisation.role,
      })),
      coordinatorUrl: process.env.COORD_BASE_URL?.replace(/\/$/, "") ?? null,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Could not load desktop session.";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
