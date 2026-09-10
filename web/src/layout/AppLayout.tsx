import type { ReactNode } from "react";
import { NavLink } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { useTenant } from "../tenant/TenantProvider";
import { logout } from "../api/client";
import { PRIMARY_NAV, SECONDARY_NAV, visibleNav } from "./navigation";

/**
 * The shell chrome: header (identity, org/site, logout) + permission-gated
 * left navigation + a content outlet. Navigation gating is UX only.
 */
export function AppLayout({ children }: { children: ReactNode }) {
  const { user } = useSession();
  const { selectedSite, sites } = useTenant();
  const permissions = user?.permissions ?? [];

  const primary = visibleNav(PRIMARY_NAV, permissions);
  const secondary = visibleNav(SECONDARY_NAV, permissions);

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
          <ul>
            {primary.map((item) => (
              <li key={item.key}>
                <NavLink to={item.to} data-testid={`nav-${item.key}`}>
                  {item.label}
                </NavLink>
              </li>
            ))}
          </ul>
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
