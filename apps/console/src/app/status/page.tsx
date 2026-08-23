import { ConsoleShell } from "@/components/console-shell";
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
        <div>
          <h1>Status</h1>
          <p className="lead">
            Health of the onshore coordinator that holds your tailnet state.
          </p>
        </div>
        <div className="panel stack">
          {error ? <p className="error">{error}</p> : null}
          {health ? (
            <>
              <p>
                <strong>Status:</strong> {health.status}
              </p>
              <p>
                <strong>Region:</strong>{" "}
                <span className="mono">{health.region}</span>
              </p>
              <p className="muted">
                Region must be set on the coordinator host. Empty region values
                are refused at startup.
              </p>
            </>
          ) : null}
        </div>
      </div>
    </ConsoleShell>
  );
}
