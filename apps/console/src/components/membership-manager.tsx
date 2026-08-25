"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { changeMembershipAction } from "@/app/actions";

export type MembershipSummary = {
  id: string;
  userId: string;
  role: "owner" | "admin" | "member";
  status: "invited" | "active" | "suspended" | "removed";
  email: string;
  name: string;
};

export function MembershipManager({
  memberships,
}: {
  memberships: MembershipSummary[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="panel stack">
      <div>
        <h2>Membership</h2>
        <p className="muted">
          Suspended or removed members lose console access immediately. Device
          records stay intact. The last owner cannot be removed.
        </p>
      </div>
      {error ? <p className="error">{error}</p> : null}
      <div className="table-wrap">
        <table className="table">
          <thead>
            <tr>
              <th>Person</th>
              <th>Role</th>
              <th>Status</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {memberships.map((row) => (
              <tr key={row.id}>
                <td>
                  <div>{row.name}</div>
                  <div className="muted mono">{row.email}</div>
                </td>
                <td>{row.role}</td>
                <td>{row.status}</td>
                <td>
                  {row.role === "owner" ? null : (
                    <div className="stack">
                      <button
                        type="button"
                        className="secondary"
                        disabled={pending}
                        onClick={() => {
                          const form = new FormData();
                          form.set("membershipId", row.id);
                          form.set(
                            "status",
                            row.status === "active" ? "suspended" : "active",
                          );
                          startTransition(async () => {
                            const result = await changeMembershipAction(form);
                            if (!result.ok) {
                              setError(result.error);
                              return;
                            }
                            router.refresh();
                          });
                        }}
                      >
                        {row.status === "active" ? "Suspend" : "Restore"}
                      </button>
                      {row.status === "removed" ? null : (
                        <button
                          type="button"
                          className="secondary"
                          disabled={pending}
                          onClick={() => {
                            const form = new FormData();
                            form.set("membershipId", row.id);
                            form.set("status", "removed");
                            startTransition(async () => {
                              const result = await changeMembershipAction(form);
                              if (!result.ok) {
                                setError(result.error);
                                return;
                              }
                              router.refresh();
                            });
                          }}
                        >
                          Remove
                        </button>
                      )}
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
