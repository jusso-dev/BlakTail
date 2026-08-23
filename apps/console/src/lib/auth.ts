import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { nextCookies } from "better-auth/next-js";
import { db } from "./db/client";
import * as schema from "./db/schema";

const betterAuthSecret = process.env.BETTER_AUTH_SECRET;
if (!betterAuthSecret || Buffer.byteLength(betterAuthSecret) < 32) {
  throw new Error("BETTER_AUTH_SECRET must be at least 32 bytes.");
}

export const auth = betterAuth({
  appName: "BlakTail",
  baseURL: process.env.BETTER_AUTH_URL ?? "http://localhost:3000",
  secret: betterAuthSecret,
  database: drizzleAdapter(db(), {
    provider: "pg",
    schema: {
      user: schema.user,
      session: schema.session,
      account: schema.account,
      verification: schema.verification,
    },
  }),
  emailAndPassword: {
    enabled: true,
    minPasswordLength: 10,
  },
  session: {
    expiresIn: 60 * 60 * 24 * 7,
    updateAge: 60 * 60 * 24,
  },
  trustedOrigins: (
    process.env.BETTER_AUTH_TRUSTED_ORIGINS ??
    process.env.BETTER_AUTH_URL ??
    "http://localhost:3000"
  )
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean),
  plugins: [nextCookies()],
});

export type Session = typeof auth.$Infer.Session;
