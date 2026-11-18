/**
 * Active Alerts and Resolved/Ended History (ADR-024 §11).
 *
 * Active: Name, Asset, Status and the Acknowledge action (users holding
 * alert.acknowledge -- the server enforces it regardless). Acknowledging
 * records who and when; the alert stays Active.
 * History: Resolved and Ended alerts of the last 90 days, newest first, with
 * "Load more" paging; alerts of deleted rules stay listed.
 */

import { useCallback, useEffect, useState } from "react";
import { acknowledgeAlert, getAlertDetail, getSiteAlerts } from "../../api/endpoints";
import type { Alert, AlertState } from "../../api/types";
import { EmptyState } from "../../components/states/EmptyState";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { ALERTS_CHANGED_EVENT } from "../../alerts/useActiveAlertCount";
import { AlertDetail } from "./AlertDetail";
import { formatSiteTime, parameterLabel, statusLabel } from "./alertFormat";

type Mode = "active" | "history";
type HistoryFilter = "ALL" | "RESOLVED" | "ENDED";

const PAGE = 50;
const REFRESH_MS = 60_000;

function statesFor(mode: Mode, filter: HistoryFilter): AlertState[] {
  if (mode === "active") return ["ACTIVE"];
  return filter === "ALL" ? ["RESOLVED", "ENDED"] : [filter];
}

export function AlertList({
  mode,
  siteId,
  timeZone,
  canAcknowledge,
}: {
  mode: Mode;
  siteId: string;
  timeZone: string | null;
  canAcknowledge: boolean;
}) {
  const [alerts, setAlerts] = useState<Alert[]>([]);
  const [nextBefore, setNextBefore] = useState<string | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState<unknown>(null);
  const [filter, setFilter] = useState<HistoryFilter>("ALL");
  const [selected, setSelected] = useState<Alert | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let active = true;
    setStatus((s) => (s === "ready" ? s : "loading"));
    getSiteAlerts(siteId, { states: statesFor(mode, filter), limit: PAGE })
      .then((r) => {
        if (!active) return;
        setAlerts(r.alerts);
        setNextBefore(r.next_before);
        setStatus("ready");
      })
      .catch((e: unknown) => {
        if (!active) return;
        setError(e);
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [siteId, mode, filter, nonce]);

  useEffect(() => {
    if (mode !== "active") return;
    const timer = window.setInterval(reload, REFRESH_MS);
    return () => window.clearInterval(timer);
  }, [mode, reload]);

  function loadMore() {
    if (!nextBefore) return;
    getSiteAlerts(siteId, { states: statesFor(mode, filter), limit: PAGE, before: nextBefore }).then((r) => {
      setAlerts((prev) => [...prev, ...r.alerts]);
      setNextBefore(r.next_before);
    });
  }

  async function acknowledge(alert: Alert) {
    setBusy(alert.alert_id);
    setActionError(null);
    try {
      const updated = await acknowledgeAlert(alert.alert_id);
      setAlerts((prev) => prev.map((a) => (a.alert_id === updated.alert_id ? updated : a)));
      if (selected?.alert_id === updated.alert_id) setSelected(updated);
      window.dispatchEvent(new Event(ALERTS_CHANGED_EVENT));
    } catch (e) {
      setActionError(e instanceof Error ? e.message : "The alert could not be acknowledged.");
      reload();
    } finally {
      setBusy(null);
    }
  }

  async function open(alert: Alert) {
    setSelected(alert);
    try {
      setSelected(await getAlertDetail(alert.alert_id));
    } catch {
      // keep the list row's data
    }
  }

  if (status === "loading") return <Loading label="Loading alerts…" />;
  if (status === "error") return <ErrorState error={error} onRetry={reload} />;

  return (
    <div className="alerts-panel" data-testid={`alerts-${mode}`}>
      {mode === "history" ? (
        <label className="alerts-field alerts-field--inline">
          <span>Show</span>
          <select value={filter} onChange={(e) => setFilter(e.target.value as HistoryFilter)} data-testid="history-filter">
            <option value="ALL">Resolved and ended</option>
            <option value="RESOLVED">Resolved</option>
            <option value="ENDED">Ended</option>
          </select>
          <span className="alerts-muted">Last 90 days</span>
        </label>
      ) : null}
      {actionError ? (
        <p className="alerts-error" role="alert">
          {actionError}
        </p>
      ) : null}
      {alerts.length === 0 ? (
        <EmptyState title={mode === "active" ? "No active alerts" : "No resolved or ended alerts"}>
          {mode === "active" ? "Nothing needs attention on this site right now." : "Nothing in the last 90 days."}
        </EmptyState>
      ) : (
        <div className="alerts-table-wrap">
          <table className="alerts-table" data-testid={`alerts-table-${mode}`}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Asset</th>
                <th>Status</th>
                <th>{mode === "active" ? "Action" : "Resolved / ended"}</th>
              </tr>
            </thead>
            <tbody>
              {alerts.map((a) => (
                <tr key={a.alert_id} data-testid={`alert-row-${a.alert_id}`}>
                  <td>
                    <button type="button" className="alerts-link" onClick={() => open(a)}>
                      {a.rule_name}
                    </button>
                    <div className="alerts-muted">
                      {parameterLabel(a.parameter)} · {formatSiteTime(a.triggered_at, timeZone)}
                    </div>
                  </td>
                  <td>{a.asset.name}</td>
                  <td>
                    <span className={`alerts-status alerts-status--${a.state.toLowerCase()}`}>{statusLabel(a)}</span>
                  </td>
                  <td>
                    {mode === "history" ? (
                      formatSiteTime(a.resolved_at ?? a.ended_at, timeZone)
                    ) : a.acknowledgement ? (
                      <span className="alerts-muted" data-testid="alert-acknowledged">
                        Acknowledged by {a.acknowledgement.acknowledged_by}
                      </span>
                    ) : canAcknowledge ? (
                      <button
                        type="button"
                        className="analytics-button"
                        disabled={busy === a.alert_id}
                        onClick={() => acknowledge(a)}
                        data-testid={`acknowledge-${a.alert_id}`}
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
          {nextBefore ? (
            <button type="button" className="alerts-link" onClick={loadMore} data-testid="alerts-load-more">
              Load more
            </button>
          ) : null}
        </div>
      )}
      {selected ? <AlertDetail alert={selected} timeZone={timeZone} onClose={() => setSelected(null)} /> : null}
    </div>
  );
}
