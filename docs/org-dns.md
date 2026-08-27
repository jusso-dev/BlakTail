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
- Longest matching split suffix wins. Duplicate suffixes after canonicalisation fail closed.

## Agent apply

Peer poll responses include the published snapshot as `dns`. Agents persist that
snapshot and keep the last successful copy when a later poll omits `dns` or
fails. Extra A/AAAA records are answered locally by full name only. Published
search domains are prepended after the MagicDNS domain (six suffixes total).
Names under a split suffix without a local extra record are forwarded to that
suffix's resolvers. MagicDNS peer names stay coordinator-authoritative:
`*.blaktail` is never forwarded, unknown `*.blaktail` names stay NXDOMAIN, and
public names without an extra record or split match stay REFUSED.

A two-agent extra-record proof is `deploy/homelab/prove-org-dns.sh`.
Packet-capture leak proofs remain on #40.
