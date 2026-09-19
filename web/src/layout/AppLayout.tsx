import { useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { NavLink, useLocation } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { useTenant } from "../tenant/TenantProvider";
import { logout } from "../api/client";
import { useActiveAlertCount } from "../alerts/useActiveAlertCount";
import {
  NAV_GROUP_LABELS,
  PRIMARY_NAV,
  SECONDARY_NAV,
  SHELL_PRIMARY_NAV,
  groupNav,
  visibleNav,
} from "./navigation";
import { NavIcon, type NavIconKey } from "./NavIcon";
import { DATE_TIME_FORMAT } from "../time/format";

/** SHELL_PRIMARY_NAV's "shell-alerts" key exists only to avoid a duplicate
 *  `nav-alerts` test id against the Archive section's own Alerts entry --
 *  it is still the same Alerts icon. */
const SHELL_ICON_KEYS = new Set<string>(["main-dashboard", "asset-view", "analytics", "single-line-diagram", "settings"]);

function shellNavIcon(key: string): NavIconKey {
  if (key === "shell-alerts") return "alerts";
  return SHELL_ICON_KEYS.has(key) ? (key as NavIconKey) : "settings";
}

/**
 * The WiseWatts dashboard redesign shell: header (brand, alerts, identity),
 * a collapsible left sidebar (site search + the new primary navigation + a
 * bottom "Archive" section), and a content outlet. The collapse toggle
 * lives in the sidebar's own header row (above Organization/Site), not the
 * shell's top header.
 *
 * The Archive section renders PRIMARY_NAV/SECONDARY_NAV via the exact same
 * groupNav/visibleNav functions and NavLink markup (same `nav-${key}`
 * test ids, same alert badge) the shell used before this redesign --
 * nothing already shipped is deleted, relabelled, or behaviourally changed;
 * it is only relocated into a labelled, collapsed-by-default section so the
 * new primary nav (Main Dashboard / Asset View / Analytics / Single Line
 * Diagram / Alerts / Settings) doesn't compete with it for attention.
 *
 * Navigation gating is UX only, as before -- the backend remains
 * authoritative for access.
 */

function useNow(intervalMs = 30_000): Date {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const id = window.setInterval(() => setNow(new Date()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  if (parts.length === 1) return parts[0]!.slice(0, 2).toUpperCase();
  return `${parts[0]![0]}${parts[parts.length - 1]![0]}`.toUpperCase();
}

/**
 * logo.svg is the full WiseWatts lockup (mark + "WISEWATTS SOLUTIONS"
 * wordmark baked into the SVG as text) -- it is the entire brand mark on
 * its own, so nothing else renders an extra "WISEWATTS" label next to it.
 * The fallback (logo file missing/unreadable) is the only place that still
 * needs its own text, since the fallback glyph alone carries no name.
 */
function BrandMark() {
  const [imgFailed, setImgFailed] = useState(false);
  if (imgFailed) {
    return (
      <>
        <span className="app-shell__brand-mark app-shell__brand-mark--fallback" aria-hidden="true">
          W
        </span>
        <span>WISEWATTS</span>
      </>
    );
  }
  return (
    // logo.svg's wordmark is filled navy (#05245b) -- identical to this
    // header's own background -- so it needs a light backing chip to stay
    // visible here, even though the file is otherwise used as-is.
    <span className="app-shell__brand-mark-chip">
      <img
        src={`${import.meta.env.BASE_URL}branding/logo.svg`}
        alt="WiseWatts"
        className="app-shell__brand-mark app-shell__brand-mark--logo"
        onError={() => setImgFailed(true)}
      />
    </span>
  );
}

function ArchiveNav({
  permissions,
  activeAlertCount,
}: {
  permissions: readonly string[];
  /** Shared with the header bell and the new primary nav's Alerts badge --
   *  fetched once in AppLayout, not re-fetched here. */
  activeAlertCount: number | null;
}) {
  const primary = visibleNav(PRIMARY_NAV, permissions);
  const secondary = visibleNav(SECONDARY_NAV, permissions);
  const primarySections = groupNav(primary);

  return (
    <details className="app-shell__archive" data-testid="nav-archive">
      <summary>
        <NavIcon icon="archive" />
        <span>Archive</span>
      </summary>
      <p className="app-shell__archive-hint">
        Earlier screens, kept for reference during the redesign -- nothing here was removed.
      </p>
      <nav aria-label="Archive">
        {primarySections.map((section, index) => (
          <ul key={section.group ?? `ungrouped-${index}`} className="app-shell__nav-section">
            {section.group ? (
              <li className="app-shell__nav-section-label">{NAV_GROUP_LABELS[section.group]}</li>
            ) : null}
            {section.items.map((item) => (
              <li key={item.key}>
                <NavLink to={item.to} data-testid={`nav-${item.key}`}>
                  {item.label}
                  {item.key === "alerts" && activeAlertCount !== null ? (
                    <span className="app-shell__nav-badge" data-testid="nav-alerts-badge">
                      {activeAlertCount > 0 ? activeAlertCount : ""}
                    </span>
                  ) : null}
                </NavLink>
              </li>
            ))}
          </ul>
        ))}
        {secondary.length > 0 ? (
          <ul className="app-shell__nav-secondary">
            {secondary.map((item) => (
              <li key={item.key}>
                <NavLink to={item.to} data-testid={`nav-${item.key}`}>
                  {item.label}
                </NavLink>
              </li>
            ))}
          </ul>
        ) : null}
      </nav>
    </details>
  );
}

/**
 * The organization the Site dropdown below is currently scoped to: the
 * selected site's own organization, or -- before any site is picked -- the
 * first (alphabetically, per TenantProvider's own sort) accessible
 * organization. Shared by OrgSwitcher and SiteSwitcher so both agree on
 * "current org" without a second piece of selection state -- org selection
 * always resolves through selecting a site.
 */
function useSelectedOrgId(): string | null {
  const { selectedSite, organizations } = useTenant();
  return selectedSite?.organization_id ?? organizations[0]?.organization_id ?? null;
}

/** organization_name is a required field on the wire contract, but must
 *  never render as blank/"undefined" if a backend is ever caught mid-rollout
 *  without it (see TenantProvider.tsx's groupByOrganization) -- falls back
 *  to the always-present organization_id so the dropdown/header stay
 *  legible and clickable rather than showing empty-looking entries. */
function orgDisplayName(org: { organization_name: string; organization_id: string }): string {
  return org.organization_name || org.organization_id;
}

/**
 * Organizations the signed-in user has access to. A single-org user never
 * sees a dropdown -- just the org name, since there is nothing to choose
 * (Q: sidebar org selector, WiseWatts dashboard redesign). A multi-org user
 * gets the same open/closed listbox pattern as SiteSwitcher, minus the
 * search field (org counts are small). Picking an org auto-selects that
 * org's first site, since the shell always needs a selected site to render
 * the dashboard and there is no standalone "org, no site" state.
 */
function OrgSwitcher() {
  const { organizations, selectSite } = useTenant();
  const selectedOrgId = useSelectedOrgId();
  const selectedOrg = organizations.find((o) => o.organization_id === selectedOrgId) ?? null;
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, []);

  if (organizations.length <= 1) {
    return (
      <div className="org-switcher org-switcher--static" data-testid="org-switcher-static">
        {selectedOrg ? orgDisplayName(selectedOrg) : "—"}
      </div>
    );
  }

  return (
    <div className="org-switcher" ref={ref}>
      <button
        type="button"
        className="org-switcher__trigger"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        data-testid="org-switcher-trigger"
      >
        <span className="org-switcher__trigger-label">
          {selectedOrg ? orgDisplayName(selectedOrg) : "Select an organization"}
        </span>
        <span className="org-switcher__chevron" aria-hidden="true">
          {open ? "▴" : "▾"}
        </span>
      </button>
      {open ? (
        <ul className="org-switcher__list" role="listbox" aria-label="Organizations">
          {organizations.map((org) => {
            const isSelected = org.organization_id === selectedOrgId;
            return (
              <li key={org.organization_id}>
                <button
                  type="button"
                  className={isSelected ? "is-selected" : ""}
                  onClick={() => {
                    if (!isSelected) {
                      const firstSite = org.sites[0];
                      if (firstSite) selectSite(firstSite.site_id);
                    }
                    setOpen(false);
                  }}
                  role="option"
                  aria-selected={isSelected}
                  data-testid={`org-switcher-item-${org.organization_id}`}
                >
                  <span className="org-switcher__item-label">{orgDisplayName(org)}</span>
                  {isSelected ? (
                    <span className="org-switcher__check" aria-hidden="true">
                      ✓
                    </span>
                  ) : null}
                </button>
              </li>
            );
          })}
        </ul>
      ) : null}
    </div>
  );
}

/**
 * Closed by default, showing only the currently selected site. Opening it
 * reveals a search field (auto-focused) and the full site list below,
 * filtered live as the user types; the selected site carries a checkmark
 * in that list so it stays identifiable while browsing/searching. Scoped to
 * OrgSwitcher's current organization -- picking a different org narrows
 * this list rather than leaving it showing every accessible site at once.
 */
function SiteSwitcher() {
  const { selectedSite, sites, selectSite } = useTenant();
  const selectedOrgId = useSelectedOrgId();
  const orgSites = useMemo(
    () => (selectedOrgId ? sites.filter((s) => s.organization_id === selectedOrgId) : sites),
    [sites, selectedOrgId],
  );
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const ref = useRef<HTMLDivElement | null>(null);
  const searchRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, []);

  useEffect(() => {
    if (!open) return;
    setQuery("");
    const id = requestAnimationFrame(() => searchRef.current?.focus());
    return () => cancelAnimationFrame(id);
  }, [open]);

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return orgSites;
    return orgSites.filter((s) => s.site_name.toLowerCase().includes(q) || s.site_code.toLowerCase().includes(q));
  }, [orgSites, query]);

  return (
    <div className="site-switcher" ref={ref}>
      <button
        type="button"
        className="site-switcher__trigger"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="listbox"
        aria-expanded={open}
        data-testid="site-switcher-trigger"
      >
        <span className="site-switcher__trigger-label">{selectedSite ? selectedSite.site_name : "Select a site"}</span>
        <span className="site-switcher__chevron" aria-hidden="true">
          {open ? "▴" : "▾"}
        </span>
      </button>
      {open ? (
        <div className="site-switcher__panel">
          <label className="visually-hidden" htmlFor="site-switcher-search">
            Search sites
          </label>
          <input
            ref={searchRef}
            id="site-switcher-search"
            type="search"
            placeholder="Search sites…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            data-testid="site-switcher-search"
          />
          <ul className="site-switcher__list" role="listbox" aria-label="Sites">
            {filtered.map((site) => {
              const isSelected = site.site_id === selectedSite?.site_id;
              return (
                <li key={site.site_id}>
                  <button
                    type="button"
                    className={isSelected ? "is-selected" : ""}
                    onClick={() => {
                      selectSite(site.site_id);
                      setOpen(false);
                    }}
                    role="option"
                    aria-selected={isSelected}
                    data-testid={`site-switcher-item-${site.site_id}`}
                  >
                    <span className="site-switcher__item-label">{site.site_name}</span>
                    {isSelected ? (
                      <span className="site-switcher__check" aria-hidden="true">
                        ✓
                      </span>
                    ) : null}
                  </button>
                </li>
              );
            })}
            {filtered.length === 0 ? <li className="site-switcher__empty">No sites match "{query}".</li> : null}
          </ul>
        </div>
      ) : null}
    </div>
  );
}

