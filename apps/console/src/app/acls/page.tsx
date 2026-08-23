import { AclEditor } from "@/components/acl-editor";
import { ConsoleShell } from "@/components/console-shell";
import { getAcl } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

export default async function AclsPage() {
  const ctx = await requireConsoleContext();
  let initialAcl = '{\n  "rules": []\n}';
  let error: string | null = null;
  try {
    const acl = await getAcl(ctx);
    initialAcl = JSON.stringify(acl, null, 2);
  } catch (err) {
    error = err instanceof Error ? err.message : "Could not load ACL.";
  }

  return (
    <ConsoleShell ctx={ctx} current="/acls">
      <div className="stack">
        <div>
          <h1>ACL rules</h1>
          <p className="lead">
            Tag and role rules live on the coordinator. Default deny across
            tags. Explicit deny wins.
          </p>
        </div>
        <div className="panel stack">
          {error ? <p className="error">{error}</p> : null}
          <AclEditor initialAcl={initialAcl} role={ctx.role} />
        </div>
      </div>
    </ConsoleShell>
  );
}
