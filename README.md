# BlakTail

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

A WireGuard mesh VPN for Indigenous organisations. Same job as Tailscale: devices join a tailnet, talk peer to peer, fall back through a relay you run, resolve each other by name. The control plane and relays stay in Australia. The org holds the keys. The code is public.

https://github.com/jusso-dev/BlakTail

## Project status

BlakTail is pre-release. There are no published agent tags or install artifacts yet;
build from source until the release checklist in
[docs/releases.md](docs/releases.md) has been completed on clean hosts.

Direct candidates, an Australian relay fallback, and nonce-confirmed UDP hole
punching are implemented and covered by local tests. The literal two-independent-NAT
deployment proof is still pending in
[#24](https://github.com/jusso-dev/BlakTail/issues/24), so NAT traversal is not yet a
production-verified claim. Dual-stack code is also awaiting its two-node IPv6-only
deployment drill in [#32](https://github.com/jusso-dev/BlakTail/issues/32).

“Onshore” is a deployment responsibility as well as a product rule. Included AWS
infrastructure is pinned to Sydney and the relay rejects non-Australian cloud region
identifiers; self-hosters must independently keep the console database, coordinator
state, TLS proxy, logs, backups, DNS, and support tooling in Australia.

## What v1 does

- Org tailnet: approve devices, issue join keys, revoke a node
- Next.js 16.3 console: Drizzle ORM, Better Auth, talks to the Rust control plane for auth and ACLs
- WireGuard agents for Linux and macOS; Windows is not implemented
- A macOS desktop app that drives the local agent; Windows and Linux desktop apps
  are not implemented
- Coordination server and AU relay the org runs
- MagicDNS-style names and tag ACLs (office, ranger, store)
- Owner-approved Linux subnet routers and opt-in IPv4 exit nodes
- Dual-stack tailnets with an organisation ULA `/64` and one `/128` per node
- Prometheus coordinator/relay metrics and an actor-attributed admin audit log

## What v1 does not do

- No SaaS control plane outside Australia
- No closed-source agent
- Not a file sync tool (that is BlakSync)
- Not a clone of Tailscale's trademark or UI assets
- No Go or Zig

## Console

Operator UI lives in `apps/console` (Next.js 16.3, Better Auth, Drizzle, onshore Postgres).
See [docs/console.md](docs/console.md).

Metrics, audit coverage, and alert examples: [docs/observability.md](docs/observability.md).
The public data-handling page is `/privacy`; operator duties and current retention
limits are in [docs/privacy.md](docs/privacy.md).

## Agent install

Until the first release is published, build the agent on its target operating system:

```sh
cargo build --locked --release -p blaktaild
sudo install -m 0755 target/release/blaktaild /usr/local/bin/blaktaild
```

Release packaging and the checksum-verifying installer support macOS `.pkg`, Debian
`.deb`, and RPM `.rpm` artifacts, but they intentionally fail when the selected
GitHub release does not exist. See [docs/releases.md](docs/releases.md) and the
[upgrade/version-skew policy](docs/upgrades.md).

## Deployment

Host it yourself, on one box or scaled out on AWS:

- **Single EC2 / any Docker host:** `compose.yaml` quickstart in [docs/deploy-aws.md](docs/deploy-aws.md).
- **AWS (Fargate + RDS + EFS + ALB/NLB):** Terraform in `deploy/aws`; console autoscales, while coordinator and relay are pinned to one task until SQLite and relay registration state are sharded. Region is pinned to Sydney (`ap-southeast-2`) — the relay refuses anything else.
- Images: `deploy/docker/*.Dockerfile` and `apps/console/Dockerfile`; push with `scripts/publish-images.sh`.

The Compose/AWS files are deployment inputs, not evidence of a running production
service. Verify TLS, health, metrics, storage, backups, privacy contact/retention,
and an enrolled node on the actual destination.

## Stack (locked for first cut)

- Rust workspace: `blaktaild` (node agent), `blaktail-coord`, `blaktail-relay`
- WireGuard: userspace on macOS first, kernel WG on Linux, userspace on Windows
- Console: Next.js 16.3, Drizzle, Better Auth, Postgres onshore. Auth sessions are issued in the console and verified by Rust
- Desktop: Mac app first (SwiftUI wrapping the LaunchDaemon agent). Windows and Linux follow
- CI on GitHub-hosted runners: `ubuntu-latest` for Rust, console, and security jobs; `macos-latest` for the Swift desktop app
- Apache-2.0

## Threat model

Keys, the onshore control plane, and relays: [docs/threat-model.md](docs/threat-model.md).

That document names the assets (node private keys, join keys, coordinator DB, ACL, relay metadata), the attackers we design for (stolen laptop, leaked join key, curious relay operator, offshore SaaS mistake), the required controls (region pin, `0600` key files, revoke, no payload logs on the relay), and the limits we will not paper over (metadata, unlocked disk, join-key theft). Revoke steps there are copy-pasteable.

## What never goes in git

The repository is public. Secrets are organisation-held and stay off GitHub.

Do not commit:

- Node WireGuard private keys, TLS private keys, PSKs (`*.key`, `*.pem`, `*.psk`)
- Join keys (`btk_…`) or node tokens (`btn_…`)
- Coordinator SQLite/Postgres dumps
- `.env`, `BETTER_AUTH_SECRET`, `BLAKTAIL_CONSOLE_SYNC_SECRET`, database URLs
- Live WireGuard configs (`wg*.conf`)

`.gitignore` blocks the common filename patterns. CI runs gitleaks on every push, plus `cargo deny` against `deny.toml`. A throwaway branch that commits a dummy secret is required to fail that job (`scripts/ci/prove-gitleaks-detects-dummy.sh`). If a real secret lands in git, rotate it; deleting the file in a later commit does not erase the blob.

## Tagline (do not rewrite)

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

## macOS desktop

SwiftUI menu bar app in `apps/macos`. Minimum **macOS 14 Sonoma**. Signs in via Better Auth (ASWebAuthenticationSession), stores the session token in Keychain, and starts/stops local `blaktaild` without the terminal. Join keys travel on stdin only and are not left in argv on quit.

See [`docs/macos-desktop.md`](docs/macos-desktop.md) for build steps, manual validation, and **notarisation** notes (do not buy signing certificates in CI).

```bash
bash scripts/validate-macos-desktop.sh
# on a Mac runner or Mac workstation:
cd apps/macos && swift test
```
