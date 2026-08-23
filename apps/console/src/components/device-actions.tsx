"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  approveNodeRoutesAction,
  revokeDeviceAction,
} from "@/app/actions";
import type { CoordNode } from "@/lib/coord";

export function DeviceActions({
  nodes,
  canMutate,
}: {
  nodes: CoordNode[];
  canMutate: boolean;
}) {
  const router = useRouter();
  const [message, setMessage] = useState<{
    text: string;
    error: boolean;
  } | null>(null);
  const [pending, startTransition] = useTransition();

  if (nodes.length === 0) {
    return (
      <p className="muted">
        No devices yet. Mint a join key and enrol a node with the agent.
      </p>
    );
  }

  return (
    <div className="stack">
      <table className="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>DNS</th>
            <th>Addresses</th>
            <th>Advertised routes</th>
            <th>Tags</th>
            <th>Credential expiry</th>
            <th>State</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {nodes.map((node) => (
            <tr key={node.id}>
              <td>{node.name}</td>
              <td className="mono">{node.dns_name || "—"}</td>
              <td className="mono">{node.allowed_ips.join(", ") || "—"}</td>
              <td>
                {node.advertised_routes.length === 0 ? (
                  "—"
                ) : (
                  <form
                    className="route-approval"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const formData = new FormData(event.currentTarget);
                      setMessage(null);
                      startTransition(async () => {
                        const result = await approveNodeRoutesAction(formData);
                        setMessage({
                          text: result.ok
                            ? `${node.name} route approvals saved.`
                            : result.error,
                          error: !result.ok,
                        });
                        if (result.ok) router.refresh();
                      });
                    }}
                  >
                    <input type="hidden" name="nodeId" value={node.id} />
                    {node.advertised_routes.map((route) => (
                      <label key={route} className="route-option mono">
                        <input
                          type="checkbox"
                          name="approvedRoutes"
                          value={route}
                          defaultChecked={node.approved_routes.includes(route)}
                          disabled={
                            !canMutate ||
                            pending ||
                            node.revoked ||
                            (node.expired &&
                              !node.approved_routes.includes(route))
                          }
                        />
                        {route === "0.0.0.0/0" ? "Exit node" : route}
                      </label>
                    ))}
                    {canMutate &&
                    !node.revoked &&
                    (!node.expired || node.approved_routes.length > 0) ? (
                      <button
                        type="submit"
                        className="secondary"
                        disabled={pending}
                      >
                        Save routes
                      </button>
                    ) : null}
                  </form>
                )}
              </td>
              <td>
                {node.tags.length > 0
                  ? node.tags.map((tag) => (
                      <span key={tag} className="badge">
                        {tag}
                      </span>
                    ))
                  : "—"}
              </td>
              <td className="mono">
                <time
                  dateTime={new Date(
                    node.credential_expires_at * 1000,
                  ).toISOString()}
                >
                  {new Date(node.credential_expires_at * 1000)
                    .toISOString()
                    .slice(0, 10)}
                </time>
              </td>
              <td>
                {node.revoked ? (
                  <span className="badge warn">Revoked</span>
                ) : node.expired ? (
                  <span className="badge warn">Expired</span>
                ) : node.expires_soon ? (
                  <span className="badge warn">Expires soon</span>
                ) : (
                  <span className="badge">Active</span>
                )}
              </td>
              <td>
                {canMutate && !node.revoked ? (
                  <button
                    type="button"
                    className="secondary"
                    disabled={pending}
                    onClick={() => {
                      const formData = new FormData();
                      formData.set("nodeId", node.id);
                      setMessage(null);
                      startTransition(async () => {
                        const result = await revokeDeviceAction(formData);
                        setMessage({
                          text: result.ok ? `${node.name} revoked.` : result.error,
                          error: !result.ok,
                        });
                        if (result.ok) router.refresh();
                      });
                    }}
                  >
                    Revoke
                  </button>
                ) : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {message ? (
        <p className={message.error ? "error" : "muted"}>{message.text}</p>
      ) : null}
    </div>
  );
}
