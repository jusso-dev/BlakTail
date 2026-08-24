import "server-only";

import { eq } from "drizzle-orm";
import { db } from "./db/client";
import { bootstrapState } from "./db/schema";

export async function requireBootstrapLocked(): Promise<void> {
  const [state] = await db()
    .select({ status: bootstrapState.status })
    .from(bootstrapState)
    .where(eq(bootstrapState.id, "primary"))
    .limit(1);
  if (state?.status !== "locked") {
    throw new Error(
      "Console ownership is not active. Run the on-host bootstrap status command.",
    );
  }
}
