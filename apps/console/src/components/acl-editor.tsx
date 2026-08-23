"use client";

import { useState, useTransition } from "react";
import { saveAclAction } from "@/app/actions";
import { canMutateTailnet, type OrgRole } from "@/lib/roles";

export function AclEditor({
  initialAcl,
  role,
}: {
  initialAcl: string;
  role: OrgRole;
}) {
  const [message, setMessage] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const canMutate = canMutateTailnet(role);

  return (
    <div className="stack">
      <form
        className="stack"
        onSubmit={(event) => {
          event.preventDefault();
          if (!canMutate) return;
          const formData = new FormData(event.currentTarget);
          setMessage(null);
          startTransition(async () => {
            const result = await saveAclAction(formData);
            setMessage(
              result.ok ? "ACL saved on the coordinator." : result.error,
            );
          });
        }}
      >
        <label>
          ACL JSON
          <textarea
            name="aclJson"
            rows={16}
            defaultValue={initialAcl}
            readOnly={!canMutate}
            spellCheck={false}
            className="mono"
          />
        </label>
        {canMutate ? (
          <button type="submit" disabled={pending}>
            {pending ? "Saving…" : "Save ACL"}
          </button>
        ) : (
          <p className="muted">
            Members can read ACL rules but cannot change them.
          </p>
        )}
      </form>
      {message ? (
        <p className={message.startsWith("ACL saved") ? "muted" : "error"}>
          {message}
        </p>
      ) : null}
    </div>
  );
}
