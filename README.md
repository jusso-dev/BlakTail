# BlakTail

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

A WireGuard mesh VPN for Indigenous organisations. Same job as Tailscale: devices join a tailnet, talk peer to peer, fall back through a relay you run, resolve each other by name. The control plane and relays stay in Australia. The org holds the keys. The code is public.

https://github.com/jusso-dev/BlakTail

## What v1 does

- Org tailnet: approve devices, issue join keys, revoke a node
- Next.js 16.3 console: Drizzle ORM, Better Auth, talks to the Rust control plane for auth and ACLs
- WireGuard agents: macOS first, then Linux and Windows
- Desktop apps for Mac, then Windows and Linux, that drive the local agent
- Coordination server and AU relay the org runs
- MagicDNS-style names and tag ACLs (office, ranger, store)

## What v1 does not do

- No SaaS control plane outside Australia
- No closed-source agent
- Not a file sync tool (that is BlakSync)
- Not a clone of Tailscale's trademark or UI assets
- No Go or Zig

## Console

Operator UI lives in `apps/console` (Next.js 16.3, Better Auth, Drizzle, onshore Postgres).
See [docs/console.md](docs/console.md).

## Stack (locked for first cut)

- Rust workspace: `blaktaild` (node agent), `blaktail-coord`, `blaktail-relay`
- WireGuard: userspace on macOS first, kernel WG on Linux, userspace on Windows
- Console: Next.js 16.3, Drizzle, Better Auth, Postgres onshore. Auth sessions are issued in the console and verified by Rust
- Desktop: Mac app first (Swift or Tauri wrapping the agent). Windows and Linux follow
- Self-hosted CI: `runs-on: [self-hosted]` and `[self-hosted, macOS]` for the Mac agent
- Apache-2.0

## Tagline (do not rewrite)

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.
