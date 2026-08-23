# Coordination server

`blaktail-coord` is the organisation-hosted control plane. It stores only coordination metadata: organisations, ACL JSON, hashed join keys, nodes, WireGuard public keys, and allowed IPs. There is no file-content or general blob table.

## Run on an Australian host

TLS and an explicit region are mandatory. The process refuses to start when `BLAKTAIL_REGION` is missing or empty.

```sh
BLAKTAIL_REGION=ap-southeast-2 \
BLAKTAIL_BIND=0.0.0.0:443 \
BLAKTAIL_DATABASE=/var/lib/blaktail/coord.sqlite3 \
BLAKTAIL_AUTH_HMAC_SECRET=<shared-random-secret-at-least-32-bytes> \
BLAKTAIL_TLS_CERT=/etc/blaktail/tls/fullchain.pem \
BLAKTAIL_TLS_KEY=/etc/blaktail/tls/private.key \
cargo run -p blaktail-coord --release
```

The default database is `blaktail-coord.sqlite3`, suitable for a single office box. SQLite WAL mode and foreign keys are enabled. PostgreSQL is not implemented in v1; it can later be added behind the store interface without changing the API. Set `RUST_LOG=info` for startup, registration, and revocation events. Startup and `GET /health` report the configured region.

## HTTP API

- `POST /v1/orgs` — `{ "name": "org", "acl": { "rules": [] } }`
- `POST /v1/orgs/{org_id}/join-keys` — owner/admin bearer session; `{ "expires_in_seconds": 3600, "single_use": true, "tags": ["office"] }`
- `GET /v1/orgs/{org_id}/nodes` — any org user session; list devices
- `DELETE /v1/orgs/{org_id}/nodes/{node_id}` — owner/admin session; revoke a device
- `POST /v1/nodes/register` — join key, name, WG public key, and optional public endpoint; the server allocates a tailnet IP
- `GET /v1/nodes/{node_id}/peers` — bearer node token; active peers only
- `DELETE /v1/nodes/{node_id}` — bearer node token; self-revocation
- `GET /v1/orgs/{org_id}/acl` — any org user session
- `PUT /v1/orgs/{org_id}/acl` — owner/admin only
- `GET /health`

Join and node credentials are returned once; only SHA-256 hashes are stored. Join keys expire after at most 30 days and default to single-use. Peer polling has no cache, so revocation is visible on the next request (within 60 seconds).

The console verifies Better Auth sessions in onshore Postgres, maps the user to an organisation and role, then issues a short-lived HMAC assertion using the shared `BLAKTAIL_AUTH_HMAC_SECRET`. Rust validates that assertion on every console request and stores no auth sessions. Use independent, randomly generated values of at least 32 bytes for this secret and `BETTER_AUTH_SECRET`. Roles are
`owner`, `admin`, and `member`. Members can read ACLs and device lists but
cannot mint join keys, update ACLs, or revoke devices. A join key binds its
creator's user identity and role plus zero or more of the fixed device tags
`office`, `ranger`, and `store` to the enrolled node.

ACL JSON uses `rules` with `action` (`allow` or `deny`) and optional `src_roles`,
`src_tags`, `dst_roles`, and `dst_tags` arrays. A blank selector matches all. Explicit
deny wins over allow. Without a matching rule, tagged nodes can see only peers sharing
a tag (default deny across tags); legacy untagged nodes can see other untagged nodes.
Peer results include a stable MagicDNS name in the form `<node>.<org-prefix>.blaktail`.

## SQLite schema dump

The canonical executable schema is [`blaktail-coord/schema.sql`](../blaktail-coord/schema.sql). Its tables are:

```sql
CREATE TABLE orgs (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
  acl_json TEXT NOT NULL, created_at TEXT NOT NULL);
CREATE TABLE join_keys (id TEXT PRIMARY KEY, org_id TEXT NOT NULL,
  key_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL,
  single_use INTEGER NOT NULL, used_at TEXT, revoked_at TEXT, created_at TEXT NOT NULL);
CREATE TABLE nodes (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, name TEXT NOT NULL,
  wg_public_key TEXT NOT NULL, endpoint TEXT, allowed_ips_json TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, revoked_at TEXT);
```

The full schema includes foreign keys, JSON checks, uniqueness constraints, and indexes.
