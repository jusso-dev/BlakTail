"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import {
  beginIdentityLinkAction,
  completeIdentityLinkAction,
  recoverIdentityAction,
  resolveIdentityRoleConflictAction,
  suspendIdentityAction,
  unlinkIdentityAction,
} from "@/app/identity-actions";
import type {
  LoginIdentitySummary,
  NetworkAccountSummary,
  PendingRoleConflict,
} from "@/lib/identity-links";
import { roleLabel } from "@/lib/roles";

export function IdentitySettings({
  identities,
  networkAccounts,
  conflicts,
}: {
  identities: LoginIdentitySummary[];
  networkAccounts: NetworkAccountSummary[];
  conflicts: PendingRoleConflict[];
}) {
  const router = useRouter();
  const [challenge, setChallenge] = useState<{
    token: string;
    expiresAt: string;
  } | null>(null);
  const [message, setMessage] = useState<{
    text: string;
    error: boolean;
  } | null>(null);
  const [pending, startTransition] = useTransition();

  function show(text: string, error = false) {
    setMessage({ text, error });
  }

  return (
    <div className="stack">
      <section className="panel stack" aria-labelledby="network-accounts">
        <div>
          <h2 id="network-accounts">Network accounts</h2>
          <p className="muted">
            These organisation memberships contribute machines to All networks.
            Roles and coordinator state remain isolated per organisation.
          </p>
        </div>
        {networkAccounts.length === 0 ? (
          <p className="muted">
            No active network accounts. Accept an invitation or ask an owner to
            add this identity to a workspace.
          </p>
        ) : (
          <div className="table-wrap">
            <table className="table">
              <thead>
                <tr>
                  <th>Network account</th>
                  <th>Organisation</th>
                  <th>Role</th>
                </tr>
              </thead>
              <tbody>
                {networkAccounts.map((account) => (
                  <tr key={account.id}>
                    <td>{account.name}</td>
                    <td>{account.organisationName}</td>
                    <td>{roleLabel(account.role)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <section className="panel stack" aria-labelledby="ways-to-sign-in">
        <div>
          <h2 id="ways-to-sign-in">Ways to sign in</h2>
          <p className="muted">
            Each identity authenticates independently. Provider credentials,
            tokens, and MFA state are never copied when identities are linked.
          </p>
        </div>
        {identities.map((identity) => (
          <div className="identity-row" key={identity.userId}>
            <div>
              <strong>{identity.email}</strong>
              <div className="muted">
                {identity.name} · {identity.methods.join(", ") || "provider"}
                {identity.current ? " · current session" : ""}
                {identity.status === "suspended" ? " · suspended" : ""}
              </div>
            </div>
            {!identity.current ? (
              <form
                className="inline-form"
                onSubmit={(event) => {
                  event.preventDefault();
                  const formData = new FormData(event.currentTarget);
                  const submitter = (
                    event.nativeEvent as SubmitEvent
                  ).submitter as HTMLButtonElement | null;
                  const operation = submitter?.value;
                  if (
                    operation !== "unlink" &&
                    operation !== "recover" &&
                    operation !== "revoke"
                  ) {
                    return;
                  }
                  setMessage(null);
                  startTransition(async () => {
                    const result =
                      operation === "unlink"
                        ? await unlinkIdentityAction(formData)
                        : operation === "recover"
                          ? await recoverIdentityAction(formData)
                          : await suspendIdentityAction(formData);
                    show(
                      result.ok
                        ? operation === "unlink"
                          ? "Identity unlinked. Its networks have been removed from this session."
                          : operation === "recover"
                            ? "Identity recovered."
                            : "Identity revoked. Its memberships no longer contribute access."
                        : result.error,
                      !result.ok,
                    );
                    if (result.ok) router.refresh();
                  });
                }}
              >
                <input
                  type="hidden"
                  name="identityUserId"
                  value={identity.userId}
                />
                <label>
                  Reauthenticate current sign-in
                  <input
                    name="currentPassword"
                    type="password"
                    autoComplete="current-password"
                    required
                    minLength={10}
                    disabled={pending}
                  />
                </label>
                {identity.status === "suspended" ? (
                  <button
                    type="submit"
                    name="operation"
                    value="recover"
                    className="secondary"
                    disabled={pending}
                  >
                    Recover
                  </button>
                ) : (
                  <>
                    <button
                      type="submit"
                      name="operation"
                      value="unlink"
                      className="secondary"
                      disabled={pending || identities.length <= 1}
                    >
                      Unlink
                    </button>
                    <button
                      type="submit"
                      name="operation"
                      value="revoke"
                      className="secondary"
                      disabled={pending || identities.length <= 1}
                    >
                      Revoke
                    </button>
                  </>
                )}
              </form>
            ) : null}
          </div>
        ))}

        {!challenge ? (
          <button
            type="button"
            disabled={pending}
            onClick={() => {
              setMessage(null);
              startTransition(async () => {
                const result = await beginIdentityLinkAction();
                if (result.ok) {
                  setChallenge(result.data);
                  show(
                    "Link challenge started. Authenticate the other identity before it expires.",
                  );
                } else {
                  show(result.error, true);
                }
              });
            }}
          >
            Link another login
          </button>
        ) : (
          <form
            className="stack"
            onSubmit={(event) => {
              event.preventDefault();
              const formData = new FormData(event.currentTarget);
              setMessage(null);
              startTransition(async () => {
                const result = await completeIdentityLinkAction(formData);
                if (!result.ok) {
                  setChallenge(null);
                  show(result.error, true);
                  return;
                }
                setChallenge(null);
                show(
                  result.data.ownerResolutionRequired
                    ? "The second identity was authenticated, but an organisation owner must explicitly resolve a role conflict before linking completes."
                    : "Login linked. All networks are available in this same session.",
                );
                router.refresh();
              });
            }}
          >
            <input type="hidden" name="challenge" value={challenge.token} />
            <p className="muted">
              Challenge expires{" "}
              <time dateTime={challenge.expiresAt}>{challenge.expiresAt}</time>.
              Reauthenticate both logins; an email address or existing browser
              session is not sufficient.
            </p>
            <label>
              Current identity password
              <input
                name="currentPassword"
                type="password"
                autoComplete="current-password"
                required
                minLength={10}
                disabled={pending}
              />
            </label>
            <label>
              Other identity email
              <input
                name="email"
                type="email"
                autoComplete="username"
                required
                disabled={pending}
              />
            </label>
            <label>
              Other identity password
              <input
                name="password"
                type="password"
                autoComplete="current-password"
                required
                minLength={10}
                disabled={pending}
              />
            </label>
            <div className="actions">
              <button type="submit" disabled={pending}>
                Authenticate and link
              </button>
              <button
                type="button"
                className="secondary"
                disabled={pending}
                onClick={() => setChallenge(null)}
              >
                Cancel
              </button>
            </div>
          </form>
        )}
      </section>

      {conflicts.length > 0 ? (
        <section className="panel stack" aria-labelledby="role-conflicts">
          <div>
            <h2 id="role-conflicts">Owner role decisions</h2>
            <p className="muted">
              Both memberships remain unchanged. Choose the effective role for
              this linked-person view; the decision is audited.
            </p>
          </div>
          {conflicts.map((conflict) => (
            <form
              key={conflict.id}
              className="inline-form"
              onSubmit={(event) => {
                event.preventDefault();
                const formData = new FormData(event.currentTarget);
                setMessage(null);
                startTransition(async () => {
                  const result =
                    await resolveIdentityRoleConflictAction(formData);
                  show(
                    result.ok
                      ? result.data.linked
                        ? "Role conflict resolved and login linked."
                        : "Role decision recorded; another owner decision is still required."
                      : result.error,
                    !result.ok,
                  );
                  if (result.ok) router.refresh();
                });
              }}
            >
              <input type="hidden" name="conflictId" value={conflict.id} />
              <label>
                {conflict.organisationName}
                <select name="resolvedRole" required defaultValue="">
                  <option value="" disabled>
                    Choose effective role
                  </option>
                  {[conflict.requesterRole, conflict.targetRole].map((role) => (
                    <option value={role} key={role}>
                      {roleLabel(role)}
                    </option>
                  ))}
                </select>
              </label>
              <button type="submit" disabled={pending}>
                Record owner decision
              </button>
            </form>
          ))}
        </section>
      ) : null}

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
