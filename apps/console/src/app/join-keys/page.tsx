import { ConsoleShell } from "@/components/console-shell";
import { JoinKeyForm } from "@/components/join-key-form";
import { PageHeader } from "@/components/page-header";
import { requireConsoleContext } from "@/lib/session";

export default async function JoinKeysPage() {
  const ctx = await requireConsoleContext();

  return (
    <ConsoleShell ctx={ctx} current="/join-keys">
      <div className="stack">
        <PageHeader
          title="Join keys"
          description="Mint a short-lived key for a new device. The coordinator stores only a hash. Show the secret to the operator once, then put it away."
        />
        <ol className="ceremony" aria-label="Join-key ceremony">
          <li>Network</li>
          <li aria-current="step">Mint key</li>
          <li>Show once</li>
          <li>Enrol device</li>
        </ol>
        <div className="panel">
          <JoinKeyForm role={ctx.role} />
        </div>
      </div>
    </ConsoleShell>
  );
}
