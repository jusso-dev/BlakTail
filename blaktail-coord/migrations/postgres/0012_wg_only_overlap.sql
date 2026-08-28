ALTER TABLE wireguard_only_peers ADD COLUMN IF NOT EXISTS previous_wg_public_key TEXT;
ALTER TABLE wireguard_only_peers ADD COLUMN IF NOT EXISTS overlap_until BIGINT;
ALTER TABLE wireguard_only_peers ADD COLUMN IF NOT EXISTS overlap_peer_id TEXT;
