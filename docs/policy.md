# Organisation policy

BlakTail policy is a versioned JSON document stored per organisation. The
coordinator compiles it once on publish. `deny` wins over `allow`. When no
rule matches, same-tag peers and untagged peers can still reach each other.

```sh
blaktail-coord check-policy policy.json
```

That command does not open a database or listener. A failing test or an
unknown field rejects the document.

## Schema version 1

```json
{
  "version": 1,
  "groups": {
    "rangers": ["alice@example.test", "alice-user"]
  },
  "tag_owners": {
    "office": ["owner-1", "admin"]
  },
  "rules": [
    {
      "action": "allow",
      "src_groups": ["rangers"],
      "dst_tags": ["store"]
    }
  ],
  "tests": [
    {
      "name": "ranger reaches store",
      "src_user": "alice-user",
      "dst_tags": ["store"],
      "allow": true
    },
    {
      "name": "office stays isolated",
      "src_tags": ["office"],
      "dst_tags": ["store"],
      "allow": false
    }
  ]
}
```

- `groups` are named sets of people, identified by user id or email.
- `tag_owners` lists who may assign that tag on a join key or browser
  approval. An unlisted tag keeps the previous owner/admin behaviour. The
  organisation owner remains a break-glass assigner.
- `rules` still select roles, tags, and groups. Ports, protocols, SSH, and
  hosts are not in v1.
- `tests` are evaluated before activation. A mismatch fails closed.

Existing documents without `version` deserialize as v1.
