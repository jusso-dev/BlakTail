import { AclEditor } from "@/components/acl-editor";
import { ConsoleShell } from "@/components/console-shell";
import { PageHeader } from "@/components/page-header";
import { getAcl } from "@/lib/coord";
import { listMemberships } from "@/lib/oidc";
import { requireConsoleContext } from "@/lib/session";

export default async function AclsPage() {
  const ctx = await requireConsoleContext();
  let initialAcl = '{\n  "groups": {},\n  "rules": []\n}';
  let error: string | null = null;
  try {
    const acl = await getAcl(ctx);
    initialAcl = JSON.stringify(acl, null, 2);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load access policy.";
  }
  const memberships = (await listMemberships(ctx.organisationId).catch(() => []))
    .filter((row) => row.status === "active");

  return (
    <ConsoleShell ctx={ctx} current="/acls">
      <div className="stack">
        <PageHeader
          title="Access"
          description="New organisations start deny-all. Existing documents keep the visible same-tag legacy default until you switch them to deny."
        />
        <div className="panel stack">
          {error ? <p className="error">{error}</p> : null}
          <AclEditor
            initialAcl={initialAcl}
            role={ctx.role}
            people={memberships.map((row) => ({
              userId: row.userId,
              email: row.email,
              name: row.name,
            }))}
          />
        </div>
      </div>
    </ConsoleShell>
  );
}
