import { ConsoleShell } from "@/components/console-shell";
import { DeviceActions } from "@/components/device-actions";
import { listNodes } from "@/lib/coord";
import { canMutateTailnet, requireConsoleContext } from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  let nodes: Awaited<ReturnType<typeof listNodes>> = [];
  let error: string | null = null;
  try {
    nodes = await listNodes(ctx);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load devices.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <div>
          <h1>Devices</h1>
          <p className="lead">
            Nodes enrolled in {ctx.organisationName}. Revoking a device drops it
            from peer lists on the next poll.
          </p>
        </div>
        <div className="panel">
          {error ? <p className="error">{error}</p> : null}
          <DeviceActions
            nodes={nodes}
            canMutate={canMutateTailnet(ctx.role)}
          />
        </div>
      </div>
    </ConsoleShell>
  );
}
