"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  createWebhookAction,
  disableWebhookAction,
  listWebhookDeliveriesAction,
  replayWebhookDeliveryAction,
} from "@/app/actions";
import type { WebhookDelivery, WebhookDestination } from "@/lib/coord";

export function WebhookManager({
  destinations,
}: {
  destinations: WebhookDestination[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [shownOnce, setShownOnce] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [deliveries, setDeliveries] = useState<WebhookDelivery[]>([]);

  return (
    <div className="panel stack">
      <div>
        <h2>Webhook destinations</h2>
        <p className="muted">
          HTTPS endpoints that receive signed policy and DNS events. The
          signing secret is shown once and stored sealed. Production rejects
          loopback, private, and metadata targets.
        </p>
      </div>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          const formEl = event.currentTarget;
          const form = new FormData(formEl);
          setError(null);
          setShownOnce(null);
          startTransition(async () => {
            const result = await createWebhookAction(form);
            if (!result.ok) {
              setError(result.error);
              return;
            }
            setShownOnce(result.data.secret);
            formEl.reset();
            router.refresh();
          });
        }}
      >
        <label>
          Name
          <input name="name" required maxLength={64} />
        </label>
        <label>
          HTTPS URL
          <input
            name="url"
            type="url"
            required
            placeholder="https://example.com/hooks/blaktail"
          />
        </label>
        <button type="submit" disabled={pending}>
          {pending ? "Creating…" : "Create destination"}
        </button>
      </form>
      {shownOnce ? (
        <label>
          Signing secret — shown once
          <input className="mono" value={shownOnce} readOnly />
        </label>
      ) : null}
      {error ? <p className="error">{error}</p> : null}
      {destinations.length ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Name</th>
                <th>URL</th>
                <th>Prefix</th>
                <th>State</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {destinations.map((destination) => (
                <tr key={destination.id}>
                  <td>{destination.name}</td>
                  <td className="mono">{destination.url}</td>
                  <td className="mono">{destination.secret_prefix}</td>
                  <td>
                    <span
                      className={
                        destination.enabled ? "badge online" : "badge revoked"
                      }
                    >
                      {destination.enabled ? "Active" : "Disabled"}
                    </span>
                  </td>
                  <td>
                    <button
                      type="button"
                      disabled={pending}
                      onClick={() => {
                        const next =
                          openId === destination.id ? null : destination.id;
                        setOpenId(next);
                        if (!next) {
                          setDeliveries([]);
                          return;
                        }
                        startTransition(async () => {
                          const result = await listWebhookDeliveriesAction(
                            destination.id,
                          );
                          if (!result.ok) {
                            setError(result.error);
                            return;
                          }
                          setDeliveries(result.data.deliveries);
                        });
                      }}
                    >
                      {openId === destination.id
                        ? "Hide deliveries"
                        : "Deliveries"}
                    </button>
                    {destination.enabled ? (
                      <button
                        type="button"
                        className="danger"
                        disabled={pending}
                        onClick={() => {
                          const form = new FormData();
                          form.set("destinationId", destination.id);
                          startTransition(async () => {
                            const result = await disableWebhookAction(form);
                            if (!result.ok) {
                              setError(result.error);
                              return;
                            }
                            router.refresh();
                          });
                        }}
                      >
                        Disable
                      </button>
                    ) : null}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
      {openId && deliveries.length ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Event</th>
                <th>Attempts</th>
                <th>State</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {deliveries.map((delivery) => (
                <tr key={delivery.id}>
                  <td className="mono">{delivery.event_type}</td>
                  <td>{delivery.attempts}</td>
                  <td>
                    {delivery.delivered_at
                      ? "Delivered"
                      : delivery.dead_lettered_at
                        ? "Dead-lettered"
                        : delivery.last_error ?? "Pending"}
                  </td>
                  <td>
                    {delivery.delivered_at ? null : (
                      <button
                        type="button"
                        disabled={pending}
                        onClick={() => {
                          const form = new FormData();
                          form.set("deliveryId", delivery.id);
                          startTransition(async () => {
                            const result =
                              await replayWebhookDeliveryAction(form);
                            if (!result.ok) {
                              setError(result.error);
                              return;
                            }
                            const listed = await listWebhookDeliveriesAction(
                              openId,
                            );
                            if (!listed.ok) {
                              setError(listed.error);
                              return;
                            }
                            setDeliveries(listed.data.deliveries);
                          });
                        }}
                      >
                        Replay
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : openId && !pending ? (
        <p className="muted">No deliveries recorded for this destination.</p>
      ) : null}
    </div>
  );
}
