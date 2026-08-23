import { ConsoleShell } from "@/components/console-shell";
import { JoinKeyForm } from "@/components/join-key-form";
import { requireConsoleContext } from "@/lib/session";

export default async function JoinKeysPage() {
  const ctx = await requireConsoleContext();

  return (
    <ConsoleShell ctx={ctx} current="/join-keys">
      <div className="stack">
        <div>
          <h1>Join keys</h1>
          <p className="lead">
            Mint a short-lived key for a new device. The coordinator stores only
            a hash. Show the secret to the operator once, then put it away.
          </p>
        </div>
        <div className="panel">
          <JoinKeyForm role={ctx.role} />
        </div>
      </div>
    </ConsoleShell>
  );
}
