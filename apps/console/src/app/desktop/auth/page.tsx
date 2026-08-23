"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { FormEvent, Suspense, useEffect, useState, useTransition } from "react";
import { authClient } from "@/lib/auth-client";

const TAGLINE =
  "Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.";

function DesktopAuthInner() {
  const router = useRouter();
  const params = useSearchParams();
  const redirectURI =
    params.get("redirect_uri") ?? "blaktail://auth/callback";
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const session = await authClient.getSession();
      if (cancelled) return;
      if (session.data?.session) {
        window.location.href = `/api/desktop/auth/callback?redirect_uri=${encodeURIComponent(redirectURI)}`;
        return;
      }
      setChecking(false);
    })();
    return () => {
      cancelled = true;
    };
  }, [redirectURI]);

  function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const email = String(form.get("email") ?? "");
    const password = String(form.get("password") ?? "");
    setError(null);
    startTransition(async () => {
      const result = await authClient.signIn.email({ email, password });
      if (result.error) {
        setError(
          result.error.message ??
            "Sign-in failed. Check your email and password.",
        );
        return;
      }
      window.location.href = `/api/desktop/auth/callback?redirect_uri=${encodeURIComponent(redirectURI)}`;
      router.refresh();
    });
  }

  if (checking) {
    return <p>Checking your session…</p>;
  }

  return (
    <main
      style={{
        maxWidth: 420,
        margin: "4rem auto",
        fontFamily: "system-ui, sans-serif",
        lineHeight: 1.5,
        padding: "0 1rem",
      }}
    >
      <div style={{ fontWeight: 700, letterSpacing: "0.04em" }}>BlakTail</div>
      <h1 style={{ marginTop: "0.5rem" }}>Desktop sign-in</h1>
      <p style={{ color: "#444" }}>{TAGLINE}</p>
      <form onSubmit={onSubmit} style={{ display: "grid", gap: "0.75rem" }}>
        <label>
          Email
          <input
            name="email"
            type="email"
            autoComplete="username"
            required
            style={{ display: "block", width: "100%", marginTop: 4 }}
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
            style={{ display: "block", width: "100%", marginTop: 4 }}
          />
        </label>
        {error ? (
          <p style={{ color: "#a40000" }} role="alert">
            {error}
          </p>
        ) : null}
        <button type="submit" disabled={pending}>
          {pending ? "Signing in…" : "Sign in and return to the app"}
        </button>
      </form>
      <p style={{ color: "#666", fontSize: "0.9rem" }}>
        Sessions stay in your onshore Postgres. The Mac app stores the session
        token in Keychain and never logs the join key.
      </p>
    </main>
  );
}

export default function DesktopAuthPage() {
  return (
    <Suspense fallback={<p>Loading…</p>}>
      <DesktopAuthInner />
    </Suspense>
  );
}
