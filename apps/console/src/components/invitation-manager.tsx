"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import {
  createInvitationAction,
  revokeInvitationAction,
} from "@/app/actions";

type PendingInvitation = {
  id: string;
  email: string;
  role: "admin" | "member";
  expiresAt: string;
};

export function InvitationManager({
  invitations,
}: {
  invitations: PendingInvitation[];
}) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [invitationUrl, setInvitationUrl] = useState<string | null>(null);

  return (
    <div className="panel stack">
      <div>
        <h2>Invite organisation member</h2>
        <p className="muted">
          Link is shown once. Send it through a trusted channel. New users create
          an account; existing users add this workspace to their current login.
        </p>
      </div>
      <form
        onSubmit={(event) => {
          event.preventDefault();
          const form = new FormData(event.currentTarget);
          setError(null);
          setInvitationUrl(null);
          startTransition(async () => {
            const result = await createInvitationAction(form);
            if (!result.ok) {
              setError(result.error);
              return;
            }
            setInvitationUrl(result.data.url);
            router.refresh();
          });
        }}
      >
        <label>
          Email
          <input name="email" type="email" autoComplete="off" required />
        </label>
        <label>
          Role
          <select name="role" defaultValue="member">
            <option value="member">Member</option>
            <option value="admin">Admin</option>
          </select>
        </label>
        <button type="submit" disabled={pending}>
          {pending ? "Creating…" : "Create invitation"}
        </button>
      </form>
      {invitationUrl ? (
        <label>
          Invitation link — shown once
          <input className="mono" value={invitationUrl} readOnly />
        </label>
      ) : null}
      {error ? <p className="error">{error}</p> : null}
      {invitations.length ? (
        <div className="table-wrap">
          <table className="table">
            <thead>
              <tr>
                <th>Email</th>
                <th>Role</th>
                <th>Expires (UTC)</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              {invitations.map((invitation) => (
                <tr key={invitation.id}>
                  <td>{invitation.email}</td>
                  <td>{invitation.role}</td>
                  <td className="mono">{invitation.expiresAt}</td>
                  <td>
                    <button
                      type="button"
                      className="danger"
                      disabled={pending}
                      onClick={() => {
                        const form = new FormData();
                        form.set("invitationId", invitation.id);
                        setError(null);
                        startTransition(async () => {
                          const result = await revokeInvitationAction(form);
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
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="muted">No pending invitations. Invite someone when you need another operator on this network.</p>
      )}
    </div>
  );
}
