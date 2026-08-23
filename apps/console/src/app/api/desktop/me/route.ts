import { NextResponse } from "next/server";
import {
  requireConsoleContextFromSession,
  sessionFromBearer,
} from "@/lib/desktop-auth";

export async function GET(request: Request) {
  try {
    const session = await sessionFromBearer(request);
    if (!session) {
      return NextResponse.json({ error: "Unauthorised" }, { status: 401 });
    }
    const ctx = await requireConsoleContextFromSession(session);
    return NextResponse.json({
      email: ctx.email,
      organisationName: ctx.organisationName,
      role: ctx.role,
      coordinatorUrl: process.env.COORD_BASE_URL?.replace(/\/$/, "") ?? null,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Could not load desktop session.";
    return NextResponse.json({ error: message }, { status: 400 });
  }
}
