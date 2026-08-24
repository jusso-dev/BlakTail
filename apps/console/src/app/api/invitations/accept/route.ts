import { createHash } from "node:crypto";
import { acceptInvitation, InvitationError } from "@/lib/invitations";
import {
  assertSameOrigin,
  consumeRateLimit,
  requestRateLimitIdentity,
  RequestSecurityError,
} from "@/lib/request-security";

function errorResponse(error: unknown): Response {
  if (error instanceof RequestSecurityError) {
    const headers = error.retryAfter
      ? { "retry-after": String(error.retryAfter) }
      : undefined;
    return Response.json({ error: error.message }, { status: error.status, headers });
  }
  if (error instanceof InvitationError) {
    return Response.json({ error: error.message }, { status: error.status });
  }
  console.error("Invitation acceptance failed", error);
  return Response.json({ error: "Invitation failed." }, { status: 500 });
}

export async function POST(request: Request): Promise<Response> {
  try {
    assertSameOrigin(request);
    const body = (await request.json()) as Record<string, unknown>;
    const token = typeof body.token === "string" ? body.token : "";
    const tokenKey = createHash("sha256").update(token).digest("hex");
    await consumeRateLimit(
      `invitation:accept:${tokenKey}:${requestRateLimitIdentity(request)}`,
      15 * 60,
      10,
    );
    const result = await acceptInvitation({
      token,
      email: typeof body.email === "string" ? body.email : "",
      name: typeof body.name === "string" ? body.name : "",
      password: typeof body.password === "string" ? body.password : "",
    });
    return Response.json(
      { status: "accepted", email: result.email },
      { status: 201 },
    );
  } catch (error) {
    return errorResponse(error);
  }
}
