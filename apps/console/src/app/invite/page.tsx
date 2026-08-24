import type { Metadata } from "next";
import { headers } from "next/headers";
import { InvitationAcceptForm } from "@/components/invitation-accept-form";
import { auth } from "@/lib/auth";

export const metadata: Metadata = {
  title: "Accept invitation · BlakTail",
  robots: { index: false, follow: false },
};

export default async function InvitePage({
  searchParams,
}: {
  searchParams: Promise<{ token?: string | string[] }>;
}) {
  const value = (await searchParams).token;
  const token = typeof value === "string" && value.startsWith("bti_") ? value : "";
  const session = await auth.api.getSession({ headers: await headers() });
  return (
    <InvitationAcceptForm
      token={token}
      signedInEmail={session?.user.email ?? null}
    />
  );
}
