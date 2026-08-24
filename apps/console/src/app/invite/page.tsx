import type { Metadata } from "next";
import { InvitationAcceptForm } from "@/components/invitation-accept-form";

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
  return <InvitationAcceptForm token={token} />;
}
