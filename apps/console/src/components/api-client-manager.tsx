"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  createApiClientAction,
  revokeApiClientAction,
} from "@/app/actions";
import type { ApiClient } from "@/lib/coord";

const SCOPES = [
  "devices:read",
  "devices:write",
  "keys:write",
  "routes:write",
  "policy:write",
  "audit:read",
  "status:read",
] as const;

export function ApiClientManager({ clients }: { clients: ApiClient[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [shownOnce, setShownOnce] = useState<string | null>(null);

  return (
    <div className="panel stack">
      <div>
        <h2>Automation credentials</h2>
        <p className="muted">
          Organisation-scoped tokens for the versioned admin API. The secret is
          shown once and stored as a hash. Send{" "}
          <span className="mono">X-BlakTail-Organisation</span> with every
          request.
        </p>
      </div>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          const form = new FormData(event.currentTarget);
          setError(null);
          setShownOnce(null);
          startTransition(async () => {
            const result = await createApiClientAction(form);
            if (!result.ok) {
              setError(result.error);
              return;
            }
            setShownOnce(result.data.token);
            router.refresh();
          });
        }}
      >
        <label>
          Name
          <input name="name" required maxLength={64} />
        </label>
        <fieldset>
          <legend>Scopes</legend>
          {SCOPES.map((scope) => (
            <label key={scope} className="route-option mono">
              <input type="checkbox" name="scopes" value={scope} defaultChecked={scope === "status:read" || scope === "devices:read"} />
              {scope}
            </label>
          ))}
        </fieldset>
        <button type="submit" disabled={pending}>
          {pending ? "Creating…" : "Create credential"}
        </button>
      </form>
      {shownOnce ? (
        <label>
          Token — shown once
          <input className="mono" value={shownOnce} readOnly />
        </label>
      ) : null}
      {error ? <p className="error">{error}</p> : null}
      {clients.length ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Prefix</th>
                <th>Scopes</th>
                <th>State</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {clients.map((client) => (
                <tr key={client.id}>
                  <td>{client.name}</td>
                  <td className="mono">{client.token_prefix}</td>
                  <td className="mono">{client.scopes.join(", ")}</td>
                  <td>{client.revoked ? "Revoked" : "Active"}</td>
                  <td>
                    {client.revoked ? null : (
                      <button
                        type="button"
                        className="secondary"
                        disabled={pending}
                        onClick={() => {
                          const form = new FormData();
                          form.set("clientId", client.id);
                          startTransition(async () => {
                            const result = await revokeApiClientAction(form);
                            if (!result.ok) {
                              setError(result.error);
                              return;
                            }
                            router.refresh();
                          });
                        }}
                      >
                        Revoke
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}
