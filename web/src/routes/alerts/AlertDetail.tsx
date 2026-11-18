/**
 * Alert detail (ADR-024 §11): triggered time, triggering condition, asset,
 * parameter, threshold/value, status and acknowledgement. Acknowledgement is
 * shown as information only -- it never changes the status.
 */

import type { Alert } from "../../api/types";
import {
  conditionText,
  endedReasonLabel,
  formatSiteTime,
  parameterLabel,
  statusLabel,
  withUnit,
} from "./alertFormat";

export function AlertDetail({
  alert,
  timeZone,
  onClose,
}: {
  alert: Alert;
  timeZone: string | null;
  onClose: () => void;
}) {
  const unit = alert.parameter.unit;
  return (
    <div className="alerts-dialog__backdrop" onClick={onClose}>
      <div
        className="alerts-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="alert-detail-title"
        data-testid="alert-detail"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="alerts-dialog__header">
          <h2 id="alert-detail-title">{alert.rule_name}</h2>
          <button type="button" className="alerts-link" onClick={onClose} aria-label="Close">
            Close
          </button>
        </div>
        <dl className="alerts-detail">
          <dt>Status</dt>
          <dd data-testid="alert-detail-status">{statusLabel(alert)}</dd>
          <dt>Triggered</dt>
          <dd>{formatSiteTime(alert.triggered_at, timeZone)}</dd>
          <dt>Condition</dt>
          <dd>{conditionText(alert.condition, unit)}</dd>
          <dt>Asset</dt>
          <dd>{alert.asset.name}</dd>
          <dt>Parameter</dt>
          <dd>{parameterLabel(alert.parameter)}</dd>
          <dt>Value when triggered</dt>
          <dd>{withUnit(alert.trigger_value, unit)}</dd>
          <dt>Latest value</dt>
          <dd data-testid="alert-detail-latest">
            {alert.state === "ACTIVE" && alert.data_unavailable
              ? "Unable to evaluate — data unavailable"
              : `${withUnit(alert.latest_value, unit)}${
                  alert.latest_value_at ? ` (${formatSiteTime(alert.latest_value_at, timeZone)})` : ""
                }`}
          </dd>
          {alert.state === "RESOLVED" ? (
            <>
              <dt>Resolved</dt>
              <dd>{formatSiteTime(alert.resolved_at, timeZone)}</dd>
              <dt>Value when resolved</dt>
              <dd>{withUnit(alert.resolved_value, unit)}</dd>
            </>
          ) : null}
          {alert.state === "ENDED" ? (
            <>
              <dt>Ended</dt>
              <dd>{formatSiteTime(alert.ended_at, timeZone)}</dd>
              <dt>Reason</dt>
              <dd>{endedReasonLabel(alert.ended_reason_code)}</dd>
            </>
          ) : null}
          <dt>Acknowledgement</dt>
          <dd data-testid="alert-detail-ack">
            {alert.acknowledgement
              ? `Acknowledged by ${alert.acknowledgement.acknowledged_by}, ${formatSiteTime(
                  alert.acknowledgement.acknowledged_at,
                  timeZone,
                )}`
              : "Not acknowledged"}
          </dd>
          <dt>Previous occurrences</dt>
          <dd>{alert.previous_occurrence_count}</dd>
        </dl>
        {alert.rule_deleted ? <p className="alerts-muted">This alert rule has since been deleted.</p> : null}
      </div>
    </div>
  );
}
