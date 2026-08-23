# Upgrade and version-skew policy

BlakTail is pre-1.0. The only unconditional compatibility guarantee is that the
coordinator, relay, console, and agents use the same release tag. Arbitrary version
skew is unsupported.

For a rolling upgrade, a release may explicitly support the immediately previous
agent release for 30 days. Its release notes must name that compatibility window;
silence means same-version only. This is an operator-enforced policy because the
current protocol does not negotiate a semantic version. Current additive IPv6 peer
data is capability-gated with `?ipv6=true`, so the version-one schema migration does
not force IPv6 routes onto older agents.

Upgrade in this order:

1. Back up Postgres, coordinator SQLite, configuration, and TLS material.
2. Upgrade one coordinator and its relay. Check `/health`, both metrics listeners,
   and peer polling before continuing.
3. Upgrade one canary agent. Confirm IPv4, IPv6, MagicDNS, direct/relay paths, and
   persisted enrollment after a service restart.
4. Upgrade remaining agents in small batches. End any advertised skew window within
   30 days.
5. Upgrade the console and run its Drizzle migrations when the release notes require
   them.

The Debian and RPM packages do not restart or enable `blaktaild` automatically:

```sh
sudo BLAKTAIL_VERSION=0.1.1 sh install-agent.sh
sudo systemctl restart blaktaild
sudo blaktaild status
```

On macOS, install the pinned package, then restart the existing LaunchDaemon and
check status. Enrollment state remains under `/var/lib/blaktail` and is not part of
the package.

Coordinator SQLite migrations run in one transaction and advance
`PRAGMA user_version`. A coordinator refuses a database created by a newer binary.
Database downgrade is unsupported: restore the pre-upgrade snapshot with the old
binary. Agent rollback is supported only when that release's notes confirm its state
format is compatible.
