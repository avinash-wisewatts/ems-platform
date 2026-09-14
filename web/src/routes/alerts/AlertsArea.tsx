/**
 * MVP-7 Basic Alerts (ADR-016/ADR-017). In-product only -- no email/SMS/
 * WhatsApp/sharing, no analytical deep links, no customer-facing severity
 * taxonomy. Active/Resolved/Ended tabs, single-select condition filter,
 * date range (default 90 days; Active can expand beyond it), list + detail.
 *
 * Known scope reductions in this pass (flagged, not silently decided):
 *   - Space/Asset cascading filters are not implemented -- no Space/Asset
 *     Attention condition exists yet (see the Space/Asset reconciliation,
 *     ADR-017), so there is nothing for such a filter to filter by today.
 *   - "Load more" is a button, not scroll-triggered auto-loading (ADR-016
 *     decision 47's substance -- no traditional page-number pagination --
 *     is preserved; the trigger mechanism is simplified).
 *   - The detail panel does not re-fetch a live "latest value" (ADR-016
 *     decision 34) -- only the persisted trigger/resolved values are shown.
 *   - The date-range filter is keyed to triggered time for every tab
 *     (`from`/`to` on GET .../alerts). ADR-016 decision 48 specifies
 *     resolved time for Resolved and ended time for Ended;
 *     analytics.get_portal_site_alerts (migration 239) filters `triggered_at`
 *     unconditionally. Correcting that is a SQL-function change to an
 *     already-applied migration (a new migration, not a frontend change) and
 *     is out of this pass's scope -- flagged for separate authorization.
 */

import { useEffect, useState } from "react";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteAlerts, getAlertDetail } from "../../api/endpoints";
import type { Alert, AlertState } from "../../api/types";
import { MVP3_MATERIALITY_POLICY } from "../../attention/materiality-policy";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

const TABS: AlertState[] = ["ACTIVE", "RESOLVED", "ENDED"];

const TAB_LABELS: Record<AlertState, string> = {
  ACTIVE: "Active",
  RESOLVED: "Resolved",
  ENDED: "Ended",
};

function ninetyDaysAgoIso(): string {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() - 90);
  return d.toISOString();
}

/** yyyy-mm-dd for a date <input>, from a full ISO instant. */
function toDateInputValue(iso: string): string {
  return iso.slice(0, 10);
}

/** Inverse of toDateInputValue -- a date <input>'s value as a UTC-midnight ISO instant. */
function fromDateInputValue(dateValue: string): string {
  return new Date(`${dateValue}T00:00:00.000Z`).toISOString();
}

function formatTimestamp(iso: string): string {
  return new Date(iso).toLocaleString();
}

function conditionLabel(conditionKey: string): string {
  // MVP-7's only condition -- see analytics.evaluate_energy_attention_materiality.
  if (conditionKey.startsWith("ENERGY_ATTENTION:")) {
    return "Energy consumption deviation";
  }
  return conditionKey;
}

/** The exact condition_key analytics.evaluate_energy_attention_materiality
 *  (migration 239) constructs for a site -- single-sourced from the same
 *  MVP3_MATERIALITY_POLICY constant that function's threshold/method mirror,
 *  not a second hardcoded "15". MVP-7 has exactly one condition today (ADR-016
 *  decision 2, Site-level Energy Attention), so this is the Condition/Metric
 *  filter's only real option (ADR-016 decision 48). */
function energyAttentionConditionKey(siteId: string): string {
  const policy = MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION;
  return `ENERGY_ATTENTION:${policy.method}:${policy.thresholdPercent}:SITE:${siteId}`;
}

/** Threshold/reference exactly as EMS currently represents it elsewhere
 *  (web/src/attention/energyAttention.ts's "threshold: ${threshold}%") --
 *  no alert-specific number-formatting system (ADR-016 decision 11). The
 *  per-occurrence deviation percent/typical-reference value are not
 *  persisted on the alert row (only the raw kWh trigger/resolution values
 *  are); this reflects the configured rule, not the specific occurrence. */
function thresholdReferenceLabel(conditionKey: string): string {
  if (conditionKey.startsWith("ENERGY_ATTENTION:")) {
    const policy = MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION;
    return `±${policy.thresholdPercent}% deviation from typical historical consumption`;
  }
  return conditionKey;
}

function AlertStateBadge({ state }: { state: AlertState }) {
  return (
    <span className={`alert-badge alert-badge--${state.toLowerCase()}`} data-testid="alert-state-badge">
      {TAB_LABELS[state]}
    </span>
  );
}

