import "server-only";

import type { AuditEvent } from "./coord";
import { rawSqlClient } from "./db/client";
import type { ConsoleContext } from "./session";

export async function listConsoleAuditEvents(
  ctx: ConsoleContext,
): Promise<AuditEvent[]> {
  const sql = rawSqlClient();
  const rows = await sql`
    SELECT id, actor_user_id, actor_email, actor_role, action,
      result, target_type, target_id, details, created_at
    FROM console_audit_event
    WHERE organisation_id = ${ctx.organisationId}
      OR (
        organisation_id IS NULL
        AND actor_user_id IN (
          SELECT user_id FROM person_login_identity
          WHERE person_id = ${ctx.personId}
        )
      )
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
