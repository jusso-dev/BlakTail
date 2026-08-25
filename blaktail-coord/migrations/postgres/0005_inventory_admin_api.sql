ALTER TABLE orgs ADD COLUMN IF NOT EXISTS audit_retention_seconds BIGINT NOT NULL DEFAULT 7776000;
ALTER TABLE orgs DROP CONSTRAINT IF EXISTS orgs_audit_retention_seconds_check;
ALTER TABLE orgs ADD CONSTRAINT orgs_audit_retention_seconds_check
    CHECK (audit_retention_seconds BETWEEN 86400 AND 31536000);

ALTER TABLE nodes ADD COLUMN IF NOT EXISTS last_seen_at BIGINT;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS os TEXT;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS os_version TEXT;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS agent_version TEXT;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS hostname TEXT;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS capabilities_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS ephemeral BIGINT NOT NULL DEFAULT 0;
ALTER TABLE nodes ADD COLUMN IF NOT EXISTS deleted_at BIGINT;

CREATE TABLE IF NOT EXISTS api_clients (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    scopes_json TEXT NOT NULL DEFAULT '[]',
    created_at BIGINT NOT NULL,
    last_used_at BIGINT,
    expires_at BIGINT,
    revoked_at BIGINT,
    UNIQUE (org_id, name)
);
CREATE INDEX IF NOT EXISTS api_clients_org_idx ON api_clients(org_id, revoked_at);

CREATE TABLE IF NOT EXISTS api_idempotency (
    org_id TEXT NOT NULL,
    client_id TEXT NOT NULL,
    key_hash TEXT NOT NULL,
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    request_hash TEXT NOT NULL DEFAULT '',
    status INTEGER NOT NULL,
    body_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (org_id, client_id, key_hash)
);
ALTER TABLE api_idempotency ADD COLUMN IF NOT EXISTS request_hash TEXT NOT NULL DEFAULT '';
