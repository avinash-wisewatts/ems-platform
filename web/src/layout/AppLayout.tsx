import type { ReactNode } from "react";
import { NavLink } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { useTenant } from "../tenant/TenantProvider";
import { logout } from "../api/client";
import { useActiveAlertCount } from "../alerts/useActiveAlertCount";
import { NAV_GROUP_LABELS, PRIMARY_NAV, SECONDARY_NAV, groupNav, visibleNav } from "./navigation";

/**
 * The shell chrome: header (identity, org/site, logout) + permission-gated
 * left navigation + a content outlet. Navigation gating is UX only.
 *
 * MVP-1 closeout: the primary nav is rendered in IA-labelled sections --
 * "Site" (Energy / Demand / Power Quality, i.e. capabilities of the current
 * site) and "Spaces & Assets" (the Site -> Space -> Asset drill-down) --
 * instead of one flat list, so Energy/Demand/PQ read as site-context
 * capabilities rather than unrelated global destinations. No route changed.
 */
export function AppLayout({ children }: { children: ReactNode }) {
  const { user } = useSession();
  const { selectedSite, sites } = useTenant();
  const permissions = user?.permissions ?? [];
  // MVP-7 (ADR-016 decision 37): visible with no number at zero; no count
  // shown when no site is selected (activeAlertCount === null).
  const activeAlertCount = useActiveAlertCount(selectedSite?.site_id ?? null);

  const primary = visibleNav(PRIMARY_NAV, permissions);
  const secondary = visibleNav(SECONDARY_NAV, permissions);
  const primarySections = groupNav(primary);

  return (
    <div className="app-shell" data-testid="app-shell">
      <header className="app-shell__header">
        <div className="app-shell__brand">
          <span className="app-shell__brand-mark">WW</span>
          <span>WiseWatts EMS</span>
        </div>
        <div className="app-shell__context">
          <span data-testid="context-site">
            {selectedSite
              ? `${selectedSite.site_name} · ${selectedSite.site_code}`
              : sites.length > 1
                ? "No site selected"
                : "—"}
          </span>
        </div>
        <div className="app-shell__identity">
          <span data-testid="identity-name">{user?.display_name ?? user?.username ?? ""}</span>
          <span className="app-shell__role" data-testid="identity-role">
            {user?.role_code ?? ""}
          </span>
          <button type="button" onClick={() => void logout()} data-testid="logout">
            Sign out
          </button>
        </div>
      </header>

      <div className="app-shell__body">
        <nav className="app-shell__nav" aria-label="Primary">
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

        <main className="app-shell__content">{children}</main>
      </div>
    </div>
  );
}
