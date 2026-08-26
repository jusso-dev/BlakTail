import type { ReactNode } from "react";
import Link from "next/link";
import { roleLabel } from "@/lib/roles";
import type { ConsoleContext, PersonSessionContext } from "@/lib/session";
import { OrganisationSwitcher } from "./organisation-switcher";
import { PathMotif } from "./path-motif";
import { Wordmark } from "./wordmark";

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
  children: ReactNode;
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
        <div className="nav-head">
          <Wordmark />
          <input
            id="console-nav"
            className="nav-toggle"
            type="checkbox"
          />
          <label className="nav-toggle-label" htmlFor="console-nav">
            Menu
          </label>
          <div className="nav-body">
            <PathMotif className="path-motif nav-motif" />
            <OrganisationSwitcher
              organisations={ctx.organisations}
              activeOrganisationId={
                selectedId ?? ctx.organisations[0]!.organisationId
              }
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
            <div className="account-block">
              <div>
                {ctx.name}
                {selected ? ` · ${roleLabel(selected.role)}` : ""}
              </div>
              {selected ? (
                <div>
                  <span className="badge network">{selected.organisationName}</span>
                </div>
              ) : null}
              <div>
                <Link href="/privacy">Privacy and data handling</Link>
              </div>
            </div>
            <p className="region-mark">
              <span className="region-dot" aria-hidden="true" />
              <strong>Onshore</strong>
              <span>Sydney, Australia · AU · ap-southeast-2</span>
            </p>
          </div>
        </div>
      </aside>
      <main className="main">
        <div className="main-motif" aria-hidden="true">
          <PathMotif />
        </div>
        {children}
      </main>
    </div>
  );
}
