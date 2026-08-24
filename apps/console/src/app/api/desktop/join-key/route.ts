import { NextResponse } from "next/server";
import { mintJoinKey, type DeviceTag } from "@/lib/coord";
import {
  requireConsoleContextFromSession,
  sessionFromBearer,
} from "@/lib/desktop-auth";
import { canMutateTailnet } from "@/lib/roles";
import { activeOrganisationIdFromRequest } from "@/lib/session";

function isDeviceTag(value: string): value is DeviceTag {
  return value === "office" || value === "ranger" || value === "store";
}

export async function POST(request: Request) {
  try {
    const session = await sessionFromBearer(request);
    if (!session) {
      return NextResponse.json({ error: "Unauthorised" }, { status: 401 });
    }
    const ctx = await requireConsoleContextFromSession(
      session,
      activeOrganisationIdFromRequest(request),
    );
    if (!canMutateTailnet(ctx.role)) {
      return NextResponse.json(
        { error: "Only owners and admins can mint join keys." },
        { status: 403 },
      );
    }

    const body = (await request.json().catch(() => ({}))) as {
      expiresInSeconds?: number;
      singleUse?: boolean;
      tags?: string[];
    };
    const tags = (body.tags ?? []).map(String).filter(isDeviceTag);
    const result = await mintJoinKey(ctx, {
      expiresInSeconds: body.expiresInSeconds ?? 600,
      singleUse: body.singleUse ?? true,
      tags,
    });
    const coordinatorUrl = process.env.COORD_BASE_URL?.replace(/\/$/, "");
    if (!coordinatorUrl) {
      return NextResponse.json(
        { error: "COORD_BASE_URL is not configured on the console." },
        { status: 500 },
      );
    }

    return NextResponse.json({
      key: result.key,
      expiresAt: result.expires_at,
      coordinatorUrl,
    });
  } catch (error) {
    const message =
      error instanceof Error ? error.message : "Could not mint join key.";
    const status = message.toLowerCase().includes("unauthor") ? 401 : 400;
    return NextResponse.json({ error: message }, { status });
  }
}
