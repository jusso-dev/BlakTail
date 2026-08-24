# Console

`apps/console` is the BlakTail operator UI. Next.js 16.3 (App Router), Better Auth,
Drizzle, and onshore Postgres. The Rust coordinator remains the source of truth for
tailnet authorisation.

## Pages

- `/sign-in` — email and password; shows the shared project mission
- `/privacy` — public software data-handling and retention statement
- `/devices` — give active nodes friendly names, approve routes, and revoke access
- `/join-keys` — mint join keys (owner/admin)
- `/acls` — read and edit ACL JSON (owner/admin write)
- `/audit` — latest actor-attributed security and administration changes
- `/status` — coordinator health and region
- `/settings` — account details and the shared project mission

## Auth flow

1. Operators sign in with Better Auth. Sessions live in onshore Postgres.
2. For each coordinator call, the console revalidates the database session and loads the user's organisation membership.
3. The console signs a short-lived (at most 60 seconds) org/user/role/name/email assertion with `BLAKTAIL_AUTH_HMAC_SECRET`; the assertion never contains the Better Auth cookie or session token.
4. Rust verifies the HMAC, expiry, organisation, and role on every protected route. Missing, expired, cross-org, or forged assertions receive 401.

For headless Linux enrollment, `blaktaild up` prints `/enroll?code=...`. The
page preserves that destination through sign-in, displays the requested node name
and WireGuard-key fingerprint, and requires an explicit approval. Any signed-in
organisation member can enroll their own untagged device; only owners and admins
can attach privileged device tags. The browser code is not the join secret.

The Devices page also shows each node's requested subnet and exit routes. Owners
and admins approve routes individually; members can see them but cannot change
approval. An unchecked request is never included in peer WireGuard configuration.
Owners and admins can also set or clear a 64-character friendly name. This label is
for people: the agent-provided name, MagicDNS hostname, WireGuard identity, routes,
and persisted agent state do not change.

The Audit log is readable by every organisation member. Join-key minting, browser
enrollment approval, friendly-name changes, route approval, ACL updates, node-key
lifetime updates, and console revocation are written in the same SQLite transaction
as the change. Raw join keys, node tokens, and browser device codes are never
included.

## Local development

```sh
cp apps/console/.env.example apps/console/.env
# point DATABASE_URL at onshore Postgres, then:
npm install
npm run db:migrate -w @blaktail/console
npm run dev:console
```

Build checks used in CI:

```sh
npm ci
npm run lint
npm run typecheck
npm run build
```

Do not pull fonts or analytics from offshore CDNs.

Before public hosting, complete the operator-specific requirements in
[privacy.md](privacy.md): legal name, contact, verified data/backup locations,
retention, subprocessors, and request handling. The generic `/privacy` page does not
invent those deployment-specific facts.
