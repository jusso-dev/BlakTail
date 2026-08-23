PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS orgs (
 id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE,
 acl_json TEXT NOT NULL CHECK (json_valid(acl_json)), created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS join_keys (
 id TEXT PRIMARY KEY, org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 key_hash TEXT NOT NULL UNIQUE, expires_at TEXT NOT NULL,
 single_use INTEGER NOT NULL CHECK (single_use IN (0,1)), used_at TEXT,
 revoked_at TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS nodes (
 id TEXT PRIMARY KEY, org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 name TEXT NOT NULL, wg_public_key TEXT NOT NULL,
 allowed_ips_json TEXT NOT NULL CHECK (json_valid(allowed_ips_json)),
 token_hash TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, revoked_at TEXT,
 UNIQUE(org_id,name), UNIQUE(org_id,wg_public_key)
);
CREATE INDEX IF NOT EXISTS nodes_active_org_idx ON nodes(org_id, revoked_at);
