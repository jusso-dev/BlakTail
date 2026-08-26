import { ConsoleShell } from "@/components/console-shell";
import { PageHeader } from "@/components/page-header";
import { getCoordHealth } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

export default async function StatusPage() {
  const ctx = await requireConsoleContext();
  let health: Awaited<ReturnType<typeof getCoordHealth>> | null = null;
  let error: string | null = null;
  try {
    health = await getCoordHealth();
  } catch (err) {
    error =
      err instanceof Error ? err.message : "Could not reach the coordinator.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/status">
      <div className="stack">
        <PageHeader
          title="Status"
          description="Health of the onshore coordinator that holds your tailnet state."
        />
        <div className="panel stack">
          {error ? <p className="error">{error}</p> : null}
          {health ? (
            <>
              <p>
                <strong>Status:</strong>{" "}
                <span className="badge online">{health.status}</span>
              </p>
              <p className="region-mark">
                <span className="region-dot" aria-hidden="true" />
                <strong>Onshore</strong>
                <span>Sydney, Australia · AU · ap-southeast-2</span>
              </p>
              <p className="muted">
                Public readiness returns only availability. Region and component
                diagnostics stay in the protected operator configuration and
                support bundle.
              </p>
            </>
          ) : null}
        </div>
      </div>
    </ConsoleShell>
  );
}
