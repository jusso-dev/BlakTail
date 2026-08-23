import { ConsoleShell } from "@/components/console-shell";
import { listAuditEvents } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

function actor(event: Awaited<ReturnType<typeof listAuditEvents>>[number]) {
  return event.actor_email || event.actor_name || event.actor_user_id;
}

export default async function AuditPage() {
  const ctx = await requireConsoleContext();
  let events: Awaited<ReturnType<typeof listAuditEvents>> = [];
  let error: string | null = null;
  try {
    events = await listAuditEvents(ctx);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load audit events.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/audit">
      <div className="stack">
        <div>
          <h1>Audit log</h1>
          <p className="lead">
            Security and administration changes for {ctx.organisationName}.
            Times are shown in UTC.
          </p>
        </div>
        <div className="panel table-wrap">
          {error ? <p className="error">{error}</p> : null}
          {!error && events.length === 0 ? (
            <p className="muted">No audited changes yet.</p>
          ) : null}
          {events.length > 0 ? (
            <table className="table">
              <thead>
                <tr>
                  <th>When (UTC)</th>
                  <th>Actor</th>
                  <th>Action</th>
                  <th>Target</th>
                  <th>Details</th>
                </tr>
              </thead>
              <tbody>
                {events.map((event) => (
                  <tr key={event.id}>
                    <td className="mono">
                      {new Date(event.created_at * 1000).toISOString()}
                    </td>
                    <td>
                      <div>{actor(event)}</div>
                      <div className="muted">{event.actor_role}</div>
                    </td>
                    <td className="mono">{event.action}</td>
                    <td>
                      <div>{event.target_type}</div>
                      {event.target_id ? (
                        <div className="mono">{event.target_id}</div>
                      ) : null}
                    </td>
                    <td>
                      <code className="mono audit-details">
                        {JSON.stringify(event.details, null, 2)}
                      </code>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : null}
        </div>
      </div>
    </ConsoleShell>
  );
}
