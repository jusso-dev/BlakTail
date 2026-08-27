CREATE TABLE IF NOT EXISTS webhook_destinations (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    signing_secret TEXT NOT NULL,
    secret_hash TEXT NOT NULL,
    secret_prefix TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at BIGINT NOT NULL,
    UNIQUE (org_id, name)
);
CREATE TABLE IF NOT EXISTS webhook_outbox (
    id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
    destination_id TEXT NOT NULL REFERENCES webhook_destinations(id) ON DELETE CASCADE,
    event_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    next_attempt_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    last_error TEXT,
    delivered_at BIGINT,
    dead_lettered_at BIGINT,
    UNIQUE (destination_id, event_id)
);
CREATE INDEX IF NOT EXISTS webhook_outbox_due_idx
    ON webhook_outbox(next_attempt_at, delivered_at, dead_lettered_at);
CREATE INDEX IF NOT EXISTS webhook_destinations_org_idx
    ON webhook_destinations(org_id, enabled);
