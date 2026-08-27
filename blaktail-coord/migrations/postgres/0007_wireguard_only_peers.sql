CREATE TABLE IF NOT EXISTS wireguard_only_peers (
 id TEXT PRIMARY KEY,
 org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 kind TEXT NOT NULL DEFAULT 'wireguard_only' CHECK (kind = 'wireguard_only'),
 wg_public_key TEXT NOT NULL,
 endpoint TEXT NOT NULL,
 allowed_ips_json TEXT NOT NULL,
 tags_json TEXT NOT NULL DEFAULT '[]',
 created_at BIGINT NOT NULL,
 expires_at BIGINT,
 revoked_at BIGINT,
 revision BIGINT NOT NULL DEFAULT 1
);
CREATE UNIQUE INDEX IF NOT EXISTS wireguard_only_peers_org_name_idx
 ON wireguard_only_peers(org_id, name) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS wireguard_only_peers_org_key_idx
 ON wireguard_only_peers(org_id, wg_public_key) WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS wireguard_only_peers_org_idx
 ON wireguard_only_peers(org_id, revoked_at);
