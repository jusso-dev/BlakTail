"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { authClient } from "@/lib/auth-client";
import { TAGLINE } from "@/lib/tagline";
import { PathMotif } from "./path-motif";
import { Wordmark } from "./wordmark";

export function InvitationAcceptForm({
  token,
  signedInEmail,
}: {
  token: string;
  signedInEmail: string | null;
}) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <div className="auth-screen">
      <div className="auth-form-col">
      <div className="sign-in-card panel">
        <div className="stack">
          <div>
            <Wordmark href="/sign-in" />
            <h1>Accept invitation</h1>
            <p className="tagline">{TAGLINE}</p>
          </div>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              const form = new FormData(event.currentTarget);
              const email = signedInEmail ?? String(form.get("email") ?? "");
              const name = String(form.get("name") ?? "");
              const password = String(form.get("password") ?? "");
              setError(null);
              startTransition(async () => {
                const response = await fetch("/api/invitations/accept", {
                  method: "POST",
                  headers: { "content-type": "application/json" },
                  body: JSON.stringify(
                    signedInEmail
                      ? { token }
                      : { token, email, name, password },
                  ),
                });
                const result = (await response.json()) as { error?: string };
                if (!response.ok) {
                  setError(result.error ?? "Invitation is invalid or expired.");
                  return;
                }
                if (!signedInEmail) {
                  const signIn = await authClient.signIn.email({ email, password });
                  if (signIn.error) {
                    setError("Account created. Sign in with your new password.");
                    return;
                  }
                }
                router.replace("/devices");
                router.refresh();
              });
            }}
          >
            {signedInEmail ? (
              <p>
                Signed in as <strong>{signedInEmail}</strong>. Accepting adds
                this workspace to the same session; your other workspaces stay
                connected.
              </p>
            ) : (
              <>
                <label>
                  Invited email
                  <input
                    name="email"
                    type="email"
                    autoComplete="username"
                    required
                  />
                </label>
                <label>
                  Your name
                  <input
                    name="name"
                    autoComplete="name"
                    maxLength={128}
                    required
                  />
                </label>
                <label>
                  Create password
                  <input
                    name="password"
                    type="password"
                    autoComplete="new-password"
                    minLength={10}
                    maxLength={128}
                    required
                  />
                </label>
              </>
            )}
            {error ? <p className="error">{error}</p> : null}
            <button type="submit" disabled={pending || !token}>
              {pending
                ? "Accepting…"
                : signedInEmail
                  ? "Join workspace"
                  : "Accept invitation"}
            </button>
          </form>
          {!token ? <p className="error">Invitation is invalid or expired.</p> : null}
          <p className="muted">
            Invitation works once and only for its assigned workspace and role.
          </p>
          {!signedInEmail ? (
            <p className="muted">
              Already have an account? <Link href="/sign-in">Sign in</Link>,
              then open this invitation again.
            </p>
          ) : null}
        </div>
      </div>
      </div>
      <aside className="auth-brand-col" aria-hidden="true">
        <PathMotif />
        <div className="auth-brand-copy">
          <p className="auth-kicker">Invitation</p>
          <p>A private path between your organisation&apos;s devices.</p>
          <p className="muted">Your network. Your rules. Your country.</p>
        </div>
      </aside>
    </div>
  );
}
