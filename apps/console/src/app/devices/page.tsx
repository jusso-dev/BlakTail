import { ConsoleShell } from "@/components/console-shell";
import {
  DeviceActions,
  type InventoryNode,
} from "@/components/device-actions";
import { listNodes } from "@/lib/coord";
import {
  canMutateTailnet,
  contextForOrganisation,
  requireConsoleContext,
} from "@/lib/session";

export default async function DevicesPage() {
  const ctx = await requireConsoleContext();
  const inventories = await Promise.all(
    ctx.organisations.map(async (organisation) => {
      const organisationContext = contextForOrganisation(
        ctx,
        organisation.organisationId,
      );
      try {
        const nodes = await listNodes(organisationContext);
        return {
          nodes: nodes.map(
            (node): InventoryNode => ({
              ...node,
              organisationId: organisation.organisationId,
              organisationName: organisation.organisationName,
              canMutate: canMutateTailnet(organisation.role),
            }),
          ),
          error: null,
        };
      } catch (error) {
        return {
          nodes: [],
          error: `${organisation.organisationName}: ${
            error instanceof Error ? error.message : "Could not load devices."
          }`,
        };
      }
    }),
  );
  const nodes = inventories
    .flatMap((inventory) => inventory.nodes)
    .sort(
      (left, right) =>
        left.organisationName.localeCompare(right.organisationName) ||
        (left.display_name || left.name).localeCompare(
          right.display_name || right.name,
        ),
    );
  const errors = inventories.flatMap((inventory) =>
    inventory.error ? [inventory.error] : [],
  );

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <div>
          <h1>All networks</h1>
          <p className="lead">
            Every machine you can access across {ctx.organisations.length}{" "}
            {ctx.organisations.length === 1 ? "workspace" : "workspaces"}, in
            one session. Actions remain isolated to each machine&apos;s network.
          </p>
        </div>
        <div className="panel">
          {errors.map((error) => (
            <p className="error" key={error}>
              {error}
            </p>
          ))}
          <DeviceActions nodes={nodes} />
        </div>
      </div>
    </ConsoleShell>
  );
}
