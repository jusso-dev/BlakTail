import { ConsoleShell } from "@/components/console-shell";
import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { listAuditEvents } from "@/lib/coord";
import { listConsoleAuditEvents } from "@/lib/console-audit";
import { requireConsoleContext } from "@/lib/session";

function actor(event: Awaited<ReturnType<typeof listAuditEvents>>[number]) {
  return event.actor_email || event.actor_name || event.actor_user_id;
}

function nodeTone(action: string): "success" | "warning" | "danger" | undefined {
  if (/revok|delete|deny|disable|tombstone/i.test(action)) return "danger";
  if (/expir|conflict|fail/i.test(action)) return "warning";
  if (/approv|create|link|save|mint/i.test(action)) return "success";
  return undefined;
}

export default async function AuditPage() {
  const ctx = await requireConsoleContext();
  let events: Awaited<ReturnType<typeof listAuditEvents>> = [];
  let error: string | null = null;
  try {
    const [coordinatorEvents, consoleEvents] = await Promise.all([
      listAuditEvents(ctx),
      listConsoleAuditEvents(ctx),
    ]);
    events = [...coordinatorEvents, ...consoleEvents]
      .sort((left, right) => right.created_at - left.created_at)
      .slice(0, 100);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load audit events.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/audit">
      <div className="stack">
        <PageHeader
          title="Audit log"
          description={`Security and administration changes for ${ctx.organisationName}. Times are shown in UTC.`}
        />
        <div className="panel">
          {error ? <p className="error">{error}</p> : null}
          {!error && events.length === 0 ? (
            <EmptyState
              title="No audited changes yet"
              body="Approvals, invitations, and policy edits will appear here as a trail through this organisation."
            />
          ) : null}
          {events.length > 0 ? (
            <ol className="audit-trail">
              {events.map((event) => (
                <li key={event.id} className="audit-event">
                  <span
                    className={["audit-node", nodeTone(event.action)]
                      .filter(Boolean)
                      .join(" ")}
                    aria-hidden="true"
                  />
                  <strong>{event.action}</strong>
                  <div>
                    {actor(event)}
                    {event.actor_role ? ` · ${event.actor_role}` : ""}
                    {event.target_type ? ` · ${event.target_type}` : ""}
                  </div>
                  <div className="muted mono">
                    {new Date(event.created_at * 1000).toISOString()}
                    {event.target_id ? ` · ${event.target_id}` : ""}
                  </div>
                  <code className="mono audit-details">
                    {JSON.stringify(event.details, null, 2)}
                  </code>
                </li>
              ))}
            </ol>
          ) : null}
        </div>
      </div>
    </ConsoleShell>
  );
}
