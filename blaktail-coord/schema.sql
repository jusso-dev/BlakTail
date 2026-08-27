PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS orgs (
 id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
 acl_json TEXT NOT NULL CHECK (json_valid(acl_json)), created_at TEXT NOT NULL,
 node_key_ttl_seconds INTEGER NOT NULL DEFAULT 7776000
   CHECK (node_key_ttl_seconds BETWEEN 86400 AND 31536000),
 audit_retention_seconds INTEGER NOT NULL DEFAULT 7776000
   CHECK (audit_retention_seconds BETWEEN 86400 AND 31536000),
 dns_json TEXT NOT NULL DEFAULT '{"managed":true,"global_resolvers":[],"split":[],"search_domains":[],"records":[]}'
   CHECK (json_valid(dns_json)),
 dns_revision INTEGER NOT NULL DEFAULT 0,
 dns_previous_json TEXT,
 control_revision INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS join_keys (
 id TEXT PRIMARY KEY, org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 key_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL,
 single_use INTEGER NOT NULL CHECK (single_use IN (0,1)), used_at TEXT,
 revoked_at TEXT, created_at TEXT NOT NULL,
 user_id TEXT NOT NULL DEFAULT '', user_role TEXT NOT NULL DEFAULT 'owner',
 tags_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags_json))
);
CREATE TABLE IF NOT EXISTS device_authorizations (
 id TEXT PRIMARY KEY,
 device_code_hash TEXT NOT NULL UNIQUE,
 user_code_hash TEXT NOT NULL UNIQUE,
 requested_name TEXT NOT NULL,
 wg_public_key TEXT NOT NULL,
 expires_at INTEGER NOT NULL,
 approved_at INTEGER,
 consumed_at INTEGER,
 last_polled_at INTEGER,
 org_id TEXT REFERENCES orgs(id) ON DELETE CASCADE,
 user_id TEXT,
 user_role TEXT,
 tags_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags_json))
);
CREATE TABLE IF NOT EXISTS nodes (
 id TEXT PRIMARY KEY, org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 name TEXT NOT NULL, display_name TEXT, wg_public_key TEXT NOT NULL,
 endpoint TEXT,
 allowed_ips_json TEXT NOT NULL CHECK (json_valid(allowed_ips_json)),
 token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, revoked_at TEXT,
 user_id TEXT NOT NULL DEFAULT '', user_role TEXT NOT NULL DEFAULT 'owner',
 tags_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags_json)),
 dns_name TEXT NOT NULL DEFAULT '',
 advertised_routes_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(advertised_routes_json)),
 approved_routes_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(approved_routes_json)),
 credential_expires_at INTEGER NOT NULL DEFAULT 0,
 relay_endpoint TEXT,
 relay_endpoint_updated_at INTEGER,
 last_seen_at INTEGER,
 os TEXT,
 os_version TEXT,
 agent_version TEXT,
 hostname TEXT,
 capabilities_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(capabilities_json)),
 ephemeral INTEGER NOT NULL DEFAULT 0 CHECK (ephemeral IN (0,1)),
 deleted_at INTEGER,
 UNIQUE(org_id,name), UNIQUE(org_id,wg_public_key)
);
CREATE INDEX IF NOT EXISTS nodes_active_org_idx ON nodes(org_id, revoked_at);
CREATE INDEX IF NOT EXISTS device_authorizations_expiry_idx
 ON device_authorizations(expires_at);
CREATE TABLE IF NOT EXISTS audit_events (
 id TEXT PRIMARY KEY,
 org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 actor_user_id TEXT NOT NULL,
 actor_name TEXT NOT NULL DEFAULT '',
 actor_email TEXT NOT NULL DEFAULT '',
 actor_role TEXT NOT NULL,
 action TEXT NOT NULL,
 target_type TEXT NOT NULL,
 target_id TEXT,
 details_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details_json)),
 created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS audit_events_org_created_idx
 ON audit_events(org_id, created_at DESC, id DESC);
CREATE TABLE IF NOT EXISTS console_assertion_nonces (
 jti_hash TEXT PRIMARY KEY,
 expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS console_assertion_nonces_expiry_idx
 ON console_assertion_nonces(expires_at);
CREATE TABLE IF NOT EXISTS pending_bootstrap_orgs (
 id TEXT PRIMARY KEY,
 name TEXT NOT NULL UNIQUE,
 acl_json TEXT NOT NULL CHECK (json_valid(acl_json)),
 node_key_ttl_seconds INTEGER NOT NULL,
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pending_bootstrap_orgs_expiry_idx
 ON pending_bootstrap_orgs(expires_at);
CREATE TABLE IF NOT EXISTS api_clients (
 id TEXT PRIMARY KEY,
 org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 token_hash TEXT NOT NULL UNIQUE,
 token_prefix TEXT NOT NULL,
 scopes_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(scopes_json)),
 created_at INTEGER NOT NULL,
 last_used_at INTEGER,
 expires_at INTEGER,
 revoked_at INTEGER,
 UNIQUE(org_id,name)
);
CREATE INDEX IF NOT EXISTS api_clients_org_idx ON api_clients(org_id, revoked_at);
CREATE TABLE IF NOT EXISTS api_idempotency (
 org_id TEXT NOT NULL,
 client_id TEXT NOT NULL,
 key_hash TEXT NOT NULL,
 method TEXT NOT NULL,
 path TEXT NOT NULL,
 request_hash TEXT NOT NULL,
 status INTEGER NOT NULL,
 body_json TEXT NOT NULL,
 created_at INTEGER NOT NULL,
 PRIMARY KEY (org_id, client_id, key_hash)
);
CREATE TABLE IF NOT EXISTS wireguard_only_peers (
 id TEXT PRIMARY KEY,
 org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 kind TEXT NOT NULL DEFAULT 'wireguard_only' CHECK (kind = 'wireguard_only'),
 wg_public_key TEXT NOT NULL,
 endpoint TEXT NOT NULL,
 allowed_ips_json TEXT NOT NULL CHECK (json_valid(allowed_ips_json)),
 tags_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(tags_json)),
 created_at INTEGER NOT NULL,
 expires_at INTEGER,
 revoked_at INTEGER,
 revision INTEGER NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX IF NOT EXISTS wireguard_only_peers_org_name_idx
 ON wireguard_only_peers(org_id, name) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS wireguard_only_peers_org_key_idx
 ON wireguard_only_peers(org_id, wg_public_key) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS wireguard_only_peers_org_idx
 ON wireguard_only_peers(org_id, revoked_at);
CREATE TABLE IF NOT EXISTS oauth_access_tokens (
 id TEXT PRIMARY KEY,
 org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 api_client_id TEXT NOT NULL REFERENCES api_clients(id) ON DELETE CASCADE,
 token_hash TEXT NOT NULL UNIQUE,
 token_prefix TEXT NOT NULL,
 scopes_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(scopes_json)),
 created_at INTEGER NOT NULL,
 expires_at INTEGER NOT NULL,
 last_used_at INTEGER
);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_client_idx
 ON oauth_access_tokens(api_client_id, expires_at);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_org_idx
 ON oauth_access_tokens(org_id, expires_at);