function AlertListItem({ alert, onSelect, selected }: { alert: Alert; onSelect: () => void; selected: boolean }) {
  return (
    <li>
      <button
        type="button"
        className="alert-list-item"
        aria-pressed={selected}
        onClick={onSelect}
        data-testid={`alert-item-${alert.alert_id}`}
      >
        <span className="alert-list-item__condition">{conditionLabel(alert.condition_key)}</span>
        <span className="alert-list-item__time">{formatTimestamp(alert.triggered_at)}</span>
        <AlertStateBadge state={alert.state} />
      </button>
    </li>
  );
}

function AlertDetailPanel({
  alert,
  siteName,
  multiSite,
}: {
  alert: Alert;
  siteName: string;
  multiSite: boolean;
}) {
  return (
    <div className="alert-detail" data-testid="alert-detail">
      <h2>{conditionLabel(alert.condition_key)}</h2>
      <HierarchyCrumb siteName={siteName} multiSite={multiSite} leaf={null} />
      <AlertStateBadge state={alert.state} />
      <dl>
        <dt>Triggered</dt>
        <dd>{formatTimestamp(alert.triggered_at)}</dd>
        <dt>Trigger value</dt>
        <dd>{alert.trigger_value.toFixed(2)} kWh</dd>
        <dt>Threshold/reference</dt>
        <dd>{thresholdReferenceLabel(alert.condition_key)}</dd>
        {alert.state === "RESOLVED" ? (
          <>
            <dt>Resolution value</dt>
            <dd>{alert.resolved_value !== null ? `${alert.resolved_value.toFixed(2)} kWh` : "Data unavailable"}</dd>
            <dt>Resolved</dt>
            <dd>{alert.resolved_at ? formatTimestamp(alert.resolved_at) : "—"}</dd>
          </>
        ) : null}
        {alert.state === "ENDED" ? (
          <>
            <dt>Ended</dt>
            <dd>{alert.ended_at ? formatTimestamp(alert.ended_at) : "—"}</dd>
            <dt>Reason</dt>
            <dd>{alert.ended_reason ?? "—"}</dd>
          </>
        ) : null}
        <dt>Previous occurrences</dt>
        <dd data-testid="alert-recurrence">
          Previous occurrences: {alert.previous_occurrence_count}
          {alert.previous_occurrence_count > 0 && alert.most_recent_previous_occurrence_at
            ? ` · Most recent: ${formatTimestamp(alert.most_recent_previous_occurrence_at)}`
            : null}
        </dd>
      </dl>
    </div>
  );
}

