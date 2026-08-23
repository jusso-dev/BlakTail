"use server";

import { revalidatePath } from "next/cache";
import {
  approveDeviceAuthorization,
  getAcl,
  mintJoinKey,
  putAcl,
  revokeNode,
  type DeviceTag,
} from "@/lib/coord";
import { canMutateTailnet, requireConsoleContext } from "@/lib/session";

export type ActionResult<T = void> =
  | { ok: true; data: T }
  | { ok: false; error: string };

function isDeviceTag(value: string): value is DeviceTag {
  return value === "office" || value === "ranger" || value === "store";
}

export async function mintJoinKeyAction(
  formData: FormData,
): Promise<ActionResult<{ key: string; expiresAt: number }>> {
  try {
    const ctx = await requireConsoleContext();
    if (!canMutateTailnet(ctx.role)) {
      return { ok: false, error: "Only owners and admins can mint join keys." };
    }
    const expiresInSeconds = Number(formData.get("expiresInSeconds") ?? 3600);
    const singleUse = formData.get("singleUse") !== "false";
    const tags = formData.getAll("tags").map(String).filter(isDeviceTag);
    const result = await mintJoinKey(ctx, {
      expiresInSeconds,
      singleUse,
      tags,
    });
    revalidatePath("/join-keys");
    return {
      ok: true,
      data: { key: result.key, expiresAt: result.expires_at },
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not mint join key.",
    };
  }
}

export async function approveDeviceAuthorizationAction(
  formData: FormData,
): Promise<ActionResult<{ expiresAt: number }>> {
  try {
    const ctx = await requireConsoleContext();
    const code = String(formData.get("code") ?? "").trim();
    if (!code) {
      return { ok: false, error: "Device code is required." };
    }
    const tags = canMutateTailnet(ctx.role)
      ? formData.getAll("tags").map(String).filter(isDeviceTag)
      : [];
    const result = await approveDeviceAuthorization(ctx, code, tags);
    revalidatePath("/enroll");
    return { ok: true, data: { expiresAt: result.expires_at } };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof Error
          ? error.message
          : "Could not approve device enrollment.",
    };
  }
}

export async function revokeDeviceAction(
  formData: FormData,
): Promise<ActionResult> {
  try {
    const ctx = await requireConsoleContext();
    if (!canMutateTailnet(ctx.role)) {
      return { ok: false, error: "Only owners and admins can revoke devices." };
    }
    const nodeId = String(formData.get("nodeId") ?? "");
    if (!nodeId) {
      return { ok: false, error: "Choose a device to revoke." };
    }
    await revokeNode(ctx, nodeId);
    revalidatePath("/devices");
    return { ok: true, data: undefined };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not revoke device.",
    };
  }
}

export async function saveAclAction(formData: FormData): Promise<ActionResult> {
  try {
    const ctx = await requireConsoleContext();
    if (!canMutateTailnet(ctx.role)) {
      return { ok: false, error: "Only owners and admins can edit ACL rules." };
    }
    const raw = String(formData.get("aclJson") ?? "");
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      return { ok: false, error: "ACL must be valid JSON." };
    }
    await putAcl(ctx, parsed);
    revalidatePath("/acls");
    return { ok: true, data: undefined };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not save ACL.",
    };
  }
}

export async function loadAclAction(): Promise<ActionResult<unknown>> {
  try {
    const ctx = await requireConsoleContext();
    return { ok: true, data: await getAcl(ctx) };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not load ACL.",
    };
  }
}
