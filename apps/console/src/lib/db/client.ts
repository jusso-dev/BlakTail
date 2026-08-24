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
  blaktailRawSql?: ReturnType<typeof postgres>;
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

export function rawSqlClient() {
  if (!globalForDb.blaktailRawSql) {
    globalForDb.blaktailRawSql = postgres(databaseUrl(), {
      max: 5,
      prepare: false,
    });
  }
  return globalForDb.blaktailRawSql;
}

export function db() {
  return drizzle(sqlClient(), { schema });
}
