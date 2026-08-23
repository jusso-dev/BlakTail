ALTER TABLE "account" ADD COLUMN "issuer" text;
--> statement-breakpoint
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM "account" WHERE "provider_id" <> 'credential'
  ) THEN
    RAISE EXCEPTION 'manual Better Auth issuer backfill required for non-credential accounts';
  END IF;
END $$;
--> statement-breakpoint
UPDATE "account"
SET "issuer" = 'local:credential', "account_id" = "user_id"
WHERE "provider_id" = 'credential';
--> statement-breakpoint
ALTER TABLE "account" ALTER COLUMN "issuer" SET NOT NULL;
--> statement-breakpoint
CREATE UNIQUE INDEX "account_issuer_account_id_unique"
ON "account" ("issuer", "account_id");
