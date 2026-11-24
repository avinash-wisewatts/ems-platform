/**
 * Create Alert subtab (ADR-024 §1-§3, §8): the site's alert rules -- Name,
 * Asset, Parameter, Value/condition, enabled toggle, Edit and Delete -- and
 * Create New Alert. Every authorised site user can see the rules; only users
 * holding alert.configure (site administrators, WiseWatts admin staff) get the
 * toggle, Edit, Delete and Create controls. Editing, disabling or deleting ends
 * the rule's active alert; deleting keeps its history.
 *
 * WhatsApp (Phase 1): a "WhatsApp · N" badge marks rules with WhatsApp
 * switched on -- for alert.configure holders only. Every other role sees no
 * WhatsApp indicator, count or number (D16; the server sends them none).
 */

import { useCallback, useEffect, useState } from "react";
import { ApiError } from "../../api/errors";
import { deleteAlertRule, getAlertRuleParameters, getSiteAlertRules, setAlertRuleEnabled } from "../../api/endpoints";
import type { AlertRule, AlertRuleParameterOption } from "../../api/types";
import { EmptyState } from "../../components/states/EmptyState";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { ALERTS_CHANGED_EVENT } from "../../alerts/useActiveAlertCount";
import { AlertRuleForm } from "./AlertRuleForm";
import { conditionText, parameterLabel, scheduleText } from "./alertFormat";

