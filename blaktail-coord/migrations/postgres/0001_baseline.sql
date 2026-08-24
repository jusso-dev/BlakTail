CREATE TABLE IF NOT EXISTS orgs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    acl_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    node_key_ttl_seconds BIGINT NOT NULL DEFAULT 7776000
        CHECK (node_key_ttl_seconds BETWEEN 86400 AND 31536000)
);

CREATE TABLE IF NOT EXISTS join_keys (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    key_hash TEXT NOT NULL UNIQUE,
    expires_at BIGINT NOT NULL,
    single_use BIGINT NOT NULL CHECK (single_use IN (0, 1)),
    used_at BIGINT,
    revoked_at BIGINT,
    created_at BIGINT NOT NULL,
    user_id TEXT NOT NULL DEFAULT '',
    user_role TEXT NOT NULL DEFAULT 'owner',
    tags_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS device_authorizations (
    id TEXT PRIMARY KEY,
    device_code_hash TEXT NOT NULL UNIQUE,
    user_code_hash TEXT NOT NULL UNIQUE,
    requested_name TEXT NOT NULL,
    wg_public_key TEXT NOT NULL,
    expires_at BIGINT NOT NULL,
    approved_at BIGINT,
    consumed_at BIGINT,
    org_id TEXT REFERENCES orgs(id) ON DELETE CASCADE,
    user_id TEXT,
    user_role TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]'
);

CREATE INDEX IF NOT EXISTS device_authorizations_expiry_idx
    ON device_authorizations(expires_at);

CREATE TABLE IF NOT EXISTS nodes (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    wg_public_key TEXT NOT NULL,
    endpoint TEXT,
    allowed_ips_json TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    created_at BIGINT NOT NULL,
    revoked_at BIGINT,
    user_id TEXT NOT NULL DEFAULT '',
    user_role TEXT NOT NULL DEFAULT 'owner',
    tags_json TEXT NOT NULL DEFAULT '[]',
    dns_name TEXT NOT NULL DEFAULT '',
    advertised_routes_json TEXT NOT NULL DEFAULT '[]',
    approved_routes_json TEXT NOT NULL DEFAULT '[]',
    credential_expires_at BIGINT NOT NULL DEFAULT 0,
    relay_endpoint TEXT,
    relay_endpoint_updated_at BIGINT,
    UNIQUE(org_id, name),
    UNIQUE(org_id, wg_public_key)
);

CREATE UNIQUE INDEX IF NOT EXISTS nodes_dns_name_org_idx
    ON nodes(org_id, dns_name) WHERE dns_name <> '';
CREATE INDEX IF NOT EXISTS nodes_active_org_idx ON nodes(org_id, revoked_at);

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
    details_json TEXT NOT NULL DEFAULT '{}',
    created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS audit_events_org_created_idx
    ON audit_events(org_id, created_at DESC, id DESC);
