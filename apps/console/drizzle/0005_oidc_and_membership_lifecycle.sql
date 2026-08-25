ALTER TABLE membership ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active';
ALTER TABLE membership DROP CONSTRAINT IF EXISTS membership_status_check;
ALTER TABLE membership ADD CONSTRAINT membership_status_check
  CHECK (status in ('invited', 'active', 'suspended', 'removed'));

CREATE TABLE IF NOT EXISTS identity_provider (
  id text PRIMARY KEY,
  organisation_id text NOT NULL REFERENCES organisation(id) ON DELETE CASCADE,
  issuer text NOT NULL,
  client_id text NOT NULL,
  client_secret text NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  allow_domains_json jsonb NOT NULL DEFAULT '[]',
  allow_subjects_json jsonb NOT NULL DEFAULT '[]',
  jit_membership boolean NOT NULL DEFAULT false,
  default_role text NOT NULL DEFAULT 'member',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organisation_id, issuer)
);

ALTER TABLE identity_provider DROP CONSTRAINT IF EXISTS identity_provider_role_check;
ALTER TABLE identity_provider ADD CONSTRAINT identity_provider_role_check
  CHECK (default_role in ('admin', 'member'));

CREATE TABLE IF NOT EXISTS oidc_login_state (
  id text PRIMARY KEY,
  organisation_id text NOT NULL REFERENCES organisation(id) ON DELETE CASCADE,
  provider_id text NOT NULL REFERENCES identity_provider(id) ON DELETE CASCADE,
  code_verifier text NOT NULL,
  nonce text NOT NULL,
  redirect_to text NOT NULL,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS oidc_login_state_expiry_idx ON oidc_login_state (expires_at);

CREATE TABLE IF NOT EXISTS external_identity (
  id text PRIMARY KEY,
  organisation_id text NOT NULL REFERENCES organisation(id) ON DELETE CASCADE,
  provider_id text NOT NULL REFERENCES identity_provider(id) ON DELETE CASCADE,
  issuer text NOT NULL,
  subject text NOT NULL,
  user_id text NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  email_snapshot text,
  last_authenticated_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (issuer, subject)
);

CREATE INDEX IF NOT EXISTS external_identity_user_idx ON external_identity (user_id);
