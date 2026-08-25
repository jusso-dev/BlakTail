import { NextResponse } from "next/server";
import { changeMembership, OidcError } from "@/lib/oidc";
import { requireConsoleContext } from "@/lib/session";

export async function PATCH(request: Request) {
  try {
    const ctx = await requireConsoleContext();
    const body = (await request.json()) as {
      membershipId?: string;
      role?: "admin" | "member";
      status?: "active" | "suspended" | "removed";
    };
    if (!body.membershipId) {
      return NextResponse.json({ error: "membershipId is required" }, { status: 400 });
    }
    await changeMembership({
      organisationId: ctx.organisationId,
      membershipId: body.membershipId,
      role: body.role,
      status: body.status,
      actorUserId: ctx.userId,
      actorEmail: ctx.email,
      actorRole: ctx.role,
    });
    return NextResponse.json({ ok: true });
  } catch (error) {
    const status = error instanceof OidcError ? 400 : 500;
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "membership update failed" },
      { status },
    );
  }
}
