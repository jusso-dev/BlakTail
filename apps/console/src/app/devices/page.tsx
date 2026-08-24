import { ConsoleShell } from "@/components/console-shell";
import { DeviceActions } from "@/components/device-actions";
import { listAllNodes } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  let nodes: Awaited<ReturnType<typeof listAllNodes>> = [];
  let error: string | null = null;
  try {
    nodes = await listAllNodes(ctx);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load devices.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <div>
          <h1>All networks</h1>
          <p className="lead">
            Every machine reachable through your linked network accounts.
            Changes are authorised again against the machine row's owning
            organisation.
          </p>
        </div>
        <div className="panel">
          {error ? <p className="error">{error}</p> : null}
          <DeviceActions nodes={nodes} />
        </div>
      </div>
    </ConsoleShell>
  );
}
