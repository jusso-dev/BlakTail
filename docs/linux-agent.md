# Linux node agent

`blaktaild` requires Linux, `iproute2`, `wireguard-tools`, and `CAP_NET_ADMIN` (normally run as root). It first creates a kernel WireGuard interface. If the kernel does not support WireGuard, it tries the Rust `boringtun` binary as a userspace fallback.

```sh
sudo install -d -m 0700 /var/lib/blaktail
sudo blaktaild up --coord https://coord.example.org --join-key "$JOIN_KEY" \
  --endpoint 203.0.113.10:51820
sudo blaktaild status
sudo blaktaild down
```

The coordinator URL must use HTTPS except for localhost testing. The private key and credential-bearing state are stored under `/var/lib/blaktail` with mode `0600`; they are never logged. `up` polls every 30 seconds. A polling failure leaves the last applied WireGuard peer configuration untouched, so live tunnels continue while the coordinator is unavailable.

The agent sets the tunnel MTU to 1280. It starts with each peer's configured UDP
endpoint, moves an unresponsive peer to the advertised Australian relay within one
poll interval, and keeps WireGuard ciphertext flowing there while attempting a
nonce-confirmed UDP hole punch. Successful peer-to-peer traffic bypasses the relay;
stale direct handshakes fall back automatically. The relay socket's reflexive address
is refreshed through the coordinator, so port forwarding is not required for the
relay path.

For systemd, install `packaging/systemd/blaktaild.service` and create `/etc/blaktail/blaktaild.env` (mode `0600`) containing `BLAKTAIL_COORD`, `BLAKTAIL_JOIN_KEY`, and `BLAKTAIL_ENDPOINT`. Remove the join key from that file after the first successful registration; subsequent service design should use persisted enrollment state.
