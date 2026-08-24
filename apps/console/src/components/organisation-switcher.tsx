"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import type { OrganisationContext } from "@/lib/session";

export function OrganisationSwitcher({
  organisations,
  activeOrganisationId,
}: {
  organisations: OrganisationContext[];
  activeOrganisationId: string;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  if (organisations.length === 1) {
    return (
      <div className="workspace-summary">
        <span>Workspace</span>
        <strong>{organisations[0]!.organisationName}</strong>
      </div>
    );
  }

  return (
    <div className="workspace-switcher">
      <label>
        Workspace
        <select
          aria-label="Active workspace"
          value={activeOrganisationId}
          disabled={pending}
          onChange={(event) => {
            const organisationId = event.currentTarget.value;
            setError(null);
            startTransition(async () => {
              const response = await fetch("/api/organisations/active", {
                method: "POST",
                headers: { "content-type": "application/json" },
                body: JSON.stringify({ organisationId }),
              });
              if (!response.ok) {
                const result = (await response.json().catch(() => ({}))) as {
                  error?: string;
                };
                setError(result.error ?? "Could not switch workspace.");
                return;
              }
              router.refresh();
            });
          }}
        >
          {organisations.map((organisation) => (
            <option
              key={organisation.organisationId}
              value={organisation.organisationId}
            >
              {organisation.organisationName}
            </option>
          ))}
        </select>
      </label>
      {error ? (
        <span className="error" role="alert">
          {error}
        </span>
      ) : null}
    </div>
  );
}
