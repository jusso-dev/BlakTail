CREATE TABLE IF NOT EXISTS console_assertion_nonces (
    jti_hash TEXT PRIMARY KEY,
    expires_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS console_assertion_nonces_expiry_idx
    ON console_assertion_nonces(expires_at);
