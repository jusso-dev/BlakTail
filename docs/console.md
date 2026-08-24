# Console

`apps/console` is the BlakTail operator UI. Bun 1.4 runs Next.js 16.3 (App
Router), Better Auth, and Drizzle over Bun's native SQL client against onshore
Postgres. The Rust coordinator remains the source of truth for tailnet
authorisation.

## Pages

- `/sign-in` — email and password; shows the shared project mission
- `/privacy` — public software data-handling and retention statement
- `/devices` — all machines across every accessible workspace; give nodes friendly
  names, approve routes, and revoke access within their owning network
- `/join-keys` — mint join keys (owner/admin)
- `/acls` — read and edit ACL JSON (owner/admin write)
- `/audit` — latest actor-attributed security and administration changes
- `/status` — status-only coordinator readiness; region stays in protected diagnostics
- `/settings` — account details, owner-only invitations, and the shared project mission
- `/invite?token=…` — one-use invitation acceptance; public account creation remains disabled

## First owner and invitations

Public email/password sign-up is disabled in Better Auth itself. A fresh database
starts `uninitialised`; first ownership must be claimed from a trusted shell where
the console has its normal `DATABASE_URL`, `COORD_BASE_URL`, and
`BLAKTAIL_AUTH_HMAC_SECRET` environment. Run migrations first, then:

Commands below run from the repository root with Bun 1.4.

```sh
umask 077
openssl rand -base64 32 > owner-password
bun --filter @blaktail/console bootstrap -- init --token-file ./bootstrap-token
bun --filter @blaktail/console bootstrap -- claim \
  --token-file ./bootstrap-token \
  --password-file ./owner-password \
  --email owner@example.org.au \
  --name "First Owner" \
  --organisation-name "Example Organisation"
rm -f ./bootstrap-token
```

Both input files must be regular files inaccessible to group/other (`0400` or
`0600`). `init` creates one random, hashed-at-rest credential that expires after 15
minutes by default. `claim` reserves the coordinator organisation, creates one
Better Auth user and owner membership, commits the coordinator reservation, then
locks bootstrap. Console management stays unavailable until every stage succeeds.
Rerun the exact claim after a transient failure; use
`bun --filter @blaktail/console bootstrap -- status`
for a redacted state check. Races produce one owner and one rejection, and a locked
or expired credential cannot create another owner.

Migration locks any deployment already containing an owner. It reports ownerless
console organisations through `status` without silently assigning them. Repair
requires an explicit operator decision.

After bootstrap, owners invite people from `/settings`. Each URL is shown once,
expires after 48 hours, is bound to one email, role, and organisation, and can be
revoked before use. For a new email, acceptance atomically creates the account and
membership. For an existing email, the recipient signs in first and acceptance adds
the new membership to that same account without ending the session or replacing any
existing memberships. An unauthenticated attempt cannot attach a workspace to an
existing identity. Used, expired, revoked, mismatched, and cross-organisation tokens
are rejected. Admins and members cannot create or revoke invitations.

## Multiple workspaces in one session

This is a product invariant: a person's login identity and an organisation's
network account are different records. One Better Auth user can hold memberships
in many organisation workspaces, and membership in a second network never requires
logging out of the first. The
sidebar workspace selector persists an active workspace in an HTTP-only cookie;
the cookie is only a preference, and every request rechecks the selected ID against
the signed-in user's live memberships. Invalid or removed workspace selections
cannot fall through to a write in another organisation.

`/devices` deliberately ignores that display preference and concurrently loads the
machine inventory for every accessible workspace. Each row names its network and
carries that organisation ID into rename, route-approval, and revoke actions. The
server resolves the submitted ID back through the current user's memberships before
signing a coordinator assertion. This prevents a machine ID from being acted on
through whichever workspace happened to be selected first.

Organisation-scoped pages such as join keys, ACLs, audit, invitations, settings,
and browser enrolment use the active workspace. Switching them requires no logout
and does not issue or replace a Better Auth session. The desktop session endpoint
also returns the full workspace list and accepts `X-BlakTail-Organisation` for an
explicit, membership-checked selection.

Lost sole-owner credentials have no web reset. From a trusted host, create a new
protected password file and run:

```sh
bun --filter @blaktail/console bootstrap -- recover-owner \
  --email owner@example.org.au \
  --password-file ./new-owner-password
```

Recovery requires the exact sole-owner email, rotates that credential, revokes all
existing sessions, and writes an audit event.

## Auth flow

1. Operators sign in with Better Auth. Sessions live in onshore Postgres.
2. For each coordinator call, the console revalidates the database session, loads
   every current organisation membership, and resolves an explicit or active
   workspace through that set.
3. The console signs a fresh assertion for each coordinator request. It binds the
   actor, role, organisation, exact issuer (`blaktail-console`), audience
   (`blaktail-coord`), action where applicable, a 60-second maximum lifetime, and a
   random nonce. It never contains the Better Auth cookie or session token.
4. Rust verifies every claim and consumes each nonce once. Missing, replayed,
   expired, cross-org, wrong-audience, wrong-issuer, or forged assertions receive
   `401`; valid actors without the required role receive `403`.

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

The Audit log is readable by every organisation member. Bootstrap, invitation use
and revocation, role assignment, denied invitation administration, join-key
minting, browser enrollment approval, friendly-name changes, route approval, ACL
updates, node-key lifetime updates, and console revocation are recorded with actor,
source, and result. Raw bootstrap credentials, invitation tokens, passwords,
sessions, join keys, node tokens, and browser device codes are never included.

## Local development

```sh
cp apps/console/.env.example apps/console/.env
# point DATABASE_URL at onshore Postgres, then:
bun install
bun --filter @blaktail/console db:migrate
# complete the on-host first-owner ceremony above, then:
bun run dev:console
```

Build checks used in CI:

```sh
bun ci
bun run lint
bun run typecheck
bun --filter @blaktail/console db:migrate
bun --filter @blaktail/console test
bun run build
bun --filter @blaktail/console test:auth-e2e
```

Do not pull fonts or analytics from offshore CDNs.

Before public hosting, complete the operator-specific requirements in
[privacy.md](privacy.md): legal name, contact, verified data/backup locations,
retention, subprocessors, and request handling. The generic `/privacy` page does not
invent those deployment-specific facts.
