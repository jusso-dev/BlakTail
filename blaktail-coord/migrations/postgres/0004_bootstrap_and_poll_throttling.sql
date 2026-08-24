ALTER TABLE device_authorizations ADD COLUMN IF NOT EXISTS last_polled_at BIGINT;

CREATE TABLE IF NOT EXISTS pending_bootstrap_orgs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    acl_json TEXT NOT NULL,
    node_key_ttl_seconds BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS pending_bootstrap_orgs_expiry_idx
    ON pending_bootstrap_orgs(expires_at);
