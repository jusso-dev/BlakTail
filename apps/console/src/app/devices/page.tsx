import { ConsoleShell } from "@/components/console-shell";
import { DeviceActions } from "@/components/device-actions";
import { listAllNodes } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  const inventory = await listAllNodes(ctx);
  const blockedErrors = ctx.blockedOrganisations.map(
    (organisation) =>
      `${organisation.organisationName}: an owner must resolve the linked-account role conflict.`,
  );

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <div>
          <h1>All networks</h1>
          <p className="lead">
            Every machine reachable through your linked network accounts.
            Changes are authorised again against each machine&apos;s owning
            organisation.
          </p>
        </div>
        <div className="panel">
          {[...blockedErrors, ...inventory.errors].map((error) => (
            <p className="error" key={error}>
              {error}
            </p>
          ))}
          <DeviceActions nodes={inventory.nodes} />
        </div>
      </div>
    </ConsoleShell>
  );
}
