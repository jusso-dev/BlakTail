import "server-only";

import type { AuditEvent } from "./coord";
import { rawSqlClient } from "./db/client";
import type { ConsoleContext } from "./session";

type ConsoleAuditRow = {
  id: string;
  actor_user_id: string | null;
  actor_email: string;
  actor_role: string;
  action: string;
  result: string;
  target_type: string;
  target_id: string | null;
  details: Record<string, unknown>;
  created_at: Date | string;
};

export async function listConsoleAuditEvents(
  ctx: ConsoleContext,
): Promise<AuditEvent[]> {
  const sql = rawSqlClient();
  const rows = await sql<ConsoleAuditRow[]>`
    SELECT id, actor_user_id, actor_email, actor_role, action,
      result, target_type, target_id, details, created_at
    FROM console_audit_event
    WHERE organisation_id = ${ctx.organisationId}
    ORDER BY created_at DESC, id DESC
    LIMIT 100
  `;
  return rows.map((row) => ({
    id: `console:${row.id}`,
    actor_user_id: row.actor_user_id ?? "operator",
    actor_name: "",
    actor_email: row.actor_email,
    actor_role: row.actor_role,
    action: row.action,
    target_type: row.target_type,
    target_id: row.target_id,
    details: { ...row.details, result: row.result, source: "console" },
    created_at: Math.floor(new Date(row.created_at).getTime() / 1000),
  }));
}
