# Australia-pinned relay

`blaktail-relay` forwards opaque encrypted UDP payloads when direct WireGuard paths
are unavailable. It refuses to start unless `BLAKTAIL_REGION` is one of the explicit
Australian AWS, Azure, or Google Cloud region identifiers.

```sh
BLAKTAIL_REGION=ap-southeast-2 \
BLAKTAIL_RELAY_BIND=0.0.0.0:3478 \
BLAKTAIL_RELAY_AUTH_SECRET="$(openssl rand -hex 32)" \
  cargo run -p blaktail-relay --release
```

Coordinator and relay must share `BLAKTAIL_RELAY_AUTH_SECRET`. Keep it distinct
from `BLAKTAIL_AUTH_HMAC_SECRET`: relay compromise must not permit console-session
forgery.

Protocol frames use one-byte opcode plus 16-byte node id:

- `REGISTER` (`1`): node id, expiry, HMAC-SHA256 capability minted by coordinator.
- `SEND` (`2`): destination id plus up to 2,048 bytes of opaque encrypted payload.
- `FORWARDED` (`3`): source id plus opaque payload.
- `PING`/`OBSERVED` (`4`/`5`): authenticated reflexive-address probe.

Registrations expire by capability time and after 120 seconds idle. Clients refresh
every 30 seconds. Relay applies per-source token-bucket limits, rejects oversized
frames, and exposes Prometheus text metrics on `127.0.0.1:9702` by default. It never
decrypts or logs tunnel payloads.

Current registration state is in-memory. Run exactly one relay task per advertised
endpoint; horizontal scale requires sharded endpoint discovery, not a UDP load
balancer spraying nodes across independent task maps.
