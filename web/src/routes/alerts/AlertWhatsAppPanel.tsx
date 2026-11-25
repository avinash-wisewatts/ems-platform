/**
 * WhatsApp notifications panel for one existing alert rule (WhatsApp Phase 1,
 * ADR-024 Amendment 2, migration 331). CONFIGURATION ONLY: nothing is sent,
 * and the panel always says so.
 *
 * - A separate concept from the rule: it has its own Save button and its own
 *   request (PUT .../whatsapp). Saving it never saves or changes the rule, so
 *   it can never end the rule's Active alert. Keys inside it never submit the
 *   surrounding rule form.
 * - Shown only to alert.configure holders (the rule form already is); the
 *   server checks again and refuses everyone else (D16, R5).
 * - Up to 10 numbers (D15), entered with their country code. Each new or
 *   changed number needs the administrator to confirm the person opted in,
 *   next to the Product-approved wording the server returns (R6, D21),
 *   which names the customer business (R9). The save sends back the version
 *   and business name shown. While no wording is approved, or the customer's
 *   legal name is not recorded, or the wording awaits Legal review, new
 *   numbers cannot be added at all.
 * - Switching WhatsApp off keeps the numbers (R7); removing a number deletes
 *   it when saved.
 */

import { useCallback, useEffect, useMemo, useState, type KeyboardEvent } from "react";
import { ApiError } from "../../api/errors";
import { getAlertRuleWhatsApp, saveAlertRuleWhatsApp } from "../../api/endpoints";
import type { AlertWhatsAppConfig, AlertWhatsAppRecipient } from "../../api/types";

const E164 = /^\+[1-9][0-9]{7,14}$/;

type Row = {
  key: string;
  recipientId: string | null;
  /** The stored number, for an existing recipient. */
  original: string | null;
  /** The number as now entered (full, with country code). */
  phone: string;
  confirmed: boolean;
  consent: AlertWhatsAppRecipient["consent"] | null;
  editing: boolean;
};

/** "+1 (202) 555-0100" -> "+12025550100". Format only: the server validates fully. */
export function compactPhone(raw: string): string {
  return raw.replace(/[\s\-().]/g, "");
}

function rowsFrom(config: AlertWhatsAppConfig): Row[] {
  return config.recipients.map((r) => ({
    key: r.recipient_id,
    recipientId: r.recipient_id,
    original: r.phone_e164,
    phone: r.phone_e164,
    confirmed: false,
    consent: r.consent,
    editing: false,
  }));
}

