"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { authClient } from "@/lib/auth-client";
import { TAGLINE } from "@/lib/tagline";

export function SignInForm({ nextPath = "/devices" }: { nextPath?: string }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  return (
    <div className="sign-in">
      <div className="sign-in-card panel">
        <div className="stack">
          <div>
            <div className="brand">BlakTail</div>
            <h1>Sign in</h1>
            <p className="tagline">{TAGLINE}</p>
          </div>
          <form
            onSubmit={(event) => {
              event.preventDefault();
              const form = new FormData(event.currentTarget);
              const email = String(form.get("email") ?? "");
              const password = String(form.get("password") ?? "");
              setError(null);
              startTransition(async () => {
                const result = await authClient.signIn.email({
                  email,
                  password,
                });
                if (result.error) {
                  setError(
                    result.error.message ??
                      "Sign-in failed. Check your email and password.",
                  );
                  return;
                }
                router.replace(nextPath);
                router.refresh();
              });
            }}
          >
            <label>
              Email
              <input
                name="email"
                type="email"
                autoComplete="username"
                required
              />
            </label>
            <label>
              Password
              <input
                name="password"
                type="password"
                autoComplete="current-password"
                required
                minLength={10}
              />
            </label>
            {error ? <p className="error">{error}</p> : null}
            <button type="submit" disabled={pending}>
              {pending ? "Signing in…" : "Sign in"}
            </button>
          </form>
          <p className="muted">
            Email and password only for now. Sessions stay in your onshore
            Postgres. The Rust coordinator checks them before it changes the
            tailnet.
          </p>
        </div>
      </div>
    </div>
  );
}
