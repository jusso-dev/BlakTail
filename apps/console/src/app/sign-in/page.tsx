import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { SignInForm } from "@/components/sign-in-form";
import { auth } from "@/lib/auth";

function safeNext(value: string | string[] | undefined): string {
  const path = Array.isArray(value) ? value[0] : value;
  return path?.startsWith("/enroll?code=") ? path : "/devices";
}

export default async function SignInPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string | string[] }>;
}) {
  const nextPath = safeNext((await searchParams).next);
  const session = await auth.api.getSession({
    headers: await headers(),
  });
  if (session) {
    redirect(nextPath);
  }
  return <SignInForm nextPath={nextPath} />;
}
