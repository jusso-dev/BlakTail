"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  approveNodeRoutesAction,
  revokeDeviceAction,
  tombstoneDeviceAction,
  updateDeviceFriendlyNameAction,
} from "@/app/actions";
import type { NetworkNode } from "@/lib/coord";
import { canMutateTailnet } from "@/lib/roles";

export function DeviceActions({
  nodes,
}: {
  nodes: NetworkNode[];
}) {
  const router = useRouter();
  const [message, setMessage] = useState<{
    text: string;
    error: boolean;
  } | null>(null);
  const [pending, startTransition] = useTransition();
  const [query, setQuery] = useState("");
  const visible = nodes.filter((node) => {
    const wanted = query.trim().toLowerCase();
    if (!wanted) return true;
    return [
      node.name,
      node.display_name ?? "",
      node.dns_name,
      node.hostname ?? "",
      node.os ?? "",
      node.id,
    ]
      .join(" ")
      .toLowerCase()
      .includes(wanted);
  });

  if (nodes.length === 0) {
    return (
      <p className="muted">
        No devices yet. Mint a join key and enrol a node with the agent.
      </p>
    );
  }

  return (
    <div className="stack">
      <label>
        Search inventory
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Name, DNS, OS, or node id"
        />
      </label>
      <div className="table-wrap">
        <table className="table">
        <thead>
          <tr>
            <th>Network account</th>
            <th>Device</th>
            <th>DNS</th>
            <th>Addresses</th>
            <th>Advertised routes</th>
            <th>Tags</th>
            <th>Posture</th>
            <th>Last seen</th>
            <th>Credential expiry</th>
            <th>State</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {visible.map((node) => (
            <tr key={`${node.organisation_id}:${node.id}`}>
              <td>
                <strong>{node.network_account_name}</strong>
                <span className="device-technical-name">
                  {node.organisation_name}
                </span>
              </td>
              <td>
                {canMutateTailnet(node.effective_role) && !node.revoked ? (
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
                      value={node.organisation_id}
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
                      value={node.organisation_id}
                    />
                    {node.advertised_routes.map((route) => (
                      <label key={route} className="route-option mono">
                        <input
                          type="checkbox"
                          name="approvedRoutes"
                          value={route}
                          defaultChecked={node.approved_routes.includes(route)}
                          disabled={
                            !canMutateTailnet(node.effective_role) ||
                            pending ||
                            node.revoked ||
                            (node.expired &&
                              !node.approved_routes.includes(route))
                          }
                        />
                        {route === "0.0.0.0/0" ? "Exit node" : route}
                      </label>
                    ))}
                    {canMutateTailnet(node.effective_role) &&
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
              <td>
                <div>{node.os || "—"}{node.os_version ? `/${node.os_version}` : ""}</div>
                <div className="muted mono">{node.agent_version || ""}</div>
                {node.hostname ? (
                  <div className="muted">{node.hostname}</div>
                ) : null}
              </td>
              <td className="mono">
                {node.last_seen_at
                  ? new Date(node.last_seen_at * 1000).toISOString().replace("T", " ").slice(0, 19)
                  : "Never"}
                <div className="muted">
                  {node.online ? "Online if seen within 90s" : "Offline"}
                </div>
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
                {node.deleted ? (
                  <span className="badge warn">Deleted</span>
                ) : node.revoked ? (
                  <span className="badge warn">Revoked</span>
                ) : node.expired ? (
                  <span className="badge warn">Expired</span>
                ) : node.expires_soon ? (
                  <span className="badge warn">Expires soon</span>
                ) : node.online ? (
                  <span className="badge">Online</span>
                ) : (
                  <span className="badge">Active</span>
                )}
              </td>
              <td>
                {canMutateTailnet(node.effective_role) && !node.revoked && !node.deleted ? (
                  <div className="stack">
                    <button
                      type="button"
                      className="secondary"
                      disabled={pending}
                      onClick={() => {
                        const formData = new FormData();
                        formData.set("nodeId", node.id);
                        formData.set("organisationId", node.organisation_id);
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
                    <button
                      type="button"
                      className="secondary"
                      disabled={pending}
                      onClick={() => {
                        const label = node.display_name || node.name;
                        if (
                          !window.confirm(
                            `Delete ${label} from inventory? This keeps a tombstone for audit and is separate from revoke.`,
                          )
                        ) {
                          return;
                        }
                        const formData = new FormData();
                        formData.set("nodeId", node.id);
                        formData.set("organisationId", node.organisation_id);
                        setMessage(null);
                        startTransition(async () => {
                          const result = await tombstoneDeviceAction(formData);
                          setMessage({
                            text: result.ok
                              ? `${label} deleted from inventory.`
                              : result.error,
                            error: !result.ok,
                          });
                          if (result.ok) router.refresh();
                        });
                      }}
                    >
                      Delete
                    </button>
                  </div>
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
