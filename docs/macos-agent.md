# macOS agent

`blaktaild` uses boringtun in-process and opens an Apple `utun` device. It does not require a Network Extension or App Store sandbox. The first cut expects peers to have mutually reachable UDP endpoints; NAT traversal and relay fallback are separate work.

## Build and install

A Mac build is deliberately checked only on a self-hosted Mac runner (`[self-hosted, macOS]`). If that runner is unavailable, build manually on macOS 13 or later:

```sh
cargo build --release -p blaktaild
sudo install -m 0755 target/release/blaktaild /usr/local/bin/blaktaild
sudo install -m 0644 packaging/macos/com.blaktail.agent.plist /Library/LaunchDaemons/com.blaktail.agent.plist
```

Root is required to create/configure `utun` and routes. Agent state, the WireGuard private key, and the coordinator node credential are stored in `/Library/Application Support/BlakTail/agent.json` with mode `0600`. They are never included in logs. Supply a join key through stdin to keep it out of shell history and process listings:

```sh
printf '%s' "$BLAKTAIL_JOIN_KEY" | sudo /usr/local/bin/blaktaild up \
  --coordinator https://coord.example.org \
  --name mac-one --address 100.64.0.1/32 \
  --endpoint 203.0.113.10:51820
```

After the first successful peer sync, stop the foreground process and load the daemon:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/com.blaktail.agent.plist
sudo /usr/local/bin/blaktaild status
```

`KeepAlive.NetworkState`, a 30-second full peer refresh, and WireGuard's 25-second persistent keepalive restore sessions after sleep/wake and apply node revocations. Logs contain node IDs and peer counts only.

To leave the tailnet, unload the daemon first so launchd cannot restart it, then revoke and erase local state:

```sh
sudo launchctl bootout system/com.blaktail.agent
sudo /usr/local/bin/blaktaild down
```

## Manual two-device test

1. Start `blaktail-coord` on an Australian-hosted TLS endpoint and create one organisation plus two single-use join keys.
2. On Mac A, join as `mac-one`, address `100.64.0.1/32`, with a UDP endpoint reachable on port 51820.
3. On Mac B (or a compatible Linux WireGuard node), join as `mac-two`, address `100.64.0.2/32`, with its reachable UDP endpoint. Allow inbound UDP 51820 on both hosts/firewalls.
4. Start both LaunchDaemons. Within 30 seconds, run `ping 100.64.0.2` from A and `ping 100.64.0.1` from B. Both must reply.
5. Sleep Mac A for at least one minute, wake it, and confirm both pings recover within 60 seconds without restarting `blaktaild`.
6. Run `blaktaild down` on B (after `launchctl bootout`) and confirm A removes B on its next peer refresh.
7. Inspect `/var/log/blaktaild.log`; confirm neither join key nor node token appears.
