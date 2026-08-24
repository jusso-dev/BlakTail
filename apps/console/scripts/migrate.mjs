#!/usr/bin/env bun

import { SQL } from "bun";
import { fileURLToPath } from "node:url";
import { drizzle } from "drizzle-orm/bun-sql";
import { migrate } from "drizzle-orm/bun-sql/migrator";

const databaseUrl = process.env.DATABASE_URL?.trim();
if (!databaseUrl) {
  throw new Error(
    "DATABASE_URL is required. Use an onshore Postgres instance only.",
  );
}

const sql = new SQL(databaseUrl, { max: 1, prepare: false });
try {
  await migrate(drizzle(sql), {
    migrationsFolder: fileURLToPath(new URL("../drizzle", import.meta.url)),
  });
} finally {
  await sql.close({ timeout: 5 });
}
