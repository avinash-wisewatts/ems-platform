import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useSession } from "../auth/SessionProvider";
import { useTenant } from "../tenant/TenantProvider";
import { TimeRangePicker } from "../components/TimeRangePicker";
import type { TimeRangePreset } from "../time/ranges";

/**
 * The empty foundation home. It demonstrates every foundation piece wired
 * together -- identity, tenant context, the shared time-range control -- with
 * NO feature dashboard. Later phases mount real screens in the feature-route
 * namespace without reworking anything here.
 */
export function ShellHome() {
  const { user } = useSession();
  const { selectedSite, sites } = useTenant();
  const navigate = useNavigate();
  const [range, setRange] = useState<TimeRangePreset>("7D");

  return (
    <div className="page page--home" data-testid="page-home">
      <h1>Home</h1>
      <p>
        Signed in as <strong>{user?.display_name ?? user?.username}</strong> ({user?.role_code},{" "}
        {user?.access_scope_mode}).
      </p>

      <section className="home-context">
        <h2>Context</h2>
        {selectedSite ? (
          <p data-testid="home-selected-site">
            {selectedSite.site_name} — {selectedSite.site_code}
            {sites.length > 1 ? (
              <button type="button" onClick={() => navigate("/select")} style={{ marginLeft: 12 }}>
                Change
              </button>
            ) : null}
          </p>
        ) : (
          <p>
            <button type="button" onClick={() => navigate("/select")}>
              Select a site
            </button>
          </p>
        )}
      </section>

      <section className="home-time">
        <h2>Time range</h2>
        <TimeRangePicker value={range} onChange={setRange} />
        <p className="hint">
          Feature screens (later phases) translate this selection into analytics API requests.
        </p>
      </section>

      <section className="home-empty">
        <p className="hint">
          This is the application shell. Feature dashboards are delivered in later phases.
        </p>
      </section>
    </div>
  );
}
