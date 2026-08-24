import { SQL } from "bun";
import { drizzle } from "drizzle-orm/bun-sql";
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
  blaktailSql?: SQL;
  blaktailRawSql?: SQL;
};

function sqlClient() {
  if (!globalForDb.blaktailSql) {
    globalForDb.blaktailSql = new SQL(databaseUrl(), {
      max: 10,
      prepare: false,
    });
  }
  return globalForDb.blaktailSql;
}

export function rawSqlClient() {
  if (!globalForDb.blaktailRawSql) {
    globalForDb.blaktailRawSql = new SQL(databaseUrl(), {
      max: 5,
      prepare: false,
    });
  }
  return globalForDb.blaktailRawSql;
}

export function db() {
  return drizzle(sqlClient(), { schema });
}
