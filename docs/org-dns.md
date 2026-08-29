# Organisation DNS settings

Owners and admins publish a versioned DNS snapshot for their organisation.
MagicDNS peer names stay coordinator-authoritative: agents never forward
`*.blaktail` to an upstream.

## Document

```json
{
  "managed": true,
  "global_resolvers": ["1.1.1.1"],
  "split": [{"suffix": "internal.example", "resolvers": ["10.0.0.53"]}],
  "search_domains": ["internal.example"],
  "records": [
    {"name": "wiki.internal.example", "type": "A", "value": "10.0.0.10"}
  ]
}
```

Validate offline without a database:

```sh
blaktail-coord check-dns docs/dns/v1-example.json
```

Publish through the console Settings page or `PUT /api/v1/dns` with `dns:write`.
Each successful publish increments `revision`, stores the previous document for
one-step rollback, and requires the current `etag` when `If-Match` or `etag` is
sent. Members are read-only.

## Limits

- Domains are lower-cased, trailing dots stripped, and passed through IDNA.
- Root, wildcard, empty-label, and mixed-script names are rejected.
- Split suffixes, search domains, and extra records cannot use `.blaktail`.
- Extra A/AAAA records must sit under a configured split suffix or search domain.
- Resolvers are IPv4 or IPv6 addresses only. Encrypted transport is not in this slice.
- `global_resolvers` are stored and used when probing a new snapshot. They are
  not a public recursive forwarder; names outside MagicDNS, extra records, and
  split suffixes stay REFUSED.
- Longest matching split suffix wins. Duplicate suffixes after canonicalisation fail closed.

## Agent apply

Peer poll responses include the published snapshot as `dns`. Agents persist that
snapshot, report the applied revision on the next poll, and keep the last
successful copy when a later poll omits `dns` or fails. Extra A/AAAA records
are answered locally by full name only. Published search domains are prepended
after the MagicDNS domain (six suffixes total). The console Settings page shows
which extra records match a split suffix and how many enrolled devices have
applied the current revision.
Names under a split suffix without a local extra record are forwarded to that
suffix's resolvers. MagicDNS peer names stay coordinator-authoritative:
`*.blaktail` is never forwarded, unknown `*.blaktail` names stay NXDOMAIN, and
public names without an extra record or split match stay REFUSED.

When a newer snapshot adds resolvers, the agent probes those addresses with a
short UDP query for a published extra-record or split name. If every new
resolver is silent and a previous snapshot exists, the agent keeps that
last-known-good copy, leaves extra records and split forwards unchanged, and
reports `dns health: degraded` from `blaktaild status`. A first snapshot is
still adopted even if its resolvers are unreachable so local extra records can
answer. Record-only or search-only updates do not probe.

Publishing `managed: false` is adopted without probing. Extra records, search
domains, and split forwards stop answering immediately. The MagicDNS stub keeps
serving `*.blaktail` peer names on the overlay address, and any host resolver
files BlakTail wrote (`resolvectl`, `resolvconf`, `/etc/resolv.conf`, or
`/etc/resolver`) are restored to the pre-BlakTail copy. `blaktaild status`
reports `dns managed: no`. `blaktaild down` still restores the same files.

A two-agent extra A and AAAA proof is `deploy/homelab/prove-org-dns.sh`.
Homelab `deploy/homelab/prove-dns-noleak.sh` captures eth0/lo while querying an
extra record, an unknown `*.blaktail` name, a public name, and a split suffix:
only the published sink sees the split query.
Homelab `deploy/homelab/prove-dns-lastgood.sh` publishes a working extra A,
then a rewritten extra A plus an unreachable split resolver, and checks the
agent keeps the first revision and answers the original address.
Homelab `deploy/homelab/prove-dns-restore.sh` then publishes `managed: false`
and checks the extra A is refused while the node MagicDNS name still answers.