function needsConsent(row: Row): boolean {
  return row.recipientId === null || compactPhone(row.phone) !== row.original;
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

let keySeq = 0;

export function AlertWhatsAppPanel({ ruleId }: { ruleId: string }) {
  const [config, setConfig] = useState<AlertWhatsAppConfig | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [enabled, setEnabled] = useState(false);
  const [rows, setRows] = useState<Row[]>([]);
  const [countryCode, setCountryCode] = useState("+91");
  const [number, setNumber] = useState("");
  const [addError, setAddError] = useState<string | null>(null);
  const [rowErrors, setRowErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(false);
  const [saved, setSaved] = useState(false);
  const [saving, setSaving] = useState(false);
  const [nonce, setNonce] = useState(0);

  const reload = useCallback(() => setNonce((n) => n + 1), []);

  useEffect(() => {
    let active = true;
    setLoadError(null);
    getAlertRuleWhatsApp(ruleId)
      .then((c) => {
        if (!active) return;
        setConfig(c);
        setEnabled(c.enabled);
        setRows(rowsFrom(c));
        setStale(false);
        setError(null);
        setRowErrors({});
      })
      .catch((e: unknown) => {
        if (!active) return;
        setLoadError(e instanceof ApiError ? e.detail || e.message : "The WhatsApp settings could not be loaded.");
      });
    return () => {
      active = false;
    };
  }, [ruleId, nonce]);

  const statement = config?.consent_statement ?? null;
  const max = config?.max_recipients ?? 10;

  const dirty = useMemo(() => {
    if (!config) return false;
    if (enabled !== config.enabled) return true;
    if (rows.length !== config.recipients.length) return true;
    return rows.some((r) => r.recipientId === null || compactPhone(r.phone) !== r.original);
  }, [config, enabled, rows]);

  function stopSubmit(event: KeyboardEvent) {
    // The panel sits inside the rule form: Enter must never save the rule.
    if (event.key === "Enter") event.preventDefault();
  }

  function touch() {
    setSaved(false);
    setError(null);
  }

  function duplicateOf(phone: string, exceptKey: string | null): boolean {
    return rows.some((r) => r.key !== exceptKey && compactPhone(r.phone) === phone);
  }

  function add() {
    touch();
    const digits = compactPhone(number);
    const code = compactPhone(countryCode).replace(/^\+?/, "+");
    const phone = digits.startsWith("+") ? digits : `${code}${digits.replace(/^0+/, "")}`;
    if (!E164.test(phone)) {
      setAddError("Enter a valid mobile number with its country code.");
      return;
    }
    if (duplicateOf(phone, null)) {
      setAddError("This number is already in the list.");
      return;
    }
    if (rows.length >= max) {
      setAddError(`An alert rule can have at most ${max} WhatsApp numbers.`);
      return;
    }
    keySeq += 1;
    setRows((prev) => [
      ...prev,
      { key: `new-${keySeq}`, recipientId: null, original: null, phone, confirmed: false, consent: null, editing: false },
    ]);
    setNumber("");
    setAddError(null);
  }

  function update(key: string, change: Partial<Row>) {
    touch();
    setRows((prev) => prev.map((r) => (r.key === key ? { ...r, ...change } : r)));
    setRowErrors((prev) => {
      const next = { ...prev };
      delete next[key];
      return next;
    });
  }

  function remove(key: string) {
    touch();
    setRows((prev) => prev.filter((r) => r.key !== key));
  }

  function validate(): boolean {
    const problems: Record<string, string> = {};
    for (const row of rows) {
      const phone = compactPhone(row.phone);
      if (!E164.test(phone)) problems[row.key] = "Enter a valid mobile number with its country code.";
      else if (duplicateOf(phone, row.key)) problems[row.key] = "This number is already in the list.";
      else if (needsConsent(row) && !row.confirmed) problems[row.key] = "Confirm that this person agreed to receive WhatsApp alert messages.";
    }
    setRowErrors(problems);
    if (Object.keys(problems).length > 0) {
      setError("Check the highlighted numbers.");
      return false;
    }
    if (enabled && rows.length === 0) {
      setError("Add at least one number before turning WhatsApp notifications on.");
      return false;
    }
    return true;
  }

  async function save() {
    if (!config) return;
    touch();
    setStale(false);
    if (!validate()) return;
    setSaving(true);
    try {
      const next = await saveAlertRuleWhatsApp(ruleId, {
        enabled,
        revision: config.revision,
        consent_statement_version: statement?.version ?? null,
        consent_business_name: statement?.business_name ?? null,
        recipients: rows.map((r) => ({
          recipient_id: r.recipientId,
          phone: compactPhone(r.phone),
          opt_in_confirmed: needsConsent(r) ? r.confirmed : false,
        })),
      });
      setConfig(next);
      setEnabled(next.enabled);
      setRows(rowsFrom(next));
      setRowErrors({});
      setSaved(true);
    } catch (e) {
      if (e instanceof ApiError && e.status === 409) setStale(true);
      setError(e instanceof ApiError ? e.detail || e.message : "The WhatsApp settings could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <fieldset className="alerts-fieldset alerts-whatsapp" data-testid="whatsapp-panel" onKeyDown={stopSubmit}>
      <legend>WhatsApp notifications</legend>
      <p className="alerts-notice" data-testid="whatsapp-not-sent">
        WhatsApp messages are not sent yet. You can set up the numbers now; nothing is sent until sending is switched on
        in a later release.
      </p>

      {loadError ? (
        <p className="alerts-error" role="alert" data-testid="whatsapp-load-error">
          {loadError}{" "}
          <button type="button" className="alerts-link" onClick={reload}>
            Try again
          </button>
        </p>
      ) : !config ? (
        <p className="alerts-muted" data-testid="whatsapp-loading">
          Loading WhatsApp settings…
        </p>
      ) : (
        <>
          <label className="alerts-check">
            <input
              type="checkbox"
              checked={enabled}
              onChange={(e) => {
                touch();
                setEnabled(e.target.checked);
              }}
              data-testid="whatsapp-enabled"
            />
            Enable WhatsApp notifications for this alert
          </label>
          {!enabled && rows.length > 0 ? (
            <p className="alerts-muted alerts-form__hint" data-testid="whatsapp-kept-note">
              {rows.length === 1 ? "1 number is" : `${rows.length} numbers are`} kept while WhatsApp is off.
            </p>
          ) : null}

          {enabled ? (
            <div className="alerts-whatsapp__list" data-testid="whatsapp-recipients">
              {rows.length === 0 ? <p className="alerts-muted">No numbers yet.</p> : null}
              <ul className="alerts-whatsapp__rows">
                {rows.map((row, index) => (
                  <li key={row.key} className="alerts-whatsapp__row" data-testid={`whatsapp-row-${index}`}>
                    <div className="alerts-whatsapp__line">
                      {row.editing ? (
                        <input
                          className="alerts-whatsapp__phone-input"
                          value={row.phone}
                          aria-label="Mobile number with country code"
                          onChange={(e) => update(row.key, { phone: e.target.value, confirmed: false })}
                          aria-invalid={Boolean(rowErrors[row.key])}
                          data-testid={`whatsapp-edit-input-${index}`}
                        />
                      ) : (
                        <span className="alerts-whatsapp__phone" data-testid={`whatsapp-phone-${index}`}>
                          {row.phone}
                        </span>
                      )}
                      <span className="alerts-actions">
                        {!row.editing && row.recipientId !== null ? (
                          <button
                            type="button"
                            className="alerts-link"
                            onClick={() => update(row.key, { editing: true })}
                            disabled={!statement}
                            data-testid={`whatsapp-edit-${index}`}
                          >
                            Edit
                          </button>
                        ) : null}
                        <button
                          type="button"
                          className="alerts-link alerts-link--danger"
                          onClick={() => remove(row.key)}
                          data-testid={`whatsapp-remove-${index}`}
                        >
                          Remove
                        </button>
                      </span>
                    </div>
                    {row.consent && !needsConsent(row) ? (
                      <p className="alerts-muted alerts-form__hint">
                        Opt-in confirmed by {row.consent.confirmed_by_name} on {formatDate(row.consent.confirmed_at)}
                      </p>
                    ) : null}
                    {needsConsent(row) && statement ? (
                      <label className="alerts-check alerts-whatsapp__consent">
                        <input
                          type="checkbox"
                          checked={row.confirmed}
                          onChange={(e) => update(row.key, { confirmed: e.target.checked })}
                          data-testid={`whatsapp-consent-${index}`}
                        />
                        <span data-testid={`whatsapp-consent-text-${index}`}>{statement.text}</span>
                      </label>
                    ) : null}
                    {rowErrors[row.key] ? (
                      <p className="alerts-error" role="alert" data-testid={`whatsapp-row-error-${index}`}>
                        {rowErrors[row.key]}
                      </p>
                    ) : null}
                  </li>
                ))}
              </ul>

              {!statement ? (
                <p className="alerts-muted alerts-form__hint" data-testid="whatsapp-no-wording">
                  {config?.consent_unavailable_reason === "legal_review_pending"
                    ? "New numbers can't be added yet: the opt-in confirmation wording is awaiting Legal review."
                    : config?.consent_unavailable_reason === "business_name_missing"
                      ? "New numbers can't be added yet: this customer's legal business name is not recorded. Ask WiseWatts Support to add it."
                      : "New numbers can't be added yet: the opt-in confirmation wording has not been approved."}
                </p>
              ) : rows.length >= max ? (
                <p className="alerts-muted alerts-form__hint" data-testid="whatsapp-limit">
                  This alert has the maximum of {max} WhatsApp numbers.
                </p>
              ) : (
                <div className="alerts-whatsapp__add">
                  <label className="alerts-field alerts-whatsapp__code">
                    <span>Country code</span>
                    <input
                      value={countryCode}
                      onChange={(e) => setCountryCode(e.target.value)}
                      inputMode="tel"
                      data-testid="whatsapp-country-code"
                    />
                  </label>
                  <label className="alerts-field alerts-whatsapp__number">
                    <span>Mobile number</span>
                    <input
                      value={number}
                      onChange={(e) => {
                        setNumber(e.target.value);
                        setAddError(null);
                      }}
                      onKeyDown={(e) => {
                        if (e.key === "Enter") add();
                      }}
                      inputMode="tel"
                      aria-invalid={Boolean(addError)}
                      data-testid="whatsapp-number"
                    />
                  </label>
                  <button type="button" className="analytics-button" onClick={add} data-testid="whatsapp-add">
                    + Add phone number
                  </button>
                  {addError ? (
                    <p className="alerts-error alerts-whatsapp__add-error" role="alert" data-testid="whatsapp-add-error">
                      {addError}
                    </p>
                  ) : null}
                </div>
              )}
            </div>
          ) : null}

          <div className="alerts-whatsapp__footer">
            <span className="alerts-muted" data-testid="whatsapp-status">
              {dirty ? "Unsaved WhatsApp changes" : saved ? "WhatsApp settings saved." : ""}
            </span>
            <button
              type="button"
              className="analytics-button analytics-button--primary"
              onClick={save}
              disabled={saving || !dirty}
              data-testid="whatsapp-save"
            >
              Save WhatsApp settings
            </button>
          </div>
          {error ? (
            <p className="alerts-error" role="alert" data-testid="whatsapp-error">
              {error}{" "}
              {stale ? (
                <button type="button" className="alerts-link" onClick={reload} data-testid="whatsapp-reload">
                  Reload
                </button>
              ) : null}
            </p>
          ) : null}
        </>
      )}
    </fieldset>
  );
}
