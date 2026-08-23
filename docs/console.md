# Console

`apps/console` is the BlakTail operator UI. Next.js 16.3 (App Router), Better Auth,
Drizzle, and onshore Postgres. The Rust coordinator remains the source of truth for
tailnet authorisation.

## Pages

- `/sign-in` — email and password; shows the locked product tagline
- `/devices` — list and revoke nodes
- `/join-keys` — mint join keys (owner/admin)
- `/acls` — read and edit ACL JSON (owner/admin write)
- `/status` — coordinator health and region
- `/settings` — account details and the locked tagline

## Auth flow

1. Operators sign in with Better Auth. Sessions live in onshore Postgres.
2. For each coordinator call, the console revalidates the database session and loads the user's organisation membership.
3. The console signs a short-lived (at most 60 seconds) org/user/role assertion with `BLAKTAIL_AUTH_HMAC_SECRET`; the assertion never contains the Better Auth cookie or session token.
4. Rust verifies the HMAC, expiry, organisation, and role on every protected route. Missing, expired, cross-org, or forged assertions receive 401.

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
