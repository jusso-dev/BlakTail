# BlakTail

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.

A WireGuard mesh VPN for Indigenous organisations. Same job as Tailscale: devices join a tailnet, talk peer to peer, fall back through a relay you run, resolve each other by name. The control plane and relays stay in Australia. The org holds the keys. The code is public.

https://github.com/jusso-dev/BlakTail

## What v1 does

- Org tailnet: approve devices, issue join keys, revoke a node
- WireGuard tunnels between nodes (kernel or userspace)
- Coordination server the org runs (Sydney or another AU region they pick)
- Optional AU relay when NAT blocks a direct path (DERP-style)
- MagicDNS-style names: `laptop.org.blaktail`
- ACLs: who can reach which tags (office, ranger, store)
- Linux first, then Windows and macOS. Android later

## What v1 does not do

- No SaaS control plane outside Australia
- No closed-source agent
- Not a file sync tool (that is BlakSync)
- Not a clone of Tailscale's trademark or UI assets

## Stack (locked for first cut)

- WireGuard (kernel on Linux, userspace elsewhere)
- Go control plane. Headscale is the reference, not a silent rebrand. Vendor or speak its API, keep BlakTail as the product name and policy layer
- Self-hosted CI: `runs-on: [self-hosted]`
- Apache-2.0

## Tagline (do not rewrite)

Made by indigenous Australians, for indigenous Australia's. Data remains onshore and in control of indigenous Australia orgs, code is public for full transparency.