function UserMenu() {
  const { user } = useSession();
  const now = useNow();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    function onClickAway(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener("mousedown", onClickAway);
    return () => document.removeEventListener("mousedown", onClickAway);
  }, []);

  const name = user?.display_name ?? user?.username ?? "";

  return (
    <div className="user-menu" ref={ref}>
      <button
        type="button"
        className="user-menu__trigger"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        data-testid="user-menu-trigger"
      >
        <span className="user-menu__avatar" aria-hidden="true">
          {initials(name)}
        </span>
        <span className="user-menu__identity">
          <span data-testid="identity-name">{name}</span>
          <span className="user-menu__datetime">{DATE_TIME_FORMAT.format(now)}</span>
        </span>
        <span className="user-menu__chevron" aria-hidden="true">
          ▾
        </span>
      </button>
      {open ? (
        <div className="user-menu__panel" role="menu">
          <p className="user-menu__role" data-testid="identity-role">
            {user?.role_code ?? ""}
          </p>
          <button type="button" onClick={() => void logout()} data-testid="logout">
            Sign out
          </button>
        </div>
      ) : null}
    </div>
  );
}

export function AppLayout({ children }: { children: ReactNode }) {
  const { user } = useSession();
  const { selectedSite, sites } = useTenant();
  const location = useLocation();
  const permissions = user?.permissions ?? [];
  const activeAlertCount = useActiveAlertCount(selectedSite?.site_id ?? null);

  const [collapsed, setCollapsed] = useState(false);
  const shellNav = visibleNav(SHELL_PRIMARY_NAV, permissions);

  return (
    <div
      className={`app-shell${collapsed ? " app-shell--collapsed" : ""}`}
      data-testid="app-shell"
    >
      <header className="app-shell__header">
        <div className="app-shell__brand">
          <BrandMark />
        </div>
        <span className="app-shell__context" data-testid="context-site">
          {selectedSite
            ? `${orgDisplayName(selectedSite)}: ${selectedSite.site_name}`
            : sites.length > 1
              ? "No site selected"
              : "—"}
        </span>
        <div className="app-shell__header-actions">
          <NavLink to="/features/alerts" className="app-shell__alerts-bell" aria-label="Alerts" data-testid="header-alerts-bell">
            <NavIcon icon="alerts" />
            {activeAlertCount !== null && activeAlertCount > 0 ? (
              <span className="app-shell__alerts-count" data-testid="header-alerts-count">
                {activeAlertCount}
              </span>
            ) : null}
          </NavLink>
          <UserMenu />
        </div>
      </header>

      <div className="app-shell__body">
        <aside className="app-shell__sidebar">
          <div className="app-shell__site-panel">
            <div className="app-shell__site-panel-header">
              <button
                type="button"
                className="app-shell__collapse-toggle"
                onClick={() => setCollapsed((c) => !c)}
                aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}
                aria-pressed={collapsed}
                data-testid="sidebar-collapse-toggle"
              >
                ☰
              </button>
            </div>
            <div className="app-shell__field">
              <span className="app-shell__field-label">Organization</span>
              <OrgSwitcher />
            </div>
            <div className="app-shell__field">
              <span className="app-shell__field-label">Site</span>
              <SiteSwitcher />
            </div>
          </div>

          <nav className="app-shell__primary-nav" aria-label="Primary">
            <ul>
              {shellNav.map((item) => (
                <li key={item.key}>
                  <NavLink to={item.to} data-testid={`shell-nav-${item.key}`}>
                    <NavIcon icon={shellNavIcon(item.key)} />
                    <span className="app-shell__nav-label">{item.label}</span>
                    {item.key === "shell-alerts" && activeAlertCount !== null && activeAlertCount > 0 ? (
                      <span className="app-shell__nav-badge" data-testid="shell-nav-alerts-badge">
                        {activeAlertCount}
                      </span>
                    ) : null}
                  </NavLink>
                </li>
              ))}
            </ul>
          </nav>

          <div className="app-shell__archive-wrapper">
            <ArchiveNav permissions={permissions} activeAlertCount={activeAlertCount} />
          </div>
        </aside>

        <main className="app-shell__content" key={location.pathname}>
          {children}
        </main>
      </div>
    </div>
  );
}
