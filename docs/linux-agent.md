# Linux node agent

`blaktaild` requires Linux, `iproute2`, `wireguard-tools`, and `CAP_NET_ADMIN` (normally run as root). It first creates a kernel WireGuard interface. If the kernel does not support WireGuard, it tries the Rust `boringtun` binary as a userspace fallback.

```sh
sudo install -d -m 0700 /var/lib/blaktail
sudo blaktaild up --coord https://coord.example.org \
  --endpoint 203.0.113.10:51820
sudo blaktaild status
sudo blaktaild down
```

On a fresh node, `up` prints a ten-minute console URL and waits. Open that URL on
any browser, sign in, confirm the displayed name and WireGuard-key fingerprint,
then approve the node. This works unchanged over SSH and never requires copying a
join key. Automation may still pass `--join-key`, set `BLAKTAIL_JOIN_KEY`, or pipe
the key on stdin.

The coordinator URL must use HTTPS except for localhost testing. The private key and credential-bearing state are stored under `/var/lib/blaktail` with mode `0600`; they are never logged. `up` polls every 30 seconds. A polling failure leaves the last applied WireGuard peer configuration untouched, so live tunnels continue while the coordinator is unavailable.

The agent sets the tunnel MTU to 1280. It starts with each peer's configured UDP
endpoint, moves an unresponsive peer to the advertised Australian relay within one
poll interval, and keeps WireGuard ciphertext flowing there while attempting a
nonce-confirmed UDP hole punch. Successful peer-to-peer traffic bypasses the relay;
stale direct handshakes fall back automatically. The relay socket's reflexive address
is refreshed through the coordinator, so port forwarding is not required for the
relay path.

## MagicDNS

The agent runs an authoritative UDP DNS stub on its own tailnet address, port 53.
It answers only A records for the node and currently authorised peers under the
organisation's `<org-prefix>.blaktail` domain. Unknown private names return
`NXDOMAIN`; names outside that suffix are refused and never forwarded by BlakTail.
Both `peer-name` and `peer-name.<org-prefix>.blaktail` resolve locally.

On systemd-resolved hosts, the agent installs a per-interface search and route-only
domain with `resolvectl`; otherwise it uses `resolvconf`. The final fallback safely
backs up and prepends `/etc/resolv.conf`, refuses to overwrite a symlink, and restores
the exact backup on `blaktaild down`. If the file changes after BlakTail manages it,
the agent preserves the backup and refuses to overwrite the operator's change.

## Credential renewal

`blaktaild status` shows the node credential expiry. Renew an expired or expiring
enrolment with a fresh join key; the node keeps its tailnet IP and WireGuard key:

```sh
printf '%s' "$BLAKTAIL_JOIN_KEY" | sudo blaktaild reauth
```

For systemd, install `packaging/systemd/blaktaild.service` and create `/etc/blaktail/blaktaild.env` (mode `0600`) containing `BLAKTAIL_COORD`, `BLAKTAIL_JOIN_KEY`, and `BLAKTAIL_ENDPOINT`. Remove the join key from that file after the first successful registration; subsequent service design should use persisted enrollment state.
