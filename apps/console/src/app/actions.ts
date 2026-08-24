"use server";

import { revalidatePath } from "next/cache";
import {
  approveDeviceAuthorization,
  approveNodeRoutes,
  getAcl,
  mintJoinKey,
  putAcl,
  revokeNode,
  updateNodeFriendlyName,
  type DeviceTag,
} from "@/lib/coord";
import {
  canMutateTailnet,
  requireConsoleContext,
  requireConsoleContextForOrganisation,
} from "@/lib/session";
import {
  createInvitation,
  InvitationError,
  revokeInvitation,
  type InvitationRole,
} from "@/lib/invitations";

export type ActionResult<T = void> =
  | { ok: true; data: T }
  | { ok: false; error: string };

function isDeviceTag(value: string): value is DeviceTag {
  return value === "office" || value === "ranger" || value === "store";
}

async function deviceActionContext(formData: FormData) {
  return requireConsoleContextForOrganisation(
    String(formData.get("organisationId") ?? ""),
  );
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
    const ctx = await deviceActionContext(formData);
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

export async function updateDeviceFriendlyNameAction(
  formData: FormData,
): Promise<ActionResult<{ friendlyName: string | null }>> {
  try {
    const ctx = await deviceActionContext(formData);
    if (!canMutateTailnet(ctx.role)) {
      return { ok: false, error: "Only owners and admins can rename devices." };
    }
    const nodeId = String(formData.get("nodeId") ?? "");
    if (!nodeId) {
      return { ok: false, error: "Choose a device to rename." };
    }
    const friendlyName = String(formData.get("friendlyName") ?? "").trim();
    if ([...friendlyName].length > 64) {
      return {
        ok: false,
        error: "Friendly names must be 64 characters or fewer.",
      };
    }
    await updateNodeFriendlyName(ctx, nodeId, friendlyName);
    revalidatePath("/devices");
    return {
      ok: true,
      data: { friendlyName: friendlyName || null },
    };
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : "Could not rename device.",
    };
  }
}

export async function approveNodeRoutesAction(
  formData: FormData,
): Promise<ActionResult> {
  try {
    const ctx = await deviceActionContext(formData);
    if (!canMutateTailnet(ctx.role)) {
      return {
        ok: false,
        error: "Only owners and admins can approve subnet or exit-node routes.",
      };
    }
    const nodeId = String(formData.get("nodeId") ?? "");
    if (!nodeId) {
      return { ok: false, error: "Choose a device." };
    }
    const approvedRoutes = formData
      .getAll("approvedRoutes")
      .map(String)
      .filter(Boolean);
    await approveNodeRoutes(ctx, nodeId, approvedRoutes);
    revalidatePath("/devices");
    return { ok: true, data: undefined };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof Error ? error.message : "Could not approve routes.",
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

export async function createInvitationAction(
  formData: FormData,
): Promise<ActionResult<{ id: string; url: string }>> {
  try {
    const ctx = await requireConsoleContext();
    const email = String(formData.get("email") ?? "");
    const requestedRole = String(formData.get("role") ?? "member");
    if (requestedRole !== "admin" && requestedRole !== "member") {
      return { ok: false, error: "Invitation role must be admin or member." };
    }
    const result = await createInvitation(
      ctx,
      email,
      requestedRole as InvitationRole,
    );
    revalidatePath("/settings");
    revalidatePath("/audit");
    return {
      ok: true,
      data: { id: result.invitation.id, url: result.url },
    };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof InvitationError
          ? error.message
          : "Could not create invitation.",
    };
  }
}

export async function revokeInvitationAction(
  formData: FormData,
): Promise<ActionResult> {
  try {
    const ctx = await requireConsoleContext();
    const invitationId = String(formData.get("invitationId") ?? "");
    if (!invitationId) {
      return { ok: false, error: "Choose an invitation to revoke." };
    }
    await revokeInvitation(ctx, invitationId);
    revalidatePath("/settings");
    revalidatePath("/audit");
    return { ok: true, data: undefined };
  } catch (error) {
    return {
      ok: false,
      error:
        error instanceof InvitationError
          ? error.message
          : "Could not revoke invitation.",
    };
  }
}
