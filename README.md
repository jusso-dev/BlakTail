# BlakTail

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

A WireGuard mesh VPN for Indigenous organisations. Same job as Tailscale: devices join a tailnet, talk peer to peer, fall back through a relay you run, resolve each other by name. The control plane and relays stay in Australia. The org holds the keys. The code is public.

https://github.com/jusso-dev/BlakTail

## What v1 does

- Org tailnet: approve devices, issue join keys, revoke a node
- WireGuard tunnels between nodes (Linux kernel WG, userspace Rust elsewhere)
- Coordination server the org runs (Sydney or another AU region they pick)
- Optional AU relay when NAT blocks a direct path (DERP-style, Rust)
- MagicDNS-style names: `laptop.org.blaktail`
- ACLs: who can reach which tags (office, ranger, store)
- Linux first, then Windows and macOS. Android later

## What v1 does not do

- No SaaS control plane outside Australia
- No closed-source agent
- Not a file sync tool (that is BlakSync)
- Not a clone of Tailscale's trademark or UI assets
- No Go or Zig in v1

## Stack (locked for first cut)

- Rust (edition 2021), one workspace: `blaktaild` (node), `blaktail-coord` (control plane), `blaktail-relay`
- WireGuard: kernel module on Linux, `boringtun` or equivalent userspace where needed
- Headscale and Tailscale are references only. Do not vendor Go. Speak the ideas, write Rust.
- Self-hosted CI: `runs-on: [self-hosted]`
- Apache-2.0

## Tagline (do not rewrite)

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

## Build

Requires [rustup](https://rustup.rs/) on Linux. The pinned toolchain is in `rust-toolchain.toml`.

```bash
cargo build --release
```

Binaries land in `target/release/`: `blaktaild`, `blaktail-coord`, `blaktail-relay`.

```bash
cargo test
```

CI runs `cargo fmt --check`, `clippy -D warnings`, and `cargo test` on self-hosted runners only (`runs-on: [self-hosted]`). Licence: Apache-2.0.
