# Organisation policy

BlakTail policy is a versioned JSON document stored per organisation. The
coordinator compiles it once on publish. `deny` wins over `allow`. New
organisations start with `"defaults": "deny"`. Existing documents without
`defaults` keep the legacy same-tag and untagged allow; GET shows that as a
visible `generated` rule. `PUT` requires the current `etag` when the caller
sends `If-Match`. Admin `PUT /api/v1/policy` always requires `etag`.
`{"rollback":true}` restores the previous document.

```sh
blaktail-coord check-policy policy.json
```

That command does not open a database or listener. A failing test or an
unknown field rejects the document.

## Schema version 1

```json
{
  "version": 1,
  "defaults": "deny",
  "groups": {
    "rangers": ["alice@example.test", "alice-user"]
  },
  "tag_owners": {
    "office": ["owner-1", "admin"]
  },
  "hosts": {
    "wiki": "10.0.0.10"
  },
  "rules": [
    {
      "action": "allow",
      "src_groups": ["rangers"],
      "dst_tags": ["store"],
      "dst_ports": ["22", "80-443"],
      "protocols": ["tcp"]
    }
  ],
  "ssh": [
    {
      "action": "allow",
      "src_groups": ["rangers"],
      "dst_tags": ["store"],
      "users": ["ubuntu", "deploy"]
    }
  ],
  "tests": [
    {
      "name": "ranger reaches store ssh",
      "src_user": "alice-user",
      "dst_tags": ["store"],
      "dst_port": 22,
      "protocol": "tcp",
      "allow": true
    },
    {
      "name": "office stays isolated",
      "src_tags": ["office"],
      "dst_tags": ["store"],
      "allow": false
    },
    {
      "name": "ranger ssh deploy",
      "src_user": "alice-user",
      "dst_tags": ["store"],
      "ssh_user": "deploy",
      "allow": true
    }
  ]
}
```

- `defaults` is `same_tag` or `deny`. Missing `defaults` is `same_tag` so
  existing meshes keep working. New organisations write `deny`.
- `groups` are named sets of people, identified by user id or email.
- `tag_owners` lists who may assign that tag on a join key or browser
  approval. An unlisted tag keeps the previous owner/admin behaviour. The
  organisation owner remains a break-glass assigner.
- `hosts` names private IPv4 or unique-local IPv6 addresses and CIDRs.
  `.blaktail` and default routes are rejected.
- `rules` select roles, tags, groups, optional `dst_hosts`, `dst_ports`
  (`22`, `80-443`, or `*`), and `protocols` (`tcp`, `udp`, `icmp`). ICMP
  cannot name ports. Peer-map evaluation still includes a peer when any
  port on that path is allowed. Linux agents install an INPUT filter on
  the overlay from each peer's compiled `ingress` grant (destination
  enforcement). Legacy snapshots without `ingress` stay unfiltered.
- `ssh` selects the same source and destination roles, tags, and groups,
  plus operating-system `users` (`ubuntu` or `*`) and `allow` / `deny` /
  `check`. `check` may set `check_period_secs` (1-604800). SSH evaluation
  has no same-tag default. Allowed users are written to
  `sshd_blaktail.conf` as `Match Address` / `AllowUsers` blocks; TCP 22
  is opened only when at least one user is granted. Homelab proof is
  `deploy/homelab/prove-acl-services.sh`.
- `tests` can name `dst_host`, `dst_port`, and `protocol`, or `ssh_user`
  for an SSH decision. A mismatch fails closed. Host-only rules never
  become the implicit same-tag default.

Existing documents without `version` deserialize as v1.
