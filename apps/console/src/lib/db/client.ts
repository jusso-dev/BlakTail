import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";

function databaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      "DATABASE_URL is required. Use an onshore Postgres instance only.",
    );
  }
  return url;
}

const globalForDb = globalThis as unknown as {
  blaktailSql?: ReturnType<typeof postgres>;
};

function sqlClient() {
  if (!globalForDb.blaktailSql) {
    globalForDb.blaktailSql = postgres(databaseUrl(), {
      max: 10,
      prepare: false,
    });
  }
  return globalForDb.blaktailSql;
}

export function db() {
  return drizzle(sqlClient(), { schema });
}
