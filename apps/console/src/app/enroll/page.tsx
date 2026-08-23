import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { ConsoleShell } from "@/components/console-shell";
import { EnrollmentApproval } from "@/components/enrollment-approval";
import { auth } from "@/lib/auth";
import { getDeviceAuthorization } from "@/lib/coord";
import { requireConsoleContext } from "@/lib/session";

function deviceCode(value: string | string[] | undefined): string | null {
  const raw = Array.isArray(value) ? value[0] : value;
  const normalized = (raw ?? "")
    .toUpperCase()
    .replaceAll(/[^A-Z0-9]/g, "");
  if (!/^[A-Z0-9]{8}$/.test(normalized)) return null;
  return `${normalized.slice(0, 4)}-${normalized.slice(4)}`;
}

export default async function EnrollPage({
  searchParams,
}: {
  searchParams: Promise<{ code?: string | string[] }>;
}) {
  const code = deviceCode((await searchParams).code);
  if (!code) {
    return (
      <main className="sign-in">
        <div className="sign-in-card panel">
          <h1>Invalid device link</h1>
          <p className="error">
            This enrollment link has no valid eight-character device code. Run
            <span className="mono"> blaktaild up </span>
            again and open the new link.
          </p>
        </div>
      </main>
    );
  }

  const session = await auth.api.getSession({ headers: await headers() });
  if (!session) {
    const next = `/enroll?code=${encodeURIComponent(code)}`;
    redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  }
  const ctx = await requireConsoleContext();

  let request;
  let loadError: string | null = null;
  try {
    request = await getDeviceAuthorization(ctx, code);
  } catch (error) {
    loadError =
      error instanceof Error
        ? error.message
        : "Could not load this device authorization.";
  }
  if (!request) {
    return (
      <ConsoleShell ctx={ctx} current="/devices">
        <div className="panel stack">
          <h1>Enrollment unavailable</h1>
          <p className="error" role="alert">
            {loadError}
          </p>
          <p className="muted">
            Run <span className="mono">blaktaild up</span> again to create a
            fresh link.
          </p>
        </div>
      </ConsoleShell>
    );
  }

  return (
    <ConsoleShell ctx={ctx} current="/devices">
      <div className="stack">
        <div>
          <h1>Approve device</h1>
          <p className="lead">
            Confirm that this is the device waiting in your terminal.
          </p>
        </div>
        <section className="panel stack" aria-labelledby="device-heading">
          <h2 id="device-heading">{request.name}</h2>
          <dl className="details">
            <div>
              <dt>Device code</dt>
              <dd className="mono">{code}</dd>
            </div>
            <div>
              <dt>WireGuard key fingerprint</dt>
              <dd className="mono">{request.public_key_fingerprint}</dd>
            </div>
            <div>
              <dt>Expires</dt>
              <dd>{new Date(request.expires_at * 1000).toISOString()}</dd>
            </div>
            <div>
              <dt>Organisation</dt>
              <dd>{ctx.organisationName}</dd>
            </div>
          </dl>
          <EnrollmentApproval
            code={code}
            role={ctx.role}
            alreadyApproved={request.approved}
          />
        </section>
      </div>
    </ConsoleShell>
  );
}
