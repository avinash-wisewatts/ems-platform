/**
 * Active Alerts card (ADR-024 §11) for the Main Dashboard and Asset View.
 *
 * Brings the site's rule-based alerts onto the operational screens, where the
 * site-health pill only reflects Energy Attention (ADR-010). It reads the
 * same endpoint as the Alerts area and the header bell
 * (GET /sites/{id}/alerts?state=ACTIVE) -- no new backend, no new rule.
 *
 * - assetId given (Asset View): only that asset's alerts, no Asset column.
 * - Not-yet-acknowledged alerts first, then the most recently triggered.
 *   At most MAX_ROWS rows; "View all" opens the Alerts area.
 * - Acknowledge only for users holding alert.acknowledge (UX only; the server
 *   enforces it). Acknowledging never resolves the alert. After a change it
 *   signals ALERTS_CHANGED_EVENT so the header bell and other views refresh.
 * - Refreshes every 60 s (the evaluator runs every minute) and on that event.
 * - A failed read is shown inside the card with Retry; the rest of the page
 *   is unaffected.
 */

import { useCallback, useEffect, useState, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { acknowledgeAlert, getSiteAlerts } from "../../api/endpoints";
import { ApiError } from "../../api/errors";
import type { Alert } from "../../api/types";
import { ALERTS_CHANGED_EVENT } from "../../alerts/useActiveAlertCount";
import { formatSiteTime, parameterLabel, statusLabel, withUnit } from "./alertFormat";

const MAX_ROWS = 5;
const FETCH_LIMIT = 200; // above the 25-active-rules-per-site limit
const REFRESH_MS = 60_000;
export const ALERTS_PATH = "/features/alerts";

/** Not acknowledged first, then newest trigger first. */
export function orderActiveAlerts(alerts: readonly Alert[]): Alert[] {
  return [...alerts].sort((a, b) => {
    const ackA = a.acknowledgement ? 1 : 0;
    const ackB = b.acknowledgement ? 1 : 0;
    if (ackA !== ackB) return ackA - ackB;
    return Date.parse(b.triggered_at) - Date.parse(a.triggered_at);
  });
}

type Load = { status: "loading" } | { status: "error" } | { status: "ready"; alerts: Alert[] };

export function ActiveAlertsCard({
  siteId,
  timeZone,
  canAcknowledge,
  assetId,
}: {
  siteId: string;
  timeZone: string | null;
  canAcknowledge: boolean;
  /** Asset View: show only this asset's alerts. */
  assetId?: string;
}) {
  const [load, setLoad] = useState<Load>({ status: "loading" });
  const [nonce, setNonce] = useState(0);
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let active = true;
    getSiteAlerts(siteId, { states: ["ACTIVE"], limit: FETCH_LIMIT })
      .then((r) => {
        if (!active) return;
        // A malformed body must never take the host page down with it.
        if (!Array.isArray(r?.alerts)) throw new Error("Malformed active-alerts response");
        setLoad({ status: "ready", alerts: r.alerts });
      })
      .catch(() => {
        // Keep showing the last good list on a failed background refresh.
        if (active) setLoad((prev) => (prev.status === "ready" ? prev : { status: "error" }));
      });
    return () => {
      active = false;
    };
  }, [siteId, nonce]);

  useEffect(() => {
    const timer = window.setInterval(reload, REFRESH_MS);
    window.addEventListener(ALERTS_CHANGED_EVENT, reload);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener(ALERTS_CHANGED_EVENT, reload);
    };
  }, [reload]);

  async function acknowledge(alert: Alert) {
    setBusy(alert.alert_id);
    setActionError(null);
    try {
      const updated = await acknowledgeAlert(alert.alert_id);
      setLoad((prev) =>
        prev.status === "ready"
          ? { status: "ready", alerts: prev.alerts.map((a) => (a.alert_id === updated.alert_id ? updated : a)) }
          : prev,
      );
      window.dispatchEvent(new Event(ALERTS_CHANGED_EVENT));
    } catch (e) {
      setActionError(e instanceof ApiError && e.detail ? e.detail : "The alert could not be acknowledged.");
      reload();
    } finally {
      setBusy(null);
    }
  }

  const title = assetId ? "Active Alerts for this Asset" : "Active Alerts";

  let body: ReactNode;
  let count: number | null = null;
  if (load.status === "loading") {
    body = <p className="dashboard-card__note">Loading active alerts…</p>;
  } else if (load.status === "error") {
    body = (
      <p className="dashboard-card__note" data-testid="active-alerts-error">
        Active alerts could not be loaded.{" "}
        <button type="button" className="alerts-link" onClick={reload} data-testid="active-alerts-retry">
          Retry
        </button>
      </p>
    );
  } else {
    const scoped = assetId ? load.alerts.filter((a) => a.asset.asset_id === assetId) : load.alerts;
    count = scoped.length;
    const rows = orderActiveAlerts(scoped).slice(0, MAX_ROWS);
    const unacknowledged = scoped.filter((a) => !a.acknowledgement).length;
    body =
      scoped.length === 0 ? (
        <p className="dashboard-card__note" data-testid="active-alerts-empty">
          {assetId ? "No active alerts for this asset." : "No active alerts. Nothing needs attention on this site right now."}
        </p>
      ) : (
        <>
          <p className="alerts-muted" data-testid="active-alerts-summary">
            {scoped.length} active · {unacknowledged} not acknowledged
          </p>
          {actionError ? (
            <p className="alerts-error" role="alert">
              {actionError}
            </p>
          ) : null}
          <div className="alerts-table-wrap">
            <table className="alerts-table" data-testid="active-alerts-table">
              <thead>
                <tr>
                  <th>Name</th>
                  {assetId ? null : <th>Asset</th>}
                  <th>Latest value</th>
                  <th>Since</th>
                  <th>Status</th>
                  <th>Action</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((a) => (
                  <tr key={a.alert_id} data-testid={`active-alert-${a.alert_id}`}>
                    <td>
                      <Link to={ALERTS_PATH} className="alerts-link">
                        {a.rule_name}
                      </Link>
                      <div className="alerts-muted">{parameterLabel(a.parameter)}</div>
                    </td>
                    {assetId ? null : <td>{a.asset.name}</td>}
                    <td>{withUnit(a.latest_value ?? a.trigger_value, a.parameter.unit)}</td>
                    <td>{formatSiteTime(a.triggered_at, timeZone)}</td>
                    <td>
                      <span className="alerts-status alerts-status--active">{statusLabel(a)}</span>
                    </td>
                    <td>
                      {a.acknowledgement ? (
                        <span className="alerts-muted" data-testid="active-alert-acknowledged">
                          Acknowledged by {a.acknowledgement.acknowledged_by}
                        </span>
                      ) : canAcknowledge ? (
                        <button
                          type="button"
                          className="analytics-button"
                          disabled={busy === a.alert_id}
                          onClick={() => acknowledge(a)}
                          data-testid={`active-alert-acknowledge-${a.alert_id}`}
                        >
                          Acknowledge
                        </button>
                      ) : (
                        <span className="alerts-muted">Not acknowledged</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      );
  }

  return (
    <section className="dashboard-card" data-testid="active-alerts-card">
      <div className="dashboard-card__header">
        <h2>
          {title}
          {count !== null && count > 0 ? (
            <span className="active-alerts-card__count" data-testid="active-alerts-count">
              {count}
            </span>
          ) : null}
        </h2>
        <Link to={ALERTS_PATH} className="alerts-link" data-testid="active-alerts-view-all">
          {count !== null && count > MAX_ROWS ? `View all ${count}` : "Open Alerts"}
        </Link>
      </div>
      {body}
    </section>
  );
}
