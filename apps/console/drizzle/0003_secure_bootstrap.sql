CREATE TABLE "bootstrap_state" (
	"id" text PRIMARY KEY NOT NULL,
	"status" text NOT NULL,
	"token_hash" text,
	"token_expires_at" timestamp with time zone,
	"provisioning_user_id" text,
	"provisioning_organisation_id" text,
	"provisioning_coord_org_id" text,
	"provisioning_email" text,
	"provisioning_owner_name" text,
	"provisioning_organisation_name" text,
	"locked_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "bootstrap_state_singleton_check" CHECK ("id" = 'primary'),
	CONSTRAINT "bootstrap_state_status_check" CHECK ("status" in ('uninitialised', 'claimable', 'provisioning', 'locked'))
);
--> statement-breakpoint
CREATE TABLE "console_audit_event" (
	"id" text PRIMARY KEY NOT NULL,
	"organisation_id" text,
	"actor_user_id" text,
	"actor_email" text DEFAULT '' NOT NULL,
	"actor_role" text NOT NULL,
	"source" text NOT NULL,
	"action" text NOT NULL,
	"result" text NOT NULL,
	"target_type" text NOT NULL,
	"target_id" text,
	"details" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "invitation" (
	"id" text PRIMARY KEY NOT NULL,
	"organisation_id" text NOT NULL,
	"email" text NOT NULL,
	"role" text NOT NULL,
	"token_hash" text NOT NULL,
	"inviter_user_id" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"accepted_at" timestamp with time zone,
	"revoked_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "invitation_token_hash_unique" UNIQUE("token_hash"),
	CONSTRAINT "invitation_role_check" CHECK ("role" in ('admin', 'member')),
	CONSTRAINT "invitation_status_check" CHECK ("status" in ('pending', 'accepted', 'revoked'))
);
--> statement-breakpoint
CREATE TABLE "rate_limit" (
	"id" text PRIMARY KEY NOT NULL,
	"key" text NOT NULL,
	"count" integer NOT NULL,
	"last_request" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "console_audit_event" ADD CONSTRAINT "console_audit_event_organisation_id_organisation_id_fk" FOREIGN KEY ("organisation_id") REFERENCES "public"."organisation"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "invitation" ADD CONSTRAINT "invitation_organisation_id_organisation_id_fk" FOREIGN KEY ("organisation_id") REFERENCES "public"."organisation"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
ALTER TABLE "invitation" ADD CONSTRAINT "invitation_inviter_user_id_user_id_fk" FOREIGN KEY ("inviter_user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "invitation_pending_org_email_unique" ON "invitation" USING btree ("organisation_id","email") WHERE "status" = 'pending';
--> statement-breakpoint
CREATE UNIQUE INDEX "rate_limit_key_unique" ON "rate_limit" USING btree ("key");
--> statement-breakpoint
INSERT INTO "bootstrap_state" ("id", "status", "locked_at")
SELECT
	'primary',
	CASE WHEN EXISTS (
		SELECT 1 FROM "membership" WHERE "role" = 'owner'
	) THEN 'locked' ELSE 'uninitialised' END,
	CASE WHEN EXISTS (
		SELECT 1 FROM "membership" WHERE "role" = 'owner'
	) THEN now() ELSE NULL END;
