import { ConsoleShell } from "@/components/console-shell";
import { DeviceActions } from "@/components/device-actions";
import { PageHeader } from "@/components/page-header";
import { PathMotif } from "@/components/path-motif";
import { listAllNodes } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  const inventory = await listAllNodes(ctx);
  const blockedErrors = ctx.blockedOrganisations.map(
    (organisation) =>
      `${organisation.organisationName}: an owner must resolve the linked-account role conflict.`,
  );
  const live = inventory.nodes.filter((node) => !node.deleted);
  const online = live.filter((node) => node.online && !node.revoked).length;
  const networks = new Set(live.map((node) => node.organisation_id)).size;

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <PageHeader
          eyebrow="Your network"
          title="All networks"
          description="Every machine reachable through your linked network accounts. Changes are authorised again against each machine's owning organisation."
        />
        <div className="overview">
          <div className="panel overview-copy">
            <p className="eyebrow">Connected places</p>
            <div className="overview-stats">
              <div className="overview-stat">
                <strong>{live.length}</strong>
                <span>Devices</span>
              </div>
              <div className="overview-stat">
                <strong>{online}</strong>
                <span>Online</span>
              </div>
              <div className="overview-stat">
                <strong>{networks || ctx.organisations.length}</strong>
                <span>Networks</span>
              </div>
            </div>
          </div>
          <div className="overview-path" aria-hidden="true">
            <PathMotif />
          </div>
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
