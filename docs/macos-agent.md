# macOS agent

`blaktaild` uses boringtun in-process and opens an Apple `utun` device. It does not require a Network Extension or App Store sandbox. IPv4 `/32` and organisation-scoped ULA IPv6 `/128` tailnet addresses are assigned by the onshore coordinator at registration; the agent never chooses them locally. The agent sets MTU 1280, discovers its relay socket's reflexive UDP address, falls back through the advertised Australian relay when a configured direct endpoint fails, and upgrades to peer-to-peer UDP after a nonce-confirmed hole punch succeeds.

## Build and install

A Mac build is checked on GitHub's hosted macOS runner (`macos-latest`). For local builds, use macOS 13 or later:

No agent release is published yet. After a tagged release, use the signed,
notarised `.pkg` and checksum-verifying installer described in
[releases.md](releases.md); the installer rejects unsigned packages. Until then,
build from source:

```sh
cargo build --release -p blaktaild -p blaktail-config
sudo install -m 0755 target/release/blaktaild /usr/local/bin/blaktaild
sudo install -m 0644 packaging/macos/com.blaktail.agent.plist /Library/LaunchDaemons/com.blaktail.agent.plist
```

Root is required to create/configure `utun` and routes. Agent state, the WireGuard private key, and the coordinator node credential are stored under `/var/lib/blaktail` with mode `0600`. They are never included in logs. Supply a join key through stdin to keep it out of shell history and process listings:

```sh
printf '%s' "$BLAKTAIL_JOIN_KEY" | sudo /usr/local/bin/blaktaild up \
  --coord https://coord.example.org \
  --name mac-one \
  --endpoint 203.0.113.10:51820 \
  --exit-after-join
```

`--exit-after-join` returns after the first successful peer sync; the LaunchDaemon keeps the tunnel alive:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/com.blaktail.agent.plist
sudo /usr/local/bin/blaktaild status
```

The daemon runs `blaktaild run`, which resumes the persisted enrollment and re-applies the full peer set every poll (30 seconds by default). `KeepAlive.NetworkState` and WireGuard's 25-second persistent keepalive restore sessions after sleep/wake and apply node revocations. Logs contain node IDs and peer counts only.

MagicDNS runs as an authoritative UDP stub on the node's tailnet IPv4 address
and still answers both A and AAAA records. The agent writes marked
`/etc/resolver/<org-prefix>.blaktail` and `/etc/resolver/blaktail` files, then
installs the organisation search suffix through `scutil` so both `peer-name`
and the full MagicDNS name resolve. `up --exit-after-join` leaves those files
in place for `blaktaild run`. BlakTail answers only its private suffix and never
forwards public DNS. `down` and `pause` remove only marked files and the
BlakTail `scutil` search entry; unmanaged resolver files are never overwritten.

Share a folder with other devices on the same organisation:

```sh
sudo blaktaild share enable --path /Users/shared/files --name files
```

Peers browse `http://<this-node>.<org>.blaktail:5647/files/` over the overlay.
On another Mac, Finder → Go → Connect to Server and enter that URL (guest,
read-only). The share binds only the tailnet IPv4 address.
`blaktaild share disable` withdraws it.

`blaktaild status` shows credential expiry. To renew without changing the node's
tailnet IP or WireGuard key, mint a fresh join key and pipe it to the agent:

```sh
printf '%s' "$BLAKTAIL_JOIN_KEY" | sudo /usr/local/bin/blaktaild reauth
```

To pause the local tunnel without revoking the node or deleting its enrolment,
unload the daemon and run `pause`. Bootstrap the same LaunchDaemon to resume:

```sh
sudo launchctl bootout system/com.blaktail.agent
sudo /usr/local/bin/blaktaild pause
sudo launchctl bootstrap system /Library/LaunchDaemons/com.blaktail.agent.plist
```

To leave the tailnet, unload the daemon first so launchd cannot restart it, then revoke and erase local state:

```sh
sudo launchctl bootout system/com.blaktail.agent
sudo /usr/local/bin/blaktaild down
```

## Manual two-device test

1. Start `blaktail-coord` on an Australian-hosted TLS endpoint and create one organisation plus two single-use join keys.
2. On Mac A, join as `mac-one`. Note the address printed by `up` (assigned by the coordinator). A reachable `--endpoint` gives the agent an immediate direct candidate; otherwise the relay path remains available.
3. On Mac B (or a compatible Linux WireGuard node), join as `mac-two`. Confirm both devices can send outbound UDP to the relay; inbound port forwarding is optional.
4. Start both LaunchDaemons. Within 30 seconds, run `ping <address-of-B>` from A and `ping <address-of-A>` from B. Both must reply.
5. Sleep Mac A for at least one minute, wake it, and confirm both pings recover within 60 seconds without restarting `blaktaild`.
6. Run `blaktaild down` on B (after `launchctl bootout`) and confirm A removes B on its next peer refresh.
7. Inspect `/var/log/blaktaild.log`; confirm neither join key nor node token appears.

For the IPv6-only inner-path check, note both ULA addresses, remove the BlakTail
IPv4 address from each current `utun` interface, then test both directions:

```sh
sudo ifconfig <utunX> inet <node-IPv4> delete
ping6 <peer-ULA>
```

Restart each LaunchDaemon afterward to restore the dual-stack interface. Relay
frames remain IP-version agnostic because they carry opaque WireGuard ciphertext.

See [upgrades.md](upgrades.md) before replacing the package on an enrolled node.
