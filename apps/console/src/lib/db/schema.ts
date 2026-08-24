import { relations, sql } from "drizzle-orm";
import {
  bigint,
  boolean,
  check,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
} from "drizzle-orm/pg-core";

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified").notNull().default(false),
  image: text("image"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at").notNull(),
  token: text("token").notNull().unique(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
});

export const account = pgTable(
  "account",
  {
    id: text("id").primaryKey(),
    issuer: text("issuer").notNull(),
    accountId: text("account_id").notNull(),
    providerId: text("provider_id").notNull(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    accessToken: text("access_token"),
    refreshToken: text("refresh_token"),
    idToken: text("id_token"),
    accessTokenExpiresAt: timestamp("access_token_expires_at"),
    refreshTokenExpiresAt: timestamp("refresh_token_expires_at"),
    scope: text("scope"),
    password: text("password"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    updatedAt: timestamp("updated_at").notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("account_issuer_account_id_unique").on(
      table.issuer,
      table.accountId,
    ),
  ],
);

export const verification = pgTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: timestamp("expires_at").notNull(),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow(),
});

export const rateLimit = pgTable(
  "rate_limit",
  {
    id: text("id").primaryKey(),
    key: text("key").notNull(),
    count: integer("count").notNull(),
    lastRequest: bigint("last_request", { mode: "number" }).notNull(),
  },
  (table) => [uniqueIndex("rate_limit_key_unique").on(table.key)],
);

/** Organisation membership mirrored to the Rust coordinator. */
export const organisation = pgTable("organisation", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  /** Coordinator org UUID. Source of truth for tailnet authz lives on the coord. */
  coordOrgId: text("coord_org_id").notNull().unique(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
});

export const membership = pgTable(
  "membership",
  {
    id: text("id").primaryKey(),
    organisationId: text("organisation_id")
      .notNull()
      .references(() => organisation.id, { onDelete: "cascade" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    role: text("role").notNull().$type<"owner" | "admin" | "member">(),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("membership_org_user_unique").on(
      table.organisationId,
      table.userId,
    ),
    check(
      "membership_role_check",
      sql.raw("\"role\" in ('owner', 'admin', 'member')"),
    ),
  ],
);

export const bootstrapState = pgTable(
  "bootstrap_state",
  {
    id: text("id").primaryKey(),
    status: text("status")
      .notNull()
      .$type<"uninitialised" | "claimable" | "provisioning" | "locked">(),
    tokenHash: text("token_hash"),
    tokenExpiresAt: timestamp("token_expires_at", { withTimezone: true }),
    provisioningUserId: text("provisioning_user_id"),
    provisioningOrganisationId: text("provisioning_organisation_id"),
    provisioningCoordOrgId: text("provisioning_coord_org_id"),
    provisioningEmail: text("provisioning_email"),
    provisioningOwnerName: text("provisioning_owner_name"),
    provisioningOrganisationName: text("provisioning_organisation_name"),
    lockedAt: timestamp("locked_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  () => [
    check("bootstrap_state_singleton_check", sql.raw("\"id\" = 'primary'")),
    check(
      "bootstrap_state_status_check",
      sql.raw(
        "\"status\" in ('uninitialised', 'claimable', 'provisioning', 'locked')",
      ),
    ),
  ],
);

export const invitation = pgTable(
  "invitation",
  {
    id: text("id").primaryKey(),
    organisationId: text("organisation_id")
      .notNull()
      .references(() => organisation.id, { onDelete: "cascade" }),
    email: text("email").notNull(),
    role: text("role").notNull().$type<"admin" | "member">(),
    tokenHash: text("token_hash").notNull().unique(),
    inviterUserId: text("inviter_user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    status: text("status")
      .notNull()
      .$type<"pending" | "accepted" | "revoked">()
      .default("pending"),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    acceptedAt: timestamp("accepted_at", { withTimezone: true }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true })
      .notNull()
      .defaultNow(),
  },
  (table) => [
    uniqueIndex("invitation_pending_org_email_unique")
      .on(table.organisationId, table.email)
      .where(sql.raw("\"status\" = 'pending'")),
    check("invitation_role_check", sql.raw("\"role\" in ('admin', 'member')")),
    check(
      "invitation_status_check",
      sql.raw("\"status\" in ('pending', 'accepted', 'revoked')"),
    ),
  ],
);

export const consoleAuditEvent = pgTable("console_audit_event", {
  id: text("id").primaryKey(),
  organisationId: text("organisation_id").references(() => organisation.id, {
    onDelete: "cascade",
  }),
  actorUserId: text("actor_user_id"),
  actorEmail: text("actor_email").notNull().default(""),
  actorRole: text("actor_role").notNull(),
  source: text("source").notNull(),
  action: text("action").notNull(),
  result: text("result").notNull(),
  targetType: text("target_type").notNull(),
  targetId: text("target_id"),
  details: jsonb("details").notNull().default({}),
  createdAt: timestamp("created_at", { withTimezone: true })
    .notNull()
    .defaultNow(),
});

export const userRelations = relations(user, ({ many }) => ({
  sessions: many(session),
  accounts: many(account),
  memberships: many(membership),
}));

export const organisationRelations = relations(organisation, ({ many }) => ({
  memberships: many(membership),
}));

export const membershipRelations = relations(membership, ({ one }) => ({
  organisation: one(organisation, {
    fields: [membership.organisationId],
    references: [organisation.id],
  }),
  user: one(user, {
    fields: [membership.userId],
    references: [user.id],
  }),
}));
