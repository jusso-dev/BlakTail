import Link from "next/link";
import { roleLabel } from "@/lib/roles";
import type { ConsoleContext, PersonSessionContext } from "@/lib/session";
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
  ctx: ConsoleContext | PersonSessionContext;
  current: (typeof links)[number]["href"];
  children: React.ReactNode;
}) {
  const selectedId =
    "organisationId" in ctx
      ? ctx.organisationId
      : ctx.organisations[0]?.organisationId;
  const selected = ctx.organisations.find(
    (organisation) => organisation.organisationId === selectedId,
  );

  return (
    <div className="shell">
      <aside className="nav">
        <Link className="brand" href="/devices">
          BlakTail
        </Link>
        <OrganisationSwitcher
          organisations={ctx.organisations}
          activeOrganisationId={selectedId ?? ctx.organisations[0]!.organisationId}
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
            {ctx.name}
            {selected ? ` · ${roleLabel(selected.role)}` : ""}
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
