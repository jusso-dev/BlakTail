# Console

`apps/console` is the BlakTail operator UI. Next.js 16.3 (App Router), Better Auth,
Drizzle, and onshore Postgres. The Rust coordinator remains the source of truth for
tailnet authorisation.

## Pages

- `/sign-in` — email and password; shows the shared project mission
- `/privacy` — public software data-handling and retention statement
- `/devices` — **All networks** inventory; every row shows its network and
  supports owning-organisation-checked rename, route approval, and revocation
- `/join-keys` — mint join keys (owner/admin)
- `/acls` — read and edit ACL JSON (owner/admin write)
- `/audit` — latest actor-attributed security and administration changes
- `/status` — status-only coordinator readiness; region stays in protected diagnostics
- `/settings` — separate **Network accounts** and **Ways to sign in**, secure
  login linking/unlinking, owner conflict decisions, invitations, and account details
- `/invite?token=…` — one-use invitation acceptance; public account creation remains disabled

## First owner and invitations

Public email/password sign-up is disabled in Better Auth itself. A fresh database
starts `uninitialised`; first ownership must be claimed from a trusted shell where
the console has its normal `DATABASE_URL`, `COORD_BASE_URL`, and
`BLAKTAIL_AUTH_HMAC_SECRET` environment. Run migrations first, then:

Commands below run from `apps/console`; from the repository root, add
`-w @blaktail/console` to each `npm run` command.

```sh
umask 077
openssl rand -base64 32 > owner-password
npm run bootstrap -- init --token-file ./bootstrap-token
npm run bootstrap -- claim \
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
Rerun the exact claim after a transient failure; use `npm run bootstrap -- status`
for a redacted state check. Races produce one owner and one rejection, and a locked
or expired credential cannot create another owner.

Migration locks any deployment already containing an owner. It reports ownerless
console organisations through `status` without silently assigning them. Repair
requires an explicit operator decision.

After bootstrap, owners invite people from `/settings`. Each URL is shown once,
expires after 48 hours, is bound to one email, role, and organisation, and can be
revoked before use. Acceptance atomically creates the account and membership. A
used, expired, revoked, mismatched, or cross-organisation token returns the same
invalid/expired response. Admins and members cannot create or revoke invitations.

Lost sole-owner credentials have no web reset. From a trusted host, create a new
protected password file and run:

```sh
npm run bootstrap -- recover-owner \
  --email owner@example.org.au \
  --password-file ./new-owner-password
```

Recovery requires the exact sole-owner email, rotates that credential, revokes all
existing sessions, and writes an audit event.

## Linked login identities and network accounts

The product invariant is: **one person, many network accounts, one all-machines
view, with no logout/login switching**. The data model intentionally keeps the
person, immutable login identities (Better Auth users), authentication methods
(Better Auth accounts), organisation memberships, and named network accounts as
separate records. Linking changes only the person-to-identity graph. It never
copies a password, OIDC access/refresh token, provider session, or MFA state.

**Link another login** creates a random, hashed-at-rest, ten-minute challenge
bound to the current person, login identity, and Better Auth session. Completion
requires fresh authentication of the second identity. An email address,
invitation URL, existing browser cookie, or cross-origin request is insufficient.
Challenges are single-use; replay, expiry, an already-linked identity, a changed
link graph, or concurrent attempts fail closed and write redacted audit events.
Errors use a generic reauthentication/recovery response so they do not disclose
whether an unrelated identity exists.

A same-organisation role mismatch pauses linking after fresh authentication.
An owner of that organisation must explicitly choose one of the existing roles as
the effective linked-person role. Both membership rows and their original roles
remain intact, and the decision is audited. A changed membership signature
invalidates the decision instead of silently elevating access.

Unlink and revocation require fresh authentication of the current identity.
Unlink moves the other identity back to its own person without deleting its
memberships. Revocation suspends only that identity in the live graph. The console
refuses to remove the last active sign-in or to suspend an identity that would
orphan a sole-owner organisation. Recovery reactivates the identity and is
audited. Existing browser and desktop sessions resolve the graph and memberships
again on every request, so unlink, deletion, suspension, role changes, and network
account revocation take effect on the next request.

Email changes do not relink accounts because identity ownership uses immutable
user IDs, never matching email strings. OIDC identities are keyed by issuer and
subject; a subject change is a new identity requiring the same explicit link or
recovery process. Deleting an identity cascades only its own network accounts and
memberships; unrelated linked identities remain. Provider-specific
reauthentication must preserve provider MFA when OIDC linking is enabled.

The browser `GET /api/me` and desktop `GET /api/desktop/me` responses list all
live organisations and network accounts. The workspace cookie selects only which
organisation-scoped ACL, key, audit, invitation, and enrolment pages are shown; it
is not an authorisation boundary and does not replace the Better Auth session.
Every device mutation from All networks submits the row's organisation ID and
performs a fresh membership/role lookup before a coordinator assertion is signed.


## Auth flow

1. Operators sign in with Better Auth. Sessions live in onshore Postgres.
2. On every request, the console resolves the current identity's live person graph,
   active network accounts, and all organisation memberships. Each coordinator
   mutation then selects the row's owning organisation and checks its live role.
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
npm install
npm run db:migrate -w @blaktail/console
# complete the on-host first-owner ceremony above, then:
npm run dev:console
```

Build checks used in CI:

```sh
npm ci
npm run lint
npm run typecheck
npm test
npm run build
npm run test:auth-e2e
```

Do not pull fonts or analytics from offshore CDNs.

Before public hosting, complete the operator-specific requirements in
[privacy.md](privacy.md): legal name, contact, verified data/backup locations,
retention, subprocessors, and request handling. The generic `/privacy` page does not
invent those deployment-specific facts.
