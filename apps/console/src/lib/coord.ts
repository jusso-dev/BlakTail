import "server-only";

import type { ConsoleContext } from "./session";

export type DeviceTag = "office" | "ranger" | "store";

export type CoordNode = {
  id: string;
  name: string;
  wg_public_key: string;
  endpoint: string | null;
  allowed_ips: string[];
  dns_name: string;
  user_id: string;
  user_role: string;
  tags: DeviceTag[];
  created_at: number;
  revoked: boolean;
};

export type JoinKeyResult = {
  id: string;
  key: string;
  expires_at: number;
  single_use: boolean;
};

export type CoordHealth = {
  status: string;
  region: string;
};

function coordBaseUrl(): string {
  const url = process.env.COORD_BASE_URL;
  if (!url) {
    throw new Error("COORD_BASE_URL is required (HTTPS coordinator URL).");
  }
  return url.replace(/\/$/, "");
}

function syncSecret(): string {
  const secret = process.env.BLAKTAIL_CONSOLE_SYNC_SECRET;
  if (!secret) {
    throw new Error("BLAKTAIL_CONSOLE_SYNC_SECRET is required.");
  }
  return secret;
}

async function coordFetch(
  path: string,
  init: RequestInit & { sessionToken?: string } = {},
): Promise<Response> {
  const { sessionToken, headers: initHeaders, ...rest } = init;
  const headers = new Headers(initHeaders);
  if (sessionToken) {
    headers.set("Authorization", `Bearer ${sessionToken}`);
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

export async function syncSessionToCoord(ctx: ConsoleContext): Promise<void> {
  const res = await coordFetch("/v1/console/sessions", {
    method: "POST",
    headers: {
      "x-blaktail-console-secret": syncSecret(),
    },
    body: JSON.stringify({
      token: ctx.sessionToken,
      org_id: ctx.coordOrgId,
      user_id: ctx.userId,
      role: ctx.role,
      expires_at: Math.floor(ctx.sessionExpiresAt.getTime() / 1000),
    }),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export async function getCoordHealth(): Promise<CoordHealth> {
  const res = await coordFetch("/health", { method: "GET" });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<CoordHealth>;
}

export async function listNodes(ctx: ConsoleContext): Promise<CoordNode[]> {
  await syncSessionToCoord(ctx);
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/nodes`, {
    method: "GET",
    sessionToken: ctx.sessionToken,
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
  return res.json() as Promise<CoordNode[]>;
}

export async function revokeNode(
  ctx: ConsoleContext,
  nodeId: string,
): Promise<void> {
  if (ctx.role === "member") {
    throw new Error("Members cannot revoke devices.");
  }
  await syncSessionToCoord(ctx);
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/nodes/${nodeId}`, {
    method: "DELETE",
    sessionToken: ctx.sessionToken,
  });
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
  await syncSessionToCoord(ctx);
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/join-keys`, {
    method: "POST",
    sessionToken: ctx.sessionToken,
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

export async function getAcl(ctx: ConsoleContext): Promise<unknown> {
  await syncSessionToCoord(ctx);
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/acl`, {
    method: "GET",
    sessionToken: ctx.sessionToken,
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
  await syncSessionToCoord(ctx);
  const res = await coordFetch(`/v1/orgs/${ctx.coordOrgId}/acl`, {
    method: "PUT",
    sessionToken: ctx.sessionToken,
    body: JSON.stringify(acl),
  });
  if (!res.ok) {
    throw new Error(await readError(res));
  }
}

export { roleLabel } from "./roles";
