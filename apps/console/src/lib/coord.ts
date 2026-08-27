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
  deleted?: boolean;
  online?: boolean;
  last_seen_at?: number | null;
  os?: string | null;
  os_version?: string | null;
  agent_version?: string | null;
  hostname?: string | null;
  capabilities?: string[];
  ephemeral?: boolean;
};

export type ApiClient = {
  id: string;
  name: string;
  token_prefix: string;
  scopes: string[];
  created_at: number;
  last_used_at: number | null;
  expires_at: number | null;
  revoked: boolean;
};

export type ApiClientCreated = ApiClient & {
  token: string;
};

export type NetworkNode = CoordNode & {
  organisation_id: string;
  organisation_name: string;
  network_account_id: string;
  network_account_name: string;
  effective_role: ConsoleContext["role"];
};

export type NetworkNodeInventory = {
  nodes: NetworkNode[];
  errors: string[];
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
): Promise<NetworkNodeInventory> {
  const inventories = await Promise.all(
    person.organisations.map(async (organisation) => {
      const ctx = organisationContext(person, organisation.organisationId);
      try {
        const nodes = await listNodes(ctx);
        return {
          nodes: nodes.map((node) => {
            const identityIndex = organisation.identityUserIds.indexOf(
              node.user_id,
            );
            const accountIndex = identityIndex < 0 ? 0 : identityIndex;
            return {
              ...node,
              organisation_id: ctx.organisationId,
              organisation_name: ctx.organisationName,
              network_account_id:
                organisation.networkAccountIds[accountIndex] ??
                ctx.networkAccountId,
              network_account_name:
                organisation.networkAccountNames[accountIndex] ??
                ctx.networkAccountName,
              effective_role: ctx.role,
            };
          }),
          error: null,
        };
      } catch (error) {
        return {
          nodes: [],
          error: `${organisation.organisationName}: ${
            error instanceof Error
              ? error.message
              : "Could not load devices."
          }`,
        };
      }
    }),
  );
  return {
    nodes: inventories
      .flatMap((inventory) => inventory.nodes)
      .sort(
        (left, right) =>
          left.organisation_name.localeCompare(right.organisation_name) ||
          (left.display_name || left.name).localeCompare(
            right.display_name || right.name,
          ),
      ),
    errors: inventories.flatMap((inventory) =>
      inventory.error ? [inventory.error] : [],
    ),
  };
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

export async function tombstoneNode(
  ctx: ConsoleContext,
  nodeId: string,
): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot delete devices.");
  }
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/nodes/${nodeId}/tombstone`,
    {
      method: "POST",
      ctx,
    },
  );
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export async function listApiClients(
  ctx: ConsoleContext,
): Promise<ApiClient[]> {
  if (ctx.role === "member") {
    throw new Error("Members cannot list automation credentials.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/api-clients`, {
    method: "GET",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<ApiClient[]>;
}

export async function createApiClient(
  ctx: ConsoleContext,
  input: { name: string; scopes: string[] },
): Promise<ApiClientCreated> {
  if (ctx.role !== "owner") {
    throw new Error("Only owners can create automation credentials.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/api-clients`, {
    method: "POST",
    ctx,
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<ApiClientCreated>;
}

export async function revokeApiClient(
  ctx: ConsoleContext,
  clientId: string,
): Promise<void> {
  if (ctx.role !== "owner") {
    throw new Error("Only owners can revoke automation credentials.");
  }
  const res = await coordFetch(
    `/v1/orgs/${ctx.coordOrgId}/api-clients/${clientId}`,
    {
      method: "DELETE",
      ctx,
    },
  );
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

export type OrgDnsSettings = {
  managed: boolean;
  global_resolvers: string[];
  split: { suffix: string; resolvers: string[] }[];
  search_domains: string[];
  records: { name: string; type: "A" | "AAAA"; value: string }[];
};

export type OrgDnsResponse = {
  revision: number;
  etag: string;
  has_previous: boolean;
  magic_dns_suffix: string;
  dns: OrgDnsSettings;
};

export async function getDns(ctx: ConsoleContext): Promise<OrgDnsResponse> {
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/dns`, {
    method: "GET",
    ctx,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<OrgDnsResponse>;
}

export async function putDns(
  ctx: ConsoleContext,
  body: { dns?: OrgDnsSettings; rollback?: boolean },
  etag: string,
): Promise<OrgDnsResponse> {
  if (ctx.role === "member") {
    throw new Error("Members cannot publish DNS settings.");
  }
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/dns`, {
    method: "PUT",
    ctx,
    headers: { "If-Match": etag },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<OrgDnsResponse>;
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
