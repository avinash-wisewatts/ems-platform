/**
 * Alerts (ADR-024) -- replaces the MVP-7 Energy Attention alerts entirely.
 *
 * Three views for the selected site, chosen with ?tab=:
 *   active  -- Active Alerts (Name, Asset, Status, Acknowledge)
 *   rules   -- Create Alert: the site's rules and Create New Alert
 *   history -- Resolved/Ended history (last 90 days)
 *
 * Controls follow the session's permissions (UX only; the server enforces
 * them): alert.configure -> create / edit / enable-disable / delete rules;
 * alert.acknowledge -> Acknowledge. Everyone with site access can view.
 * Times are in the site's timezone. Nothing is sent by email or WhatsApp.
 */

import { useSearchParams } from "react-router-dom";
import { useSession } from "../../auth/SessionProvider";
import { hasPermission } from "../../auth/permissions";
import { useTenant } from "../../tenant/TenantProvider";
import { EmptyState } from "../../components/states/EmptyState";
import { AlertList } from "./AlertLists";
import { AlertRules } from "./AlertRules";

type Tab = "active" | "rules" | "history";

const TABS: { key: Tab; label: string }[] = [
  { key: "active", label: "Active Alerts" },
  { key: "rules", label: "Create Alert" },
  { key: "history", label: "History" },
];

export function AlertsArea() {
  const { selectedSite } = useTenant();
  const { user } = useSession();
  const [params, setParams] = useSearchParams();
  const requested = params.get("tab");
  const tab: Tab = requested === "rules" || requested === "history" ? requested : "active";

  if (!selectedSite) {
    return <EmptyState title="Select a site to view alerts" />;
  }

  const canConfigure = hasPermission(user, "alert.configure");
  const canAcknowledge = hasPermission(user, "alert.acknowledge");
  const timeZone = selectedSite.timezone;

  return (
    <div className="page alerts-page" data-testid="alerts-area">
      <h1>Alerts</h1>
      <div role="tablist" aria-label="Alerts" className="alerts-tabs">
        {TABS.map((t) => (
          <button
            key={t.key}
            type="button"
            role="tab"
            aria-selected={tab === t.key}
            className={`alerts-tab${tab === t.key ? " alerts-tab--active" : ""}`}
            onClick={() => setParams(t.key === "active" ? {} : { tab: t.key })}
            data-testid={`alerts-tab-${t.key}`}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div role="tabpanel">
        {tab === "active" ? (
          <AlertList
            key={`active-${selectedSite.site_id}`}
            mode="active"
            siteId={selectedSite.site_id}
            timeZone={timeZone}
            canAcknowledge={canAcknowledge}
          />
        ) : null}
        {tab === "rules" ? (
          <AlertRules key={selectedSite.site_id} siteId={selectedSite.site_id} timeZone={timeZone} canConfigure={canConfigure} />
        ) : null}
        {tab === "history" ? (
          <AlertList
            key={`history-${selectedSite.site_id}`}
            mode="history"
            siteId={selectedSite.site_id}
            timeZone={timeZone}
            canAcknowledge={false}
          />
        ) : null}
      </div>
    </div>
  );
}
