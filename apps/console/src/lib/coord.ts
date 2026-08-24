import "server-only";

import { signCoordAssertion } from "./coord-assertion";
import {
  organisationContext,
  type ConsoleContext,
  type PersonSessionContext,
} from "./session";

export type DeviceTag = "office" | "ranger" | "store";

export type CoordNode = {
  id: string;
  name: string;
  display_name: string | null;
  wg_public_key: string;
  endpoint: string | null;
  allowed_ips: string[];
  advertised_routes: string[];
  approved_routes: string[];
  dns_name: string;
  user_id: string;
  user_role: string;
  tags: DeviceTag[];
  created_at: number;
  credential_expires_at: number;
  expired: boolean;
  expires_soon: boolean;
  revoked: boolean;
};

export type NetworkNode = CoordNode & {
  organisation_id: string;
  organisation_name: string;
  network_account_id: string;
  network_account_name: string;
  effective_role: ConsoleContext["role"];
};

export type JoinKeyResult = {
  id: string;
  key: string;
  expires_at: number;
  single_use: boolean;
};

export type DeviceAuthorizationPreview = {
  name: string;
  public_key_fingerprint: string;
  expires_at: number;
  approved: boolean;
};

export type CoordHealth = {
  status: string;
};

export type AuditEvent = {
  id: string;
  actor_user_id: string;
  actor_name: string;
  actor_email: string;
  actor_role: string;
  action: string;
  target_type: string;
  target_id: string | null;
  details: unknown;
  created_at: number;
};

function coordBaseUrl(): string {
  const url = process.env.COORD_BASE_URL;
  if (!url) {
    throw new Error("COORD_BASE_URL is required (HTTPS coordinator URL).");
  }
  return url.replace(/\/$/, "");
}

async function coordFetch(
  path: string,
  init: RequestInit & { ctx?: ConsoleContext } = {},
): Promise<Response> {
  const { ctx, headers: initHeaders, ...rest } = init;
  const headers = new Headers(initHeaders);
  if (ctx) {
    headers.set("Authorization", `Bearer ${signCoordAssertion(ctx)}`);
  }
  if (!headers.has("content-type") && rest.body) {
    headers.set("content-type", "application/json");
  }
  return fetch(`${coordBaseUrl()}${path}`, {
    ...rest,
    headers,
    cache: "no-store",
  });
}

async function readError(res: Response): Promise<string> {
  try {
    const body = (await res.json()) as { error?: string };
    if (body.error) return body.error;
  } catch {
    /* ignore */
  }
  return `Coordinator returned ${res.status}`;
}

export async function getCoordHealth(): Promise<CoordHealth> {
  const res = await coordFetch("/health", { method: "GET" });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<CoordHealth>;
}

export async function listNodes(ctx: ConsoleContext): Promise<CoordNode[]> {
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/nodes`, {
    method: "GET",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<CoordNode[]>;
}

export async function listAllNodes(
  person: PersonSessionContext,
): Promise<NetworkNode[]> {
  const groups = await Promise.all(
    person.organisations.map(async (organisation) => {
      const ctx = organisationContext(person, organisation.organisationId);
      const nodes = await listNodes(ctx);
      return nodes.map((node) => ({
        ...node,
        organisation_id: ctx.organisationId,
        organisation_name: ctx.organisationName,
        network_account_id: ctx.networkAccountId,
        network_account_name: ctx.networkAccountName,
        effective_role: ctx.role,
      }));
    }),
  );
  return groups.flat();
}

export async function listAuditEvents(
  ctx: ConsoleContext,
): Promise<AuditEvent[]> {
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/audit?limit=100`, {
    method: "GET",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<AuditEvent[]>;
}

export async function revokeNode(
  ctx: ConsoleContext,
  nodeId: string,
): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot revoke devices.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/nodes/${nodeId}`, {
    method: "DELETE",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export async function updateNodeFriendlyName(
  ctx: ConsoleContext,
  nodeId: string,
  friendlyName: string,
): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot rename devices.");
  }
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/nodes/${nodeId}/friendly-name`,
    {
      method: "PUT",
      ctx,
      body: JSON.stringify({ friendly_name: friendlyName }),
    },
  );
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export async function approveNodeRoutes(
  ctx: ConsoleContext,
  nodeId: string,
  approvedRoutes: string[],
): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot approve subnet or exit-node routes.");
  }
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/nodes/${nodeId}/routes`,
    {
      method: "PUT",
      ctx,
      body: JSON.stringify({ approved_routes: approvedRoutes }),
    },
  );
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export async function mintJoinKey(
  ctx: ConsoleContext,
  input: {
    expiresInSeconds?: number;
    singleUse?: boolean;
    tags?: DeviceTag[];
  },
): Promise<JoinKeyResult> {
  if (ctx.role === "member") {
    throw new Error("Members cannot mint join keys.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/join-keys`, {
    method: "POST",
    ctx,
    body: JSON.stringify({
      expires_in_seconds: input.expiresInSeconds ?? 3600,
      single_use: input.singleUse ?? true,
      tags: input.tags ?? [],
    }),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<JoinKeyResult>;
}

export async function getDeviceAuthorization(
  ctx: ConsoleContext,
  code: string,
): Promise<DeviceAuthorizationPreview> {
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/device-authorizations/${encodeURIComponent(code)}`,
    {
      method: "GET",
      ctx,
    },
  );
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<DeviceAuthorizationPreview>;
}

export async function approveDeviceAuthorization(
  ctx: ConsoleContext,
  code: string,
  tags: DeviceTag[],
): Promise<{ status: string; expires_at: number }> {
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/device-authorizations/${encodeURIComponent(code)}`,
    {
      method: "POST",
      ctx,
      body: JSON.stringify({ tags }),
    },
  );
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<{ status: string; expires_at: number }>;
}

export async function getAcl(ctx: ConsoleContext): Promise<unknown> {
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/acl`, {
    method: "GET",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json();
}

export async function putAcl(ctx: ConsoleContext, acl: unknown): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot edit ACL rules.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/acl`, {
    method: "PUT",
    ctx,
    body: JSON.stringify(acl),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export { roleLabel } from "./roles";
