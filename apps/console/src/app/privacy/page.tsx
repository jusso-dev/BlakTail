import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy and data handling · BlakTail",
  description: "What a self-hosted BlakTail deployment processes and retains.",
};

export default function PrivacyPage() {
  return (
    <main className="policy-page">
      <article className="panel stack">
        <div>
          <Link className="brand" href="/">
            BlakTail
          </Link>
          <h1>Privacy and data handling</h1>
          <p className="lead">Software statement · 23 August 2026</p>
        </div>

        <p>
          BlakTail is self-hosted. The organisation operating this console
          controls its deployment and is responsible for its privacy contact,
          hosting, retention, backups, support access, and legal obligations.
        </p>

        <section className="stack">
          <h2>What this deployment processes</h2>
          <ul>
            <li>
              Account name and email, authentication records, sessions, IP
              address and user agent, organisation membership, and role.
            </li>
            <li>
              Device names and identifiers, WireGuard public keys, tailnet
              addresses, endpoints, routes, ACLs, credential hashes and expiry,
              and administrator audit events.
            </li>
            <li>
              Short-lived relay registrations containing a node identifier and
              public socket address. Relays forward opaque WireGuard ciphertext;
              they cannot decrypt tunnel contents.
            </li>
          </ul>
        </section>

        <section className="stack">
          <h2>What BlakTail does not add</h2>
          <p>
            No advertising, third-party analytics, tracking pixels, remote
            fonts, or public-DNS forwarding. The console uses authentication
            cookies. Runtime logs must never contain private WireGuard keys, raw
            join keys, node tokens, passwords, or tunnel payloads.
          </p>
        </section>

        <section className="stack">
          <h2>Location and retention</h2>
          <p>
            BlakTail is designed for Australian hosting, but the operator must
            verify the actual locations of databases, logs, backups, DNS, and
            support systems. Revoked nodes, expired join-key records, and audit
            events currently have no automatic deletion schedule. Relay
            registrations expire after 120 seconds idle.
          </p>
        </section>

        <section className="stack">
          <h2>Your choices and contact</h2>
          <p>
            Contact the organisation that gave you access to this console to
            request access, correction, export, deletion, or to make a privacy
            complaint. That operator must publish its real legal name, contact,
            retention periods, and subprocessors before public launch.
          </p>
        </section>

        <p className="muted">
          Maintainers and operators: see the complete{" "}
          <a href="https://github.com/jusso-dev/BlakTail/blob/main/docs/privacy.md">
            deployment data-handling statement
          </a>
          .
        </p>
      </article>
    </main>
  );
}
