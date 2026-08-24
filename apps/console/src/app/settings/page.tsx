import { ConsoleShell } from "@/components/console-shell";
import { InvitationManager } from "@/components/invitation-manager";
import { listPendingInvitations } from "@/lib/invitations";
import { roleLabel } from "@/lib/roles";
import { requireConsoleContext } from "@/lib/session";
import { TAGLINE } from "@/lib/tagline";

export default async function SettingsPage() {
  const ctx = await requireConsoleContext();
  const invitations = await listPendingInvitations(ctx);

  return (
    <ConsoleShell ctx={ctx} current="/settings">
      <div className="stack">
        <div>
          <h1>Settings</h1>
          <p className="lead">
            Account and organisation details for this console session.
          </p>
        </div>
        <div className="panel stack">
          <p>
            <strong>Signed in as:</strong> {ctx.name} ({ctx.email})
          </p>
          <p>
            <strong>Role:</strong> {roleLabel(ctx.role)}
          </p>
          <p>
            <strong>Organisation:</strong> {ctx.organisationName}
          </p>
          <p>
            <strong>Accessible workspaces:</strong> {ctx.organisations.length}
          </p>
          <p>
            <strong>Coordinator org id:</strong>{" "}
            <span className="mono">{ctx.coordOrgId}</span>
          </p>
          <p className="tagline">{TAGLINE}</p>
          <p className="muted">
            No analytics leave the building. Fonts are local. Auth lives in
            onshore Postgres. Tailnet authority stays with the Rust
            coordinator. Switching workspaces never signs you out of another
            one.
          </p>
        </div>
        {ctx.role === "owner" ? (
          <InvitationManager
            invitations={invitations.map((invitation) => ({
              id: invitation.id,
              email: invitation.email,
              role: invitation.role,
              expiresAt: invitation.expiresAt.toISOString(),
            }))}
          />
        ) : null}
      </div>
    </ConsoleShell>
  );
}
