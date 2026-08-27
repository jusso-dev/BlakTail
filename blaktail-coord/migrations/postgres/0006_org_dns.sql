ALTER TABLE orgs ADD COLUMN IF NOT EXISTS dns_json TEXT NOT NULL DEFAULT '{"managed":true,"global_resolvers":[],"split":[],"search_domains":[],"records":[]}';
ALTER TABLE orgs ADD COLUMN IF NOT EXISTS dns_revision BIGINT NOT NULL DEFAULT 0;
ALTER TABLE orgs ADD COLUMN IF NOT EXISTS dns_previous_json TEXT;
