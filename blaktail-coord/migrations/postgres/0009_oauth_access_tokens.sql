CREATE TABLE IF NOT EXISTS oauth_access_tokens (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    api_client_id TEXT NOT NULL REFERENCES api_clients(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    scopes_json TEXT NOT NULL DEFAULT '[]',
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    last_used_at BIGINT
);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_client_idx
    ON oauth_access_tokens(api_client_id, expires_at);
CREATE INDEX IF NOT EXISTS oauth_access_tokens_org_idx
    ON oauth_access_tokens(org_id, expires_at);
