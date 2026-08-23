# Australia-pinned relay

`blaktail-relay` forwards opaque encrypted UDP payloads when direct WireGuard paths
are unavailable. It refuses to start unless `BLAKTAIL_REGION` is one of the explicit
Australian AWS, Azure, or Google Cloud region identifiers.

```sh
BLAKTAIL_REGION=ap-southeast-2 BLAKTAIL_RELAY_BIND=0.0.0.0:3478 \
  cargo run -p blaktail-relay --release
```

The compact protocol uses a one-byte opcode and 16-byte node id: opcode 1 registers
the sender; opcode 2 addresses the remaining datagram to a registered id; forwarded
packets use opcode 3 and carry the source id. The relay never decrypts tunnel traffic.
The forced-relay round-trip test uses two UDP clients with no direct client path.
