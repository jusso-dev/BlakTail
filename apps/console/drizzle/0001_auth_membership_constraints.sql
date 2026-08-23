ALTER TABLE "membership"
  ADD CONSTRAINT "membership_role_check"
  CHECK ("role" in ('owner', 'admin', 'member'));

CREATE UNIQUE INDEX "membership_org_user_unique" ON "membership" ("organisation_id", "user_id");
