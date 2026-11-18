/**
 * Create / edit an alert rule (ADR-024 §3, §5, §9, §10). Shown only to users
 * holding alert.configure; the server validates everything again.
 *
 * - Parameters come from the server for the chosen asset (cumulative counters
 *   are never offered -- the form says so). Options are ordered by name, then
 *   Total / Average before phases. Changing the asset clears the parameter.
 * - Compact layout: fixed header and footer (Cancel / Create always visible),
 *   scrolling body, two-column grid collapsing to one column on narrow
 *   screens.
 * - Equal to needs an explicit tolerance in the parameter's unit -- no default.
 * - The schedule is in the site's timezone; an end before the start crosses
 *   midnight.
 * - Reminder frequency and Email / WhatsApp are stored preferences only and
 *   are labelled "Coming Soon": nothing is sent.
 */

import { useMemo, useState, type FormEvent } from "react";
import { ApiError } from "../../api/errors";
import { createAlertRule, updateAlertRule } from "../../api/endpoints";
import type {
  AlertComparator,
  AlertRule,
  AlertRuleInput,
  AlertRuleParameterOption,
  Weekday,
} from "../../api/types";
import { COMPARATOR_LABELS, WEEKDAYS, WEEKDAY_LABELS, parameterLabel } from "./alertFormat";

function paramKey(code: string, qualifier: string | null): string {
  return `${code}|${qualifier ?? ""}`;
}

// Total / average first, then phases, line-to-line pairs, neutral, anything else.
const QUALIFIER_ORDER = ["", "TOTAL", "AVG", "L1", "L2", "L3", "L12", "L23", "L31", "NEUTRAL"];

function qualifierRank(qualifier: string | null): number {
  const i = QUALIFIER_ORDER.indexOf(qualifier ?? "");
  return i === -1 ? QUALIFIER_ORDER.length : i;
}

export function sortParameterOptions(options: AlertRuleParameterOption[]): AlertRuleParameterOption[] {
  return [...options].sort(
    (a, b) =>
      a.parameter.name.localeCompare(b.parameter.name) ||
      qualifierRank(a.parameter.qualifier) - qualifierRank(b.parameter.qualifier) ||
      (a.parameter.qualifier ?? "").localeCompare(b.parameter.qualifier ?? ""),
  );
}