export function AlertsArea() {
  const { selectedSite, sites } = useTenant();
  const [tab, setTab] = useState<AlertState>("ACTIVE");
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [selectedAlertId, setSelectedAlertId] = useState<string | null>(null);
  const [selectedAlert, setSelectedAlert] = useState<Alert | null>(null);
  const [hasMore, setHasMore] = useState(false);
  const [nonce, setNonce] = useState(0);

  // Applied filters (ADR-016 decision 48) -- take effect on "Apply filters";
  // "" conditionKey means no filter (all conditions); toDate "" means no
  // upper bound. fromDate defaults to the 90-day window every tab starts
  // with; "Clear filters" restores exactly these defaults.
  const [conditionKey, setConditionKey] = useState("");
  const [fromDate, setFromDate] = useState(() => toDateInputValue(ninetyDaysAgoIso()));
  const [toDate, setToDate] = useState("");

  // Pending (unapplied) filter inputs -- committed to the applied state
  // above only by "Apply filters", per ADR-016 decision 48.
  const [pendingConditionKey, setPendingConditionKey] = useState("");
  const [pendingFromDate, setPendingFromDate] = useState(fromDate);
  const [pendingToDate, setPendingToDate] = useState("");

  function resetFilters() {
    const defaultFrom = toDateInputValue(ninetyDaysAgoIso());
    setConditionKey("");
    setFromDate(defaultFrom);
    setToDate("");
    setPendingConditionKey("");
    setPendingFromDate(defaultFrom);
    setPendingToDate("");
  }

  function applyFilters() {
    setConditionKey(pendingConditionKey);
    setFromDate(pendingFromDate);
    setToDate(pendingToDate);
  }

  useEffect(() => {
    setSelectedAlertId(null);
    setSelectedAlert(null);
    resetFilters();
    // Switching Active/Resolved/Ended clears filters (ADR-016 decision 48).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tab]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);

    getSiteAlerts(selectedSite.site_id, {
      state: tab,
      condition_key: conditionKey || undefined,
      from: fromDate ? fromDateInputValue(fromDate) : ninetyDaysAgoIso(),
      to: toDate ? fromDateInputValue(toDate) : undefined,
      limit: 50,
    })
      .then((response) => {
        if (!active) return;
        setAlerts(response.alerts);
        setHasMore(response.alerts.length === 50);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setError(err);
        setStatus("error");
      });

    return () => {
      active = false;
    };
  }, [selectedSite, tab, nonce, conditionKey, fromDate, toDate]);

  useEffect(() => {
    if (!selectedAlertId) {
      setSelectedAlert(null);
      return;
    }
    let active = true;
    getAlertDetail(selectedAlertId)
      .then((alert) => {
        if (active) setSelectedAlert(alert);
      })
      .catch(() => {
        if (active) setSelectedAlert(null);
      });
    return () => {
      active = false;
    };
  }, [selectedAlertId]);

  function loadMore() {
    if (!selectedSite || alerts.length === 0) return;
    const last = alerts[alerts.length - 1]!;
    getSiteAlerts(selectedSite.site_id, {
      state: tab,
      condition_key: conditionKey || undefined,
      from: fromDate ? fromDateInputValue(fromDate) : ninetyDaysAgoIso(),
      to: toDate ? fromDateInputValue(toDate) : undefined,
      limit: 50,
      before: last.triggered_at,
    }).then((response) => {
      setAlerts((prev) => [...prev, ...response.alerts]);
      setHasMore(response.alerts.length === 50);
    });
  }

  if (!selectedSite) {
    return <EmptyState title="Select a site to view alerts" />;
  }

  return (
    <div className="alerts-area" data-testid="alerts-area">
      <h1>Alerts</h1>
      <div role="tablist" aria-label="Alert status">
        {TABS.map((t) => (
          <button
            key={t}
            type="button"
            role="tab"
            aria-selected={tab === t}
            onClick={() => setTab(t)}
            data-testid={`alerts-tab-${t.toLowerCase()}`}
          >
            {TAB_LABELS[t]}
          </button>
        ))}
      </div>

      <fieldset className="alerts-area__filters" data-testid="alerts-filters">
        <legend>Filters</legend>
        <label>
          Condition/Metric
          <select
            aria-label="Condition/Metric"
            value={pendingConditionKey}
            onChange={(e) => setPendingConditionKey(e.target.value)}
            data-testid="alerts-filter-condition"
          >
            <option value="">All conditions</option>
            <option value={energyAttentionConditionKey(selectedSite.site_id)}>
              {conditionLabel(energyAttentionConditionKey(selectedSite.site_id))}
            </option>
          </select>
        </label>
        <label>
          From
          <input
            type="date"
            value={pendingFromDate}
            onChange={(e) => setPendingFromDate(e.target.value)}
            data-testid="alerts-filter-from"
          />
        </label>
        <label>
          To
          <input
            type="date"
            value={pendingToDate}
            onChange={(e) => setPendingToDate(e.target.value)}
            data-testid="alerts-filter-to"
          />
        </label>
        <button type="button" onClick={applyFilters} data-testid="alerts-apply-filters">
          Apply filters
        </button>
        <button type="button" onClick={resetFilters} data-testid="alerts-clear-filters">
          Clear filters
        </button>
      </fieldset>

      {status === "loading" ? <Loading label="Loading alerts…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}

      {status === "ready" && alerts.length === 0 ? (
        <EmptyState title={`No ${TAB_LABELS[tab].toLowerCase()} alerts`}>
          {tab === "ACTIVE" ? "No active alerts." : null}
        </EmptyState>
      ) : null}

      {status === "ready" && alerts.length > 0 ? (
        <div className="alerts-area__body">
          <ul className="alert-list" data-testid="alert-list">
            {alerts.map((alert) => (
              <AlertListItem
                key={alert.alert_id}
                alert={alert}
                selected={alert.alert_id === selectedAlertId}
                onSelect={() => setSelectedAlertId(alert.alert_id)}
              />
            ))}
          </ul>
          {hasMore ? (
            <button type="button" onClick={loadMore} data-testid="alerts-load-more">
              Load more
            </button>
          ) : (
            <p className="alerts-area__end" data-testid="alerts-end">
              End of alerts
            </p>
          )}
          {selectedAlert ? (
            <AlertDetailPanel alert={selectedAlert} siteName={selectedSite.site_name} multiSite={sites.length > 1} />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
