import { ConsoleShell } from "@/components/console-shell";
import { DeviceActions } from "@/components/device-actions";
import { PageHeader } from "@/components/page-header";
import { WgOnlyManager } from "@/components/wg-only-manager";
import { listAllNodes, listAllWgOnlyPeers } from "@/lib/coord";
import { listMemberships } from "@/lib/oidc";
import { requireConsoleContext } from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  const [inventory, memberships, unmanaged] = await Promise.all([
    listAllNodes(ctx),
    Promise.all(
      ctx.organisations.map((organisation) =>
        listMemberships(organisation.organisationId).catch(() => []),
      ),
    ).then((rows) => rows.flat().filter((row) => row.status === "active")),
    listAllWgOnlyPeers(ctx),
  ]);
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
          title="Devices"
          description="Every machine you can reach through your linked network accounts. Changes stay scoped to the organisation that owns the device."
        />
        <p className="summary-line">
          {live.length} devices · {online} online ·{" "}
          {networks || ctx.organisations.length} networks
        </p>
        <div className="panel table-panel">
          {[...blockedErrors, ...inventory.errors].map((error) => (
            <p className="error" key={error}>
              {error}
            </p>
          ))}
          <DeviceActions
            nodes={inventory.nodes}
            people={memberships.map((row) => ({
              userId: row.userId,
              email: row.email,
              name: row.name,
            }))}
          />
        </div>
        <WgOnlyManager
          peers={unmanaged.peers}
          errors={unmanaged.errors}
          role={ctx.role}
          organisationId={ctx.organisationId}
        />
      </div>
    </ConsoleShell>
  );
}
