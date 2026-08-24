PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS orgs (
 id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
 acl_json TEXT NOT NULL CHECK (json_valid(acl_json)), created_at TEXT NOT NULL,
 node_key_ttl_seconds INTEGER NOT NULL DEFAULT 7776000
   CHECK (node_key_ttl_seconds BETWEEN 86400 AND 31536000)
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
