CREATE TABLE "person" (
  "id" text PRIMARY KEY NOT NULL,
  "display_name" text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "person_login_identity" (
  "id" text PRIMARY KEY NOT NULL,
  "person_id" text NOT NULL,
  "user_id" text NOT NULL,
  "status" text DEFAULT 'active' NOT NULL,
  "linked_at" timestamp with time zone DEFAULT now() NOT NULL,
  "suspended_at" timestamp with time zone,
  CONSTRAINT "person_login_identity_status_check"
    CHECK ("status" in ('active', 'suspended'))
);
--> statement-breakpoint
CREATE TABLE "network_account" (
  "id" text PRIMARY KEY NOT NULL,
  "membership_id" text NOT NULL,
  "login_identity_user_id" text NOT NULL,
  "organisation_id" text NOT NULL,
  "name" text NOT NULL,
  "status" text DEFAULT 'active' NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "revoked_at" timestamp with time zone,
  CONSTRAINT "network_account_status_check"
    CHECK ("status" in ('active', 'revoked'))
);
--> statement-breakpoint
CREATE TABLE "identity_link_challenge" (
  "id" text PRIMARY KEY NOT NULL,
  "token_hash" text NOT NULL,
  "requester_person_id" text NOT NULL,
  "requester_user_id" text NOT NULL,
  "requester_session_id" text NOT NULL,
  "target_user_id" text,
  "status" text DEFAULT 'pending' NOT NULL,
  "failure_code" text,
  "expires_at" timestamp with time zone NOT NULL,
  "authenticated_at" timestamp with time zone,
  "completed_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "identity_link_challenge_token_hash_unique" UNIQUE("token_hash"),
  CONSTRAINT "identity_link_challenge_status_check"
    CHECK ("status" in ('pending', 'awaiting_owner', 'succeeded', 'rejected', 'expired'))
);
--> statement-breakpoint
CREATE TABLE "identity_link_conflict" (
  "id" text PRIMARY KEY NOT NULL,
  "challenge_id" text NOT NULL,
  "organisation_id" text NOT NULL,
  "requester_role" text NOT NULL,
  "target_role" text NOT NULL,
  "resolved_role" text,
  "resolved_by_user_id" text,
  "resolved_at" timestamp with time zone,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "identity_link_conflict_roles_check" CHECK (
    "requester_role" in ('owner', 'admin', 'member')
    AND "target_role" in ('owner', 'admin', 'member')
    AND ("resolved_role" IS NULL OR "resolved_role" in ('owner', 'admin', 'member'))
  )
);
--> statement-breakpoint
CREATE TABLE "membership_role_resolution" (
  "id" text PRIMARY KEY NOT NULL,
  "person_id" text NOT NULL,
  "organisation_id" text NOT NULL,
  "effective_role" text NOT NULL,
  "membership_signature" text NOT NULL,
  "resolved_by_user_id" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  CONSTRAINT "membership_role_resolution_role_check"
    CHECK ("effective_role" in ('owner', 'admin', 'member'))
);
--> statement-breakpoint
ALTER TABLE "person_login_identity"
  ADD CONSTRAINT "person_login_identity_person_id_person_id_fk"
  FOREIGN KEY ("person_id") REFERENCES "public"."person"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "person_login_identity"
  ADD CONSTRAINT "person_login_identity_user_id_user_id_fk"
  FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "network_account"
  ADD CONSTRAINT "network_account_membership_id_membership_id_fk"
  FOREIGN KEY ("membership_id") REFERENCES "public"."membership"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "network_account"
  ADD CONSTRAINT "network_account_login_identity_user_id_user_id_fk"
  FOREIGN KEY ("login_identity_user_id") REFERENCES "public"."user"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "network_account"
  ADD CONSTRAINT "network_account_organisation_id_organisation_id_fk"
  FOREIGN KEY ("organisation_id") REFERENCES "public"."organisation"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_challenge"
  ADD CONSTRAINT "identity_link_challenge_requester_person_id_person_id_fk"
  FOREIGN KEY ("requester_person_id") REFERENCES "public"."person"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_challenge"
  ADD CONSTRAINT "identity_link_challenge_requester_user_id_user_id_fk"
  FOREIGN KEY ("requester_user_id") REFERENCES "public"."user"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_challenge"
  ADD CONSTRAINT "identity_link_challenge_requester_session_id_session_id_fk"
  FOREIGN KEY ("requester_session_id") REFERENCES "public"."session"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_challenge"
  ADD CONSTRAINT "identity_link_challenge_target_user_id_user_id_fk"
  FOREIGN KEY ("target_user_id") REFERENCES "public"."user"("id") ON DELETE set null;
--> statement-breakpoint
ALTER TABLE "identity_link_conflict"
  ADD CONSTRAINT "identity_link_conflict_challenge_id_identity_link_challenge_id_fk"
  FOREIGN KEY ("challenge_id") REFERENCES "public"."identity_link_challenge"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_conflict"
  ADD CONSTRAINT "identity_link_conflict_organisation_id_organisation_id_fk"
  FOREIGN KEY ("organisation_id") REFERENCES "public"."organisation"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "identity_link_conflict"
  ADD CONSTRAINT "identity_link_conflict_resolved_by_user_id_user_id_fk"
  FOREIGN KEY ("resolved_by_user_id") REFERENCES "public"."user"("id") ON DELETE set null;
--> statement-breakpoint
ALTER TABLE "membership_role_resolution"
  ADD CONSTRAINT "membership_role_resolution_person_id_person_id_fk"
  FOREIGN KEY ("person_id") REFERENCES "public"."person"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "membership_role_resolution"
  ADD CONSTRAINT "membership_role_resolution_organisation_id_organisation_id_fk"
  FOREIGN KEY ("organisation_id") REFERENCES "public"."organisation"("id") ON DELETE cascade;
--> statement-breakpoint
ALTER TABLE "membership_role_resolution"
  ADD CONSTRAINT "membership_role_resolution_resolved_by_user_id_user_id_fk"
  FOREIGN KEY ("resolved_by_user_id") REFERENCES "public"."user"("id") ON DELETE set null;
--> statement-breakpoint
CREATE UNIQUE INDEX "person_login_identity_user_unique"
  ON "person_login_identity" ("user_id");
--> statement-breakpoint
CREATE INDEX "person_login_identity_person_status_idx"
  ON "person_login_identity" ("person_id", "status");
--> statement-breakpoint
CREATE UNIQUE INDEX "network_account_membership_unique"
  ON "network_account" ("membership_id");
--> statement-breakpoint
CREATE INDEX "network_account_organisation_idx"
  ON "network_account" ("organisation_id");
--> statement-breakpoint
CREATE INDEX "network_account_identity_active_idx"
  ON "network_account" ("login_identity_user_id", "status");
--> statement-breakpoint
CREATE UNIQUE INDEX "identity_link_conflict_challenge_org_unique"
  ON "identity_link_conflict" ("challenge_id", "organisation_id");
--> statement-breakpoint
CREATE UNIQUE INDEX "identity_link_challenge_open_person_unique"
  ON "identity_link_challenge" ("requester_person_id")
  WHERE "status" in ('pending', 'awaiting_owner');
--> statement-breakpoint
CREATE UNIQUE INDEX "membership_role_resolution_person_org_unique"
  ON "membership_role_resolution" ("person_id", "organisation_id");
--> statement-breakpoint
INSERT INTO "person" ("id", "display_name", "created_at", "updated_at")
SELECT "id", "name", "created_at" AT TIME ZONE 'UTC',
  "updated_at" AT TIME ZONE 'UTC'
FROM "user";
--> statement-breakpoint
INSERT INTO "person_login_identity" ("id", "person_id", "user_id")
SELECT 'identity_' || "id", "id", "id" FROM "user";
--> statement-breakpoint
INSERT INTO "network_account" (
  "id", "membership_id", "login_identity_user_id", "organisation_id", "name"
)
SELECT 'network_' || m."id", m."id", m."user_id", m."organisation_id", o."name"
FROM "membership" m
JOIN "organisation" o ON o."id" = m."organisation_id";