export function AlertRuleForm({
  siteId,
  timeZone,
  parameters,
  rule,
  onSaved,
  onCancel,
}: {
  siteId: string;
  timeZone: string | null;
  parameters: AlertRuleParameterOption[];
  rule: AlertRule | null;
  onSaved: (rule: AlertRule) => void;
  onCancel: () => void;
}) {
  const assets = useMemo(() => {
    const seen = new Map<string, string>();
    for (const p of parameters) seen.set(p.asset.asset_id, p.asset.name);
    if (rule && !seen.has(rule.asset.asset_id)) seen.set(rule.asset.asset_id, rule.asset.name);
    return [...seen.entries()].sort((a, b) => a[1].localeCompare(b[1]));
  }, [parameters, rule]);

  const [name, setName] = useState(rule?.name ?? "");
  const [assetId, setAssetId] = useState(rule?.asset.asset_id ?? "");
  const [param, setParam] = useState(rule ? paramKey(rule.parameter.code, rule.parameter.qualifier) : "");
  const [comparator, setComparator] = useState<AlertComparator>(rule?.condition.comparator ?? "GT");
  const [threshold, setThreshold] = useState(rule ? String(rule.condition.threshold) : "");
  const [tolerance, setTolerance] = useState(rule?.condition.tolerance != null ? String(rule.condition.tolerance) : "");
  const [startTime, setStartTime] = useState(rule?.schedule.start_time ?? "00:00");
  const [endTime, setEndTime] = useState(rule?.schedule.end_time ?? "23:59");
  const [weekdays, setWeekdays] = useState<Weekday[]>(rule?.schedule.weekdays ?? [...WEEKDAYS]);
  const [reminder, setReminder] = useState<"" | "15" | "30">(rule?.reminder_minutes ? (String(rule.reminder_minutes) as "15" | "30") : "");
  const [email, setEmail] = useState(rule?.delivery.email.requested ?? false);
  const [whatsapp, setWhatsapp] = useState(rule?.delivery.whatsapp.requested ?? false);
  const [enabled, setEnabled] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const assetParameters = useMemo(
    () => sortParameterOptions(parameters.filter((p) => p.asset.asset_id === assetId)),
    [parameters, assetId],
  );
  const selectedParam =
    assetParameters.find((p) => paramKey(p.parameter.code, p.parameter.qualifier) === param)?.parameter ??
    (rule && paramKey(rule.parameter.code, rule.parameter.qualifier) === param && rule.asset.asset_id === assetId
      ? rule.parameter
      : null);
  const unit = selectedParam?.unit ?? null;
  const everyDay = weekdays.length === WEEKDAYS.length;

  function toggleDay(day: Weekday) {
    setWeekdays((prev) => (prev.includes(day) ? prev.filter((d) => d !== day) : WEEKDAYS.filter((d) => prev.includes(d) || d === day)));
  }

  function validate(): string | null {
    if (!name.trim()) return "Enter a name.";
    if (name.trim().length > 120) return "The name can be at most 120 characters.";
    if (!assetId) return "Choose an asset.";
    if (!selectedParam) return "Choose a parameter.";
    if (threshold.trim() === "" || !Number.isFinite(Number(threshold))) return "Enter a valid value.";
    if (comparator === "EQ") {
      if (tolerance.trim() === "") return "Equal to needs a tolerance.";
      if (!Number.isFinite(Number(tolerance)) || Number(tolerance) < 0) return "The tolerance must be zero or a positive number.";
    }
    if (startTime === endTime) return "The schedule start and end times must differ.";
    if (weekdays.length === 0) return "Choose every day or at least one weekday.";
    return null;
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const problem = validate();
    if (problem) {
      setError(problem);
      return;
    }
    const input: AlertRuleInput = {
      name: name.trim(),
      asset_id: assetId,
      parameter_code: selectedParam!.code,
      qualifier: selectedParam!.qualifier,
      comparator,
      threshold: Number(threshold),
      tolerance: comparator === "EQ" ? Number(tolerance) : null,
      schedule: { start_time: startTime, end_time: endTime, weekdays },
      reminder_minutes: reminder === "" ? null : (Number(reminder) as 15 | 30),
      delivery: { email, whatsapp },
    };
    setSaving(true);
    setError(null);
    try {
      const saved = rule
        ? await updateAlertRule(rule.rule_id, { ...input, version: rule.version })
        : await createAlertRule(siteId, { ...input, enabled });
      onSaved(saved);
    } catch (e) {
      setError(e instanceof ApiError ? e.detail || e.message : "The alert rule could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="alerts-dialog__backdrop alerts-dialog__backdrop--form">
      <form
        className="alerts-dialog alerts-form"
        role="dialog"
        aria-modal="true"
        aria-labelledby="alert-rule-form-title"
        onSubmit={submit}
        noValidate
        data-testid="alert-rule-form"
      >
        <div className="alerts-form__header">
          <h2 id="alert-rule-form-title">{rule ? "Edit alert" : "Create new alert"}</h2>
        </div>

        <div className="alerts-form__body" data-testid="alert-rule-form-body">
          {rule?.active_alert_id ? (
            <p className="alerts-notice">Saving changes ends this rule's active alert; evaluation starts again.</p>
          ) : null}

          <div className="alerts-form__grid">
            <label className="alerts-field alerts-form__span">
              <span>Name</span>
              <input value={name} maxLength={120} onChange={(e) => setName(e.target.value)} data-testid="rule-name" />
            </label>

            <label className="alerts-field">
              <span>Asset</span>
              <select
                value={assetId}
                onChange={(e) => {
                  setAssetId(e.target.value);
                  setParam("");
                }}
                data-testid="rule-asset"
              >
                <option value="">Choose an asset</option>
                {assets.map(([id, label]) => (
                  <option key={id} value={id}>
                    {label}
                  </option>
                ))}
              </select>
            </label>

            <label className="alerts-field">
              <span>Parameter</span>
              <select value={param} onChange={(e) => setParam(e.target.value)} disabled={!assetId} data-testid="rule-parameter">
                <option value="">{assetId ? "Choose a parameter" : "Choose an asset first"}</option>
                {assetParameters.map((p) => (
                  <option key={paramKey(p.parameter.code, p.parameter.qualifier)} value={paramKey(p.parameter.code, p.parameter.qualifier)}>
                    {parameterLabel(p.parameter)}
                    {p.parameter.unit ? ` (${p.parameter.unit})` : ""}
                  </option>
                ))}
              </select>
            </label>
            {assetId ? (
              <p className="alerts-muted alerts-form__span alerts-form__hint" data-testid="rule-parameter-hint">
                {assetParameters.length === 1 ? "1 parameter" : `${assetParameters.length} parameters`} available for this
                asset. Cumulative energy counters (kWh, kVAh) can't be used for alerts.
              </p>
            ) : null}
          </div>

          <div className="alerts-form__grid alerts-form__grid--3">
            <label className="alerts-field">
              <span>Condition</span>
              <select value={comparator} onChange={(e) => setComparator(e.target.value as AlertComparator)} data-testid="rule-comparator">
                {(Object.keys(COMPARATOR_LABELS) as AlertComparator[]).map((c) => (
                  <option key={c} value={c}>
                    {COMPARATOR_LABELS[c]}
                  </option>
                ))}
              </select>
            </label>
            <label className="alerts-field">
              <span>Value{unit ? ` (${unit})` : ""}</span>
              <input type="number" step="any" value={threshold} onChange={(e) => setThreshold(e.target.value)} data-testid="rule-threshold" />
            </label>
            {comparator === "EQ" ? (
              <label className="alerts-field">
                <span>Tolerance ±{unit ? ` (${unit})` : ""}</span>
                <input
                  type="number"
                  step="any"
                  min="0"
                  value={tolerance}
                  onChange={(e) => setTolerance(e.target.value)}
                  data-testid="rule-tolerance"
                />
              </label>
            ) : null}
            <p className="alerts-muted alerts-form__span alerts-form__hint">
              Compared against a fixed value. Mean over a time window: coming later.
            </p>
          </div>

          <fieldset className="alerts-fieldset">
            <legend>Schedule{timeZone ? ` (site time, ${timeZone})` : " (site time)"}</legend>
            <div className="alerts-form__grid alerts-form__grid--3 alerts-form__grid--end">
              <label className="alerts-field">
                <span>From</span>
                <input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} data-testid="rule-start" />
              </label>
              <label className="alerts-field">
                <span>To</span>
                <input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} data-testid="rule-end" />
              </label>
              <label className="alerts-check">
                <input
                  type="checkbox"
                  checked={everyDay}
                  onChange={(e) => setWeekdays(e.target.checked ? [...WEEKDAYS] : [])}
                  data-testid="rule-every-day"
                />
                Every day
              </label>
            </div>
            {endTime < startTime ? <p className="alerts-muted alerts-form__hint">Runs overnight, past midnight.</p> : null}
            <div className="alerts-days">
              {WEEKDAYS.map((d) => (
                <label key={d} className="alerts-check">
                  <input type="checkbox" checked={weekdays.includes(d)} onChange={() => toggleDay(d)} data-testid={`rule-day-${d}`} />
                  {WEEKDAY_LABELS[d]}
                </label>
              ))}
            </div>
          </fieldset>

          <fieldset className="alerts-fieldset">
            <legend>
              Notifications <span className="alerts-badge">Coming Soon</span>
            </legend>
            <p className="alerts-muted alerts-form__hint" data-testid="rule-delivery-note">
              Alerts appear in the EMS. Email, WhatsApp and reminders are not sent yet — your choices are saved for when
              they become available.
            </p>
            <div className="alerts-form__grid alerts-form__grid--3 alerts-form__grid--end">
              <label className="alerts-check">
                <input type="checkbox" checked={email} onChange={(e) => setEmail(e.target.checked)} data-testid="rule-email" />
                Email <span className="alerts-badge">Coming Soon</span>
              </label>
              <label className="alerts-check">
                <input type="checkbox" checked={whatsapp} onChange={(e) => setWhatsapp(e.target.checked)} data-testid="rule-whatsapp" />
                WhatsApp <span className="alerts-badge">Coming Soon</span>
              </label>
              <label className="alerts-field">
                <span>
                  Reminder <span className="alerts-badge">Coming Soon</span>
                </span>
                <select value={reminder} onChange={(e) => setReminder(e.target.value as "" | "15" | "30")} data-testid="rule-reminder">
                  <option value="">None</option>
                  <option value="15">Every 15 minutes until acknowledged</option>
                  <option value="30">Every 30 minutes until acknowledged</option>
                </select>
              </label>
            </div>
          </fieldset>

          {!rule ? (
            <label className="alerts-check">
              <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} data-testid="rule-enabled" />
              Enabled
            </label>
          ) : null}
        </div>

        <div className="alerts-form__footer">
          {error ? (
            <p className="alerts-error alerts-form__error" role="alert" data-testid="rule-form-error">
              {error}
            </p>
          ) : (
            <span />
          )}
          <div className="alerts-actions">
            <button type="button" className="analytics-button" onClick={onCancel} disabled={saving}>
              Cancel
            </button>
            <button type="submit" className="analytics-button analytics-button--primary" disabled={saving} data-testid="rule-save">
              {rule ? "Save changes" : "Create alert"}
            </button>
          </div>
        </div>
      </form>
    </div>
  );
}