export function AlertRules({
  siteId,
  timeZone,
  canConfigure,
}: {
  siteId: string;
  timeZone: string | null;
  canConfigure: boolean;
}) {
  const [rules, setRules] = useState<AlertRule[]>([]);
  const [maxRules, setMaxRules] = useState(25);
  const [parameters, setParameters] = useState<AlertRuleParameterOption[]>([]);
  const [status, setStatus] = useState<"loading" | "ready" | "error">("loading");
  const [error, setError] = useState<unknown>(null);
  const [editing, setEditing] = useState<AlertRule | "new" | null>(null);
  const [confirmDelete, setConfirmDelete] = useState<AlertRule | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let active = true;
    Promise.all([getSiteAlertRules(siteId), canConfigure ? getAlertRuleParameters(siteId) : Promise.resolve(null)])
      .then(([r, p]) => {
        if (!active) return;
        setRules(r.rules);
        setMaxRules(r.max_active_rules);
        if (p) setParameters(p.parameters);
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
  }, [siteId, canConfigure, nonce]);

  function changed() {
    window.dispatchEvent(new Event(ALERTS_CHANGED_EVENT));
    reload();
  }

  async function toggle(rule: AlertRule) {
    setBusy(rule.rule_id);
    setActionError(null);
    try {
      await setAlertRuleEnabled(rule.rule_id, !rule.enabled);
      changed();
    } catch (e) {
      setActionError(e instanceof ApiError ? e.detail || e.message : "The alert rule could not be changed.");
    } finally {
      setBusy(null);
    }
  }

  async function remove(rule: AlertRule) {
    setBusy(rule.rule_id);
    setActionError(null);
    try {
      await deleteAlertRule(rule.rule_id);
      setConfirmDelete(null);
      changed();
    } catch (e) {
      setActionError(e instanceof ApiError ? e.detail || e.message : "The alert rule could not be deleted.");
    } finally {
      setBusy(null);
    }
  }

  if (status === "loading") return <Loading label="Loading alert rules…" />;
  if (status === "error") return <ErrorState error={error} onRetry={reload} />;

  const activeCount = rules.filter((r) => r.enabled).length;

  return (
    <div className="alerts-panel" data-testid="alerts-rules">
      <div className="alerts-toolbar">
        <p className="alerts-muted">
          {activeCount} of {maxRules} active alert rules
        </p>
        {canConfigure ? (
          <button
            type="button"
            className="analytics-button analytics-button--primary"
            onClick={() => setEditing("new")}
            disabled={parameters.length === 0}
            data-testid="create-alert"
          >
            Create New Alert
          </button>
        ) : null}
      </div>
      {canConfigure && parameters.length === 0 ? (
        <p className="alerts-muted">No asset of this site has a parameter that alerts can use yet.</p>
      ) : null}
      {actionError ? (
        <p className="alerts-error" role="alert">
          {actionError}
        </p>
      ) : null}
      {rules.length === 0 ? (
        <EmptyState title="No alert rules yet">
          {canConfigure ? "Create an alert to be told when an asset needs attention." : "A site administrator can create alerts."}
        </EmptyState>
      ) : (
        <div className="alerts-table-wrap">
          <table className="alerts-table" data-testid="alert-rules-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Asset</th>
                <th>Parameter</th>
                <th>Value / condition</th>
                <th>Enabled</th>
                {canConfigure ? <th>Actions</th> : null}
              </tr>
            </thead>
            <tbody>
              {rules.map((r) => (
                <tr key={r.rule_id} data-testid={`rule-row-${r.rule_id}`}>
                  <td>
                    {r.name}
                    {canConfigure && r.whatsapp?.enabled ? (
                      <span
                        className="alerts-badge alerts-badge--whatsapp"
                        title="WhatsApp numbers are set up. WhatsApp messages are not sent yet."
                        data-testid={`rule-whatsapp-badge-${r.rule_id}`}
                      >
                        WhatsApp · {r.whatsapp.recipient_count}
                      </span>
                    ) : null}
                    <div className="alerts-muted">{scheduleText(r)}</div>
                  </td>
                  <td>{r.asset.name}</td>
                  <td>{parameterLabel(r.parameter)}</td>
                  <td>{conditionText(r.condition, r.parameter.unit)}</td>
                  <td>
                    <button
                      type="button"
                      role="switch"
                      aria-checked={r.enabled}
                      aria-label={`${r.enabled ? "Disable" : "Enable"} ${r.name}`}
                      className={`alerts-switch${r.enabled ? " alerts-switch--on" : ""}`}
                      disabled={!canConfigure || busy === r.rule_id}
                      onClick={() => toggle(r)}
                      data-testid={`rule-toggle-${r.rule_id}`}
                    >
                      <span className="alerts-switch__knob" />
                    </button>
                  </td>
                  {canConfigure ? (
                    <td className="alerts-table__actions">
                      <button type="button" className="alerts-link" onClick={() => setEditing(r)} data-testid={`rule-edit-${r.rule_id}`}>
                        Edit
                      </button>
                      <button
                        type="button"
                        className="alerts-link alerts-link--danger"
                        onClick={() => setConfirmDelete(r)}
                        data-testid={`rule-delete-${r.rule_id}`}
                      >
                        Delete
                      </button>
                    </td>
                  ) : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {editing ? (
        <AlertRuleForm
          siteId={siteId}
          timeZone={timeZone}
          parameters={parameters}
          rule={editing === "new" ? null : editing}
          onCancel={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            changed();
          }}
        />
      ) : null}

      {confirmDelete ? (
        <div className="alerts-dialog__backdrop">
          <div className="alerts-dialog" role="alertdialog" aria-modal="true" aria-labelledby="delete-title" data-testid="delete-confirm">
            <h2 id="delete-title">Delete “{confirmDelete.name}”?</h2>
            <p>
              The rule stops being evaluated{confirmDelete.active_alert_id ? " and its active alert ends" : ""}. Its past alerts stay in
              History.
            </p>
            <div className="alerts-actions">
              <button type="button" className="analytics-button" onClick={() => setConfirmDelete(null)}>
                Cancel
              </button>
              <button
                type="button"
                className="analytics-button alerts-button--danger"
                disabled={busy === confirmDelete.rule_id}
                onClick={() => remove(confirmDelete)}
                data-testid="delete-confirm-button"
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
