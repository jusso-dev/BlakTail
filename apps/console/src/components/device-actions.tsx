"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  approveNodeRoutesAction,
  revokeDeviceAction,
  updateDeviceFriendlyNameAction,
} from "@/app/actions";
import type { CoordNode } from "@/lib/coord";

export type InventoryNode = CoordNode & {
  organisationId: string;
  organisationName: string;
  canMutate: boolean;
};

export function DeviceActions({
  nodes,
}: {
  nodes: InventoryNode[];
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
      <div className="table-wrap">
        <table className="table">
        <thead>
          <tr>
            <th>Device</th>
            <th>Network</th>
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
            <tr key={`${node.organisationId}:${node.id}`}>
              <td>
                {node.canMutate && !node.revoked ? (
                  <form
                    className="device-name-editor"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const formData = new FormData(event.currentTarget);
                      setMessage(null);
                      startTransition(async () => {
                        const result =
                          await updateDeviceFriendlyNameAction(formData);
                        setMessage({
                          text: result.ok
                            ? result.data.friendlyName
                              ? `${node.name} is now shown as ${result.data.friendlyName}.`
                              : `${node.name} now uses its original name.`
                            : result.error,
                          error: !result.ok,
                        });
                        if (result.ok) router.refresh();
                      });
                    }}
                  >
                    <input type="hidden" name="nodeId" value={node.id} />
                    <input
                      type="hidden"
                      name="organisationId"
                      value={node.organisationId}
                    />
                    <label>
                      <span>Friendly name</span>
                      <input
                        name="friendlyName"
                        type="text"
                        maxLength={64}
                        defaultValue={node.display_name ?? ""}
                        placeholder={node.name}
                        aria-label={`Friendly name for ${node.name}`}
                        disabled={pending}
                      />
                    </label>
                    <button
                      type="submit"
                      className="secondary"
                      disabled={pending}
                    >
                      Save name
                    </button>
                    <span className="device-technical-name mono">
                      Agent: {node.name}
                    </span>
                  </form>
                ) : (
                  <div className="device-name-readonly">
                    <strong>{node.display_name || node.name}</strong>
                    {node.display_name ? (
                      <span className="device-technical-name mono">
                        Agent: {node.name}
                      </span>
                    ) : null}
                  </div>
                )}
              </td>
              <td>
                <strong>{node.organisationName}</strong>
              </td>
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
                            ? `${node.display_name || node.name} route approvals saved.`
                            : result.error,
                          error: !result.ok,
                        });
                        if (result.ok) router.refresh();
                      });
                    }}
                  >
                    <input type="hidden" name="nodeId" value={node.id} />
                    <input
                      type="hidden"
                      name="organisationId"
                      value={node.organisationId}
                    />
                    {node.advertised_routes.map((route) => (
                      <label key={route} className="route-option mono">
                        <input
                          type="checkbox"
                          name="approvedRoutes"
                          value={route}
                          defaultChecked={node.approved_routes.includes(route)}
                          disabled={
                            !node.canMutate ||
                            pending ||
                            node.revoked ||
                            (node.expired &&
                              !node.approved_routes.includes(route))
                          }
                        />
                        {route === "0.0.0.0/0" ? "Exit node" : route}
                      </label>
                    ))}
                    {node.canMutate &&
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
                {node.canMutate && !node.revoked ? (
                  <button
                    type="button"
                    className="secondary"
                    disabled={pending}
                    onClick={() => {
                      const formData = new FormData();
                      formData.set("nodeId", node.id);
                      formData.set("organisationId", node.organisationId);
                      setMessage(null);
                      startTransition(async () => {
                        const result = await revokeDeviceAction(formData);
                        setMessage({
                          text: result.ok
                            ? `${node.display_name || node.name} revoked.`
                            : result.error,
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
      </div>
      {message ? (
        <p
          className={message.error ? "error" : "muted"}
          role={message.error ? "alert" : "status"}
          aria-live="polite"
        >
          {message.text}
        </p>
      ) : null}
    </div>
  );
}
