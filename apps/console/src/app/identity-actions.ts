"use server";

import { revalidatePath } from "next/cache";
import {
  beginIdentityLink,
  completeIdentityLink,
  IdentityLinkError,
  recoverIdentity,
  resolveIdentityRoleConflict,
  suspendIdentity,
  unlinkIdentity,
} from "@/lib/identity-links";
import type { OrgRole } from "@/lib/roles";
import { requirePersonSessionContext } from "@/lib/session";

type IdentityActionResult<T = void> =
  | { ok: true; data: T }
  | { ok: false; error: string };

function refreshIdentityViews() {
  revalidatePath("/devices");
  revalidatePath("/settings");
  revalidatePath("/audit");
}

function message(error: unknown, fallback: string) {
  return error instanceof IdentityLinkError ? error.message : fallback;
}

export async function beginIdentityLinkAction(): Promise<
  IdentityActionResult<{ token: string; expiresAt: string }>
> {
  try {
    const ctx = await requirePersonSessionContext();
    const challenge = await beginIdentityLink(ctx);
    revalidatePath("/audit");
    return {
      ok: true,
      data: {
        token: challenge.token,
        expiresAt: challenge.expiresAt.toISOString(),
      },
    };
  } catch (error) {
    return {
      ok: false,
      error: message(error, "Could not start identity linking."),
    };
  }
}

export async function completeIdentityLinkAction(
  formData: FormData,
): Promise<
  IdentityActionResult<{ linked: boolean; ownerResolutionRequired: boolean }>
> {
  try {
    const ctx = await requirePersonSessionContext();
    const result = await completeIdentityLink(ctx, {
      token: String(formData.get("challenge") ?? ""),
      email: String(formData.get("email") ?? ""),
      password: String(formData.get("password") ?? ""),
    });
    refreshIdentityViews();
    return { ok: true, data: result };
  } catch (error) {
    revalidatePath("/audit");
    return {
      ok: false,
      error: message(
        error,
        "Linking could not be completed. Fresh reauthentication or account recovery is required.",
      ),
    };
  }
}

export async function unlinkIdentityAction(
  formData: FormData,
): Promise<IdentityActionResult> {
  try {
    const ctx = await requirePersonSessionContext();
    await unlinkIdentity(
      ctx,
      String(formData.get("identityUserId") ?? ""),
      String(formData.get("currentPassword") ?? ""),
    );
    refreshIdentityViews();
    return { ok: true, data: undefined };
  } catch (error) {
    revalidatePath("/audit");
    return {
      ok: false,
      error: message(error, "Could not unlink that sign-in identity."),
    };
  }
}

export async function suspendIdentityAction(
  formData: FormData,
): Promise<IdentityActionResult> {
  try {
    const ctx = await requirePersonSessionContext();
    await suspendIdentity(
      ctx,
      String(formData.get("identityUserId") ?? ""),
      String(formData.get("currentPassword") ?? ""),
    );
    refreshIdentityViews();
    return { ok: true, data: undefined };
  } catch (error) {
    revalidatePath("/audit");
    return {
      ok: false,
      error: message(error, "Could not revoke that sign-in identity."),
    };
  }
}

export async function recoverIdentityAction(
  formData: FormData,
): Promise<IdentityActionResult> {
  try {
    const ctx = await requirePersonSessionContext();
    await recoverIdentity(
      ctx,
      String(formData.get("identityUserId") ?? ""),
      String(formData.get("currentPassword") ?? ""),
    );
    refreshIdentityViews();
    return { ok: true, data: undefined };
  } catch (error) {
    revalidatePath("/audit");
    return {
      ok: false,
      error: message(error, "Could not recover that sign-in identity."),
    };
  }
}

function role(value: FormDataEntryValue | null): OrgRole | null {
  return value === "owner" || value === "admin" || value === "member"
    ? value
    : null;
}

export async function resolveIdentityRoleConflictAction(
  formData: FormData,
): Promise<IdentityActionResult<{ linked: boolean }>> {
  try {
    const resolvedRole = role(formData.get("resolvedRole"));
    if (!resolvedRole) {
      return { ok: false, error: "Choose one of the existing roles." };
    }
    const ctx = await requirePersonSessionContext();
    const result = await resolveIdentityRoleConflict(
      ctx,
      String(formData.get("conflictId") ?? ""),
      resolvedRole,
    );
    refreshIdentityViews();
    return { ok: true, data: result };
  } catch (error) {
    revalidatePath("/audit");
    return {
      ok: false,
      error: message(error, "Could not resolve that role conflict."),
    };
  }
}

