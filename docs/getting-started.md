# Getting started

This is the laptop path. The [README](../README.md) is the short version.
`scripts/quickstart.sh` (or `make up`) is the supported first command.

## Prerequisites

Nothing in this path is optional. Install these before you clone:

| Need | Why |
| --- | --- |
| Docker Engine with Compose v2 (`docker compose`) | Console, coordinator, relay, and Postgres |
| OpenSSL | Throwaway coordinator certificates and owner password |
| `curl` | Quickstart waits until the console and coordinator answer |
| Rust 1.98 via rustup | This repo's `rust-toolchain.toml`; required to build `blaktaild` |
| Linux: `iproute2`, `wireguard-tools`, `iptables` | Kernel WireGuard path |
| Root or `CAP_NET_ADMIN` | Creating `blaktail0` / `utun` |
| A few GB of disk | First image build compiles Rust and Next.js |

macOS 14+ can also run the native desktop app after the agent is installed.
There is no published agent package yet; [releases.md](releases.md) explains
why `scripts/install-agent.sh` is not a quickstart.

## What `scripts/quickstart.sh` does

1. Refuses to start without `openssl` and `docker compose`.
2. Detects a local or remote Docker engine (`DOCKER_CONTEXT`). Schema v1
   only allows HTTP on loopback, so a remote engine keeps
   `http://localhost:3000` and forwards ports 3000 and 8443 over SSH. The
   relay is advertised at the remote host so agents can send UDP there.
3. Writes a mode-`0600` `.env` when missing and keeps console/relay URLs
   aligned with that Docker host.
4. Runs `docker compose up -d --build --wait`. `certs-init` writes throwaway
   coordinator certificates into the `coordcerts` volume. Do not reuse them
   in production. The CA is copied to `certs/ca.crt` on this machine for the
   agent; private keys stay in the volume.
5. Waits until the console answers from inside Compose, so it works when
   published ports are on another host.
6. Claims the first owner if bootstrap is not already locked, writing
   `./owner-password` at mode `0600`. Secrets are copied into the console
   with `docker compose cp`, not bind-mounted. A retry keeps the bootstrap
   token in `.quickstart/bootstrap-token` so a failed claim does not require
   waiting out the 15-minute expiry.

Override the owner with `OWNER_EMAIL`, `OWNER_NAME`, and `ORGANISATION_NAME`.

Sign in at [http://localhost:3000](http://localhost:3000) with
`owner@example.org.au` and the password file. Then:

```sh
cargo build --locked --release -p blaktaild -p blaktail-config
sudo install -m 0755 target/release/blaktaild /usr/local/bin/blaktaild
sudo install -m 0755 target/release/blaktail-config /usr/local/bin/blaktail-config
sudo blaktaild up --coord https://127.0.0.1:8443 --coord-ca certs/ca.crt
```

Open the printed `/enroll?code=…` link, approve the device, then
`sudo blaktaild status`.

Annotated inputs: [examples/](../examples/). Full schema:
[configuration.md](configuration.md).

## A second machine

On the other host, build the agent the same way and point it at this laptop's
reachable address, not `127.0.0.1`:

```sh
sudo blaktaild up \
  --coord https://<laptop-lan-ip>:8443 \
  --coord-ca /path/to/ca.crt
```

Copy only `certs/ca.crt`. Never copy `certs/ca.key` or `certs/coord.key`. Open
the coordinator and relay ports (`8443/tcp`, `3478/udp`) on the laptop if the
peer is not local. The coordinator advertises `BLAKTAIL_RELAY_ENDPOINT` from
`.env`; for two machines on one LAN, set that to the laptop's LAN address
before `docker compose up`.

## Tear down

```sh
make down                 # docker compose down; volumes stay
docker compose down -v    # also deletes Postgres and coordinator state
```

Then remove `./owner-password`, `./.env`, and `certs/` if you do not need them.
`blaktaild down` on each node revokes that enrolment.

## Troubleshooting

**`UnsupportedSchema` or Postgres password authentication failed.** Compose
reused volumes from an older or newer checkout. `docker compose down -v`
deletes that local state; then run `scripts/quickstart.sh` again.

**Compose exits asking for `POSTGRES_PASSWORD`.** You started `docker compose`
without `.env`. Run `scripts/quickstart.sh`, or copy
[examples/env.local](../examples/env.local) to `.env` and replace every
`change-me` value.

**Port 3000, 8443, or 3478 is busy.** Another Compose project or process has
the port. Stop that listener, or set `COMPOSE_PROJECT_NAME` and change the
published ports in `compose.yaml`.

**`bootstrap is not locked` / claim failed.** Bootstrap credentials expire in
15 minutes. Re-run `scripts/quickstart.sh`; it skips a locked owner and retries
an unfinished claim. Recover a lost sole-owner password with
[console.md](console.md#first-owner-and-invitations).

**Agent TLS errors.** The coordinator uses the throwaway CA. Pass
`--coord-ca certs/ca.crt` or `BLAKTAIL_COORD_CA`. The certificate SAN includes
`localhost` and `127.0.0.1`, plus the Docker host when Compose is remote.

**`certificate file could not be read` during migrate.** An older Compose file
bind-mounted `./certs`. Current `compose.yaml` generates certs in the
`coordcerts` volume. Pull the latest file and run `docker compose up` again.

**Console is not on localhost.** If `docker context` points at another machine,
quickstart forwards `localhost:3000` and `localhost:8443` over SSH. Open
[http://localhost:3000](http://localhost:3000). The relay stays on the remote
host so UDP does not need a tunnel.

**Console cookie / sign-in loop.** Use `http://localhost:3000`, the same origin
as `BETTER_AUTH_URL`. Mixing `localhost` and `127.0.0.1` in the browser will
drop the session.

**Linux agent cannot create `blaktail0`.** Run as root and install
`wireguard-tools`. The agent falls back to `boringtun` when the kernel has no
WireGuard.

**`install-agent.sh` failed.** That is expected until a tagged release exists.

## After the laptop

- Invite people and mint join keys from the console:
  [console.md](console.md).
- Linux routes and exit nodes: [linux-agent.md](linux-agent.md).
- macOS desktop and iPhone: [macos-desktop.md](macos-desktop.md),
  [ios.md](ios.md).
- Single EC2 host or disposable Sydney AWS:
  [deploy-aws.md](deploy-aws.md).
- What is implemented today: [project-status.md](project-status.md).
