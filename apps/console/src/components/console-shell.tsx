import Link from "next/link";
import { roleLabel } from "@/lib/roles";
import type { ConsoleContext } from "@/lib/session";
import { OrganisationSwitcher } from "./organisation-switcher";

const links = [
  { href: "/devices", label: "All networks" },
  { href: "/join-keys", label: "Join keys" },
  { href: "/acls", label: "ACL rules" },
  { href: "/audit", label: "Audit log" },
  { href: "/status", label: "Status" },
  { href: "/settings", label: "Settings" },
] as const;

export function ConsoleShell({
  ctx,
  current,
  children,
}: {
  ctx: ConsoleContext;
  current: (typeof links)[number]["href"];
  children: React.ReactNode;
}) {
  return (
    <div className="shell">
      <aside className="nav">
        <Link className="brand" href="/devices">
          BlakTail
        </Link>
        <OrganisationSwitcher
          organisations={ctx.organisations}
          activeOrganisationId={ctx.organisationId}
        />
        <nav aria-label="Console">
          {links.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              aria-current={current === link.href ? "page" : undefined}
            >
              {link.label}
            </Link>
          ))}
        </nav>
        <div className="muted">
          <div>
            {ctx.name} · {roleLabel(ctx.role)}
          </div>
          <div>
            <Link href="/privacy">Privacy and data handling</Link>
          </div>
        </div>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
