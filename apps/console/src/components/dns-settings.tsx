"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { saveDnsAction } from "@/app/actions";
import type { OrgDnsResponse } from "@/lib/coord";

export function DnsSettings({
  initial,
  readOnly,
}: {
  initial: OrgDnsResponse;
  readOnly: boolean;
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [document, setDocument] = useState(
    JSON.stringify(initial.dns, null, 2),
  );

  const preview = (() => {
    try {
      return JSON.parse(document) as OrgDnsResponse["dns"];
    } catch {
      return null;
    }
  })();

  return (
    <div className="panel stack">
      <div>
        <h2>Organisation DNS</h2>
        <p className="muted">
          Publish split suffixes, search domains, and extra A/AAAA records.
          Agents apply split forwarding. MagicDNS stays authoritative for{" "}
          <span className="mono">{initial.magic_dns_suffix}</span>. Global
          resolvers are stored for later use; public names stay refused.
        </p>
        <p className="muted">
          Revision {initial.revision}
          {initial.has_previous ? " · previous revision available" : ""}
          {typeof initial.enrolled === "number"
            ? ` · ${initial.applied ?? 0} of ${initial.enrolled} enrolled devices on this revision`
            : ""}
        </p>
      </div>
      <label>
        Settings JSON
        <textarea
          className="mono"
          name="dnsJson"
          rows={14}
          value={document}
          disabled={readOnly || pending}
          onChange={(event) => setDocument(event.target.value)}
        />
      </label>
      {preview ? (
        <ul className="muted">
          <li>
            Managed: {preview.managed === false ? "no" : "yes"} · global
            resolvers: {preview.global_resolvers?.length ?? 0}
          </li>
          {(preview.split ?? []).map((route) => (
            <li key={route.suffix}>
              Split <span className="mono">{route.suffix}</span> →{" "}
              {(route.resolvers ?? []).join(", ")}
            </li>
          ))}
          {(preview.records ?? []).map((record) => (
            <li key={`${record.type}-${record.name}-${record.value}`}>
              {record.type} <span className="mono">{record.name}</span>{" "}
              {record.value}
            </li>
          ))}
          {(initial.record_preview ?? []).map((route) => (
            <li key={`preview-${route.name}`}>
              {route.name} →{" "}
              {route.split_suffix ? (
                <span className="mono">{route.split_suffix}</span>
              ) : (
                "local / MagicDNS only"
              )}
            </li>
          ))}
        </ul>
      ) : (
        <p className="error">JSON is not valid yet.</p>
      )}
      {error ? <p className="error">{error}</p> : null}
      {readOnly ? (
        <p className="muted">Members can view DNS settings but cannot publish.</p>
      ) : (
        <div>
          <button
            type="button"
            disabled={pending || !preview}
            onClick={() => {
              const form = new FormData();
              form.set("dnsJson", document);
              form.set("etag", initial.etag);
              setError(null);
              startTransition(async () => {
                const result = await saveDnsAction(form);
                if (!result.ok) {
                  setError(result.error);
                  return;
                }
                router.refresh();
              });
            }}
          >
            {pending ? "Publishing…" : "Publish DNS"}
          </button>
          {initial.has_previous ? (
            <button
              type="button"
              className="secondary"
              disabled={pending}
              onClick={() => {
                const form = new FormData();
                form.set("rollback", "true");
                form.set("etag", initial.etag);
                setError(null);
                startTransition(async () => {
                  const result = await saveDnsAction(form);
                  if (!result.ok) {
                    setError(result.error);
                    return;
                  }
                  router.refresh();
                });
              }}
            >
              Roll back
            </button>
          ) : null}
        </div>
      )}
    </div>
  );
}
