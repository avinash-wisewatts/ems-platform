/**
 * Admin -> Users -> one user: details, role and access, account status, and
 * password (administrator reset for others; "Change my password", with the
 * current password, for oneself).
 *
 * Self-protection mirrors the server: an administrator cannot change their
 * own role, access or status, nor reset their own password. The controls are
 * disabled here for clarity; the API and the database refuse it regardless.
 */

import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { Link, useParams } from "react-router-dom";
import {
  changeOwnPassword,
  describeAccess,
  getManagedUser,
  getUserManagementOptions,
  resetManagedUserPassword,
  updateManagedUser,
  type ManagedUser,
  type UserManagementOptions,
} from "../../api/adminUsers";
import { ApiError, NotAccessibleError } from "../../api/errors";
import { EmptyState } from "../../components/states/EmptyState";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { AccessFields, accessDraftProblem, accessPayload, type AccessDraft } from "./AccessFields";
import { TemporaryPasswordNotice } from "./TemporaryPasswordNotice";
import { CREATED_DATE_FORMAT, EMAIL_PATTERN } from "./UsersPage";

type Notice = { tone: "ok" | "error"; text: string } | null;

function errorText(err: unknown, fallback: string): string {
  return err instanceof ApiError ? err.detail || err.message : fallback;
}

function NoticeLine({ notice, testId }: { notice: Notice; testId: string }) {
  if (!notice) return null;
  return (
    <p
      className={`admin-notice${notice.tone === "error" ? " admin-notice--error" : ""}`}
      role={notice.tone === "error" ? "alert" : "status"}
      data-testid={testId}
    >
      {notice.text}
    </p>
  );
}

function toAccessDraft(user: ManagedUser): AccessDraft {
  return {
    role_code: user.role_code,
    access_scope_mode: user.access_scope_mode,
    organization_id: user.organization_id ?? "",
    site_ids: user.sites.map((s) => s.site_id),
  };
}

function DetailsSection({ user, onSaved }: { user: ManagedUser; onSaved: (u: ManagedUser) => void }) {
  const [displayName, setDisplayName] = useState(user.display_name);
  const [email, setEmail] = useState(user.email ?? "");
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const dirty = displayName !== user.display_name || email !== (user.email ?? "");

  async function save(event: FormEvent) {
    event.preventDefault();
    if (!displayName.trim()) return setNotice({ tone: "error", text: "Enter the full name." });
    if (!EMAIL_PATTERN.test(email.trim())) return setNotice({ tone: "error", text: "Enter a valid email address." });
    setSaving(true);
    try {
      const result = await updateManagedUser(user.portal_user_id, { display_name: displayName.trim(), email: email.trim() });
      onSaved(result.user);
      setNotice({ tone: "ok", text: "Details saved." });
    } catch (err) {
      setNotice({ tone: "error", text: errorText(err, "The details could not be saved.") });
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="admin-card" onSubmit={save} noValidate aria-label="Details" data-testid="user-details-form">
      <h2 className="admin-card__title">Details</h2>
      <div className="admin-form__grid">
        <div className="admin-field">
          <span className="admin-field__label">Username</span>
          <span className="admin-field__static" data-testid="user-username">
            {user.username}
          </span>
        </div>
        <label className="admin-field" htmlFor="user-display-name">
          <span className="admin-field__label">Full name</span>
          <input id="user-display-name" value={displayName} onChange={(e) => setDisplayName(e.target.value)} data-testid="user-display-name" />
        </label>
        <label className="admin-field" htmlFor="user-email">
          <span className="admin-field__label">Email address</span>
          <input id="user-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} data-testid="user-email" />
        </label>
      </div>
      <NoticeLine notice={notice} testId="user-details-notice" />
      <div className="admin-actions">
        <button type="submit" className="analytics-button analytics-button--primary" disabled={!dirty || saving} data-testid="user-details-save">
          {saving ? "Saving…" : "Save details"}
        </button>
      </div>
    </form>
  );
}

function AccessSection({
  user,
  options,
  onSaved,
}: {
  user: ManagedUser;
  options: UserManagementOptions;
  onSaved: (u: ManagedUser) => void;
}) {
  const [draft, setDraft] = useState<AccessDraft>(() => toAccessDraft(user));
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const original = toAccessDraft(user);
  const dirty =
    draft.role_code !== original.role_code ||
    draft.access_scope_mode !== original.access_scope_mode ||
    draft.organization_id !== original.organization_id ||
    [...draft.site_ids].sort().join() !== [...original.site_ids].sort().join();

  async function save(event: FormEvent) {
    event.preventDefault();
    const problem = accessDraftProblem(draft);
    if (problem) return setNotice({ tone: "error", text: problem });
    setSaving(true);
    try {
      const result = await updateManagedUser(user.portal_user_id, {
        role_code: draft.role_code as ManagedUser["role_code"],
        ...accessPayload(draft),
      });
      onSaved(result.user);
      setDraft(toAccessDraft(result.user));
      setNotice({ tone: "ok", text: "Role and access saved." });
    } catch (err) {
      setNotice({ tone: "error", text: errorText(err, "The role and access could not be saved.") });
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="admin-card" onSubmit={save} noValidate aria-label="Role and access" data-testid="user-access-form">
      <h2 className="admin-card__title">Role and access</h2>
      {user.is_self ? (
        <p className="admin-field__hint" data-testid="user-access-self">
          You cannot change your own role or access. Ask another administrator.
        </p>
      ) : null}
      <AccessFields options={options} draft={draft} onChange={setDraft} disabled={user.is_self || saving} idPrefix="user" />
      <NoticeLine notice={notice} testId="user-access-notice" />
      {!user.is_self ? (
        <div className="admin-actions">
          <button type="submit" className="analytics-button analytics-button--primary" disabled={!dirty || saving} data-testid="user-access-save">
            {saving ? "Saving…" : "Save role and access"}
          </button>
        </div>
      ) : null}
    </form>
  );
}

function StatusSection({ user, onSaved }: { user: ManagedUser; onSaved: (u: ManagedUser) => void }) {
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const [confirming, setConfirming] = useState(false);

  async function apply(isActive: boolean) {
    setSaving(true);
    try {
      const result = await updateManagedUser(user.portal_user_id, { is_active: isActive });
      onSaved(result.user);
      setNotice({ tone: "ok", text: isActive ? "Account activated." : "Account deactivated. The user can no longer sign in." });
    } catch (err) {
      setNotice({ tone: "error", text: errorText(err, "The account status could not be changed.") });
    } finally {
      setSaving(false);
      setConfirming(false);
    }
  }

  return (
    <div className="admin-card" data-testid="user-status-section">
      <h2 className="admin-card__title">Account status</h2>
      <p>
        <span className={`admin-status admin-status--${user.is_active ? "active" : "inactive"}`} data-testid="user-status">
          {user.is_active ? "Active" : "Inactive"}
        </span>
      </p>
      {user.is_self ? (
        <p className="admin-field__hint">You cannot deactivate your own account.</p>
      ) : user.is_active ? (
        confirming ? (
          <div className="admin-actions">
            <span>Deactivate {user.username}? They will no longer be able to sign in or access any data.</span>
            <button type="button" className="analytics-button admin-button--danger" onClick={() => void apply(false)} disabled={saving} data-testid="user-deactivate-confirm">
              Deactivate
            </button>
            <button type="button" className="analytics-button" onClick={() => setConfirming(false)} disabled={saving}>
              Cancel
            </button>
          </div>
        ) : (
          <div className="admin-actions">
            <button type="button" className="analytics-button" onClick={() => setConfirming(true)} data-testid="user-deactivate">
              Deactivate account
            </button>
          </div>
        )
      ) : (
        <div className="admin-actions">
          <button type="button" className="analytics-button analytics-button--primary" onClick={() => void apply(true)} disabled={saving} data-testid="user-activate">
            Activate account
          </button>
        </div>
      )}
      <NoticeLine notice={notice} testId="user-status-notice" />
    </div>
  );
}

function ResetPasswordSection({ user, options }: { user: ManagedUser; options: UserManagementOptions }) {
  // Another administrator's password: WiseWatts staff (GLOBAL) only -- the
  // database refuses it for tenant administrators.
  if (user.role_code === "ADMIN" && options.actor.access_scope_mode !== "GLOBAL") {
    return (
      <section className="admin-card" aria-label="Reset password" data-testid="reset-password-staff-only">
        <h2 className="admin-card__title">Reset password</h2>
        <p className="admin-header__subtitle">
          Only WiseWatts staff administrators can reset another administrator&apos;s password.
        </p>
      </section>
    );
  }
  return <ResetPasswordForm user={user} options={options} />;
}

function ResetPasswordForm({ user, options }: { user: ManagedUser; options: UserManagementOptions }) {
  const [mode, setMode] = useState<"generate" | "set">("generate");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [notice, setNotice] = useState<Notice>(null);
  const [temporary, setTemporary] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  async function reset(event: FormEvent) {
    event.preventDefault();
    setTemporary(null);
    if (mode === "set") {
      if (password.length < options.password_policy.min_length)
        return setNotice({ tone: "error", text: `Passwords must contain at least ${options.password_policy.min_length} characters.` });
      if (password !== confirm) return setNotice({ tone: "error", text: "The passwords do not match." });
    }
    setSaving(true);
    try {
      const result = await resetManagedUserPassword(user.portal_user_id, mode === "set" ? password : undefined);
      setTemporary(result.temporary_password);
      setPassword("");
      setConfirm("");
      setNotice({ tone: "ok", text: "Password reset. Any failed-sign-in lockout was cleared." });
    } catch (err) {
      setNotice({ tone: "error", text: errorText(err, "The password could not be reset.") });
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="admin-card" onSubmit={reset} noValidate aria-label="Reset password" data-testid="user-reset-form">
      <h2 className="admin-card__title">Reset password</h2>
      <div className="admin-radio-row" role="radiogroup" aria-label="New password">
        <label className="admin-check">
          <input type="radio" name="reset-mode" checked={mode === "generate"} onChange={() => setMode("generate")} data-testid="reset-generate" />
          <span>Generate a temporary password</span>
        </label>
        <label className="admin-check">
          <input type="radio" name="reset-mode" checked={mode === "set"} onChange={() => setMode("set")} data-testid="reset-set" />
          <span>Set a password</span>
        </label>
      </div>
      {mode === "set" ? (
        <div className="admin-form__grid">
          <label className="admin-field" htmlFor="reset-password">
            <span className="admin-field__label">New password</span>
            <input id="reset-password" type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} data-testid="reset-password" />
          </label>
          <label className="admin-field" htmlFor="reset-password-confirm">
            <span className="admin-field__label">Confirm password</span>
            <input id="reset-password-confirm" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} data-testid="reset-password-confirm" />
          </label>
        </div>
      ) : null}
      <NoticeLine notice={notice} testId="user-reset-notice" />
      {temporary ? <TemporaryPasswordNotice password={temporary} /> : null}
      <div className="admin-actions">
        <button type="submit" className="analytics-button" disabled={saving} data-testid="user-reset-submit">
          {saving ? "Resetting…" : "Reset password"}
        </button>
      </div>
    </form>
  );
}

/** Mirrors the server's password policy minimum (app/src/user_account_policy.py); the server enforces it. */
export const DEFAULT_MIN_PASSWORD_LENGTH = 12;

/**
 * Change one's own password (POST /api/admin/v1/me/password): current
 * password required; refused while the account is locked. Used on an
 * administrator's own user page and on /account/password for every role.
 */
export function ChangeOwnPasswordSection({ minLength = DEFAULT_MIN_PASSWORD_LENGTH }: { minLength?: number }) {
  const [current, setCurrent] = useState("");
  const [next, setNext] = useState("");
  const [confirm, setConfirm] = useState("");
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);

  async function change(event: FormEvent) {
    event.preventDefault();
    if (!current) return setNotice({ tone: "error", text: "Enter your current password." });
    if (next.length < minLength)
      return setNotice({ tone: "error", text: `Passwords must contain at least ${minLength} characters.` });
    if (next !== confirm) return setNotice({ tone: "error", text: "The new passwords do not match." });
    setSaving(true);
    try {
      await changeOwnPassword(current, next);
      setCurrent("");
      setNext("");
      setConfirm("");
      setNotice({ tone: "ok", text: "Your password was changed." });
    } catch (err) {
      setNotice({ tone: "error", text: errorText(err, "Your password could not be changed.") });
    } finally {
      setSaving(false);
    }
  }

  return (
    <form className="admin-card" onSubmit={change} noValidate aria-label="Change my password" data-testid="own-password-form">
      <h2 className="admin-card__title">Change my password</h2>
      <div className="admin-form__grid">
        <label className="admin-field" htmlFor="own-current">
          <span className="admin-field__label">Current password</span>
          <input id="own-current" type="password" autoComplete="current-password" value={current} onChange={(e) => setCurrent(e.target.value)} data-testid="own-current" />
        </label>
        <label className="admin-field" htmlFor="own-new">
          <span className="admin-field__label">New password</span>
          <input id="own-new" type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} data-testid="own-new" />
          <span className="admin-field__hint">At least {minLength} characters.</span>
        </label>
        <label className="admin-field" htmlFor="own-confirm">
          <span className="admin-field__label">Confirm new password</span>
          <input id="own-confirm" type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} data-testid="own-confirm" />
        </label>
      </div>
      <NoticeLine notice={notice} testId="own-password-notice" />
      <div className="admin-actions">
        <button type="submit" className="analytics-button analytics-button--primary" disabled={saving} data-testid="own-password-submit">
          {saving ? "Changing…" : "Change my password"}
        </button>
      </div>
    </form>
  );
}

export function UserDetailPage() {
  const { portalUserId } = useParams();
  const id = Number(portalUserId);
  const [status, setStatus] = useState<"loading" | "ready" | "missing" | "error">("loading");
  const [error, setError] = useState<unknown>(null);
  const [options, setOptions] = useState<UserManagementOptions | null>(null);
  const [user, setUser] = useState<ManagedUser | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!Number.isInteger(id) || id <= 0) {
      setStatus("missing");
      return;
    }
    let active = true;
    setStatus("loading");
    Promise.all([getUserManagementOptions(), getManagedUser(id)])
      .then(([opts, result]) => {
        if (!active) return;
        setOptions(opts);
        setUser(result.user);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        if (err instanceof NotAccessibleError) {
          setStatus("missing");
          return;
        }
        setError(err);
        setStatus("error");
      });
    return () => {
      active = false;
    };
  }, [id, nonce]);

  return (
    <section className="page page--admin-users" data-testid="page-admin-user" aria-label="User">
      <nav className="hierarchy-crumb" aria-label="Breadcrumb">
        <Link to="/admin/users">Users</Link>
        {user ? <span> / {user.username}</span> : null}
      </nav>

      {status === "loading" ? <Loading label="Loading user…" /> : null}
      {status === "error" ? <ErrorState error={error} title="The user could not be loaded" onRetry={() => setNonce((n) => n + 1)} /> : null}
      {status === "missing" ? (
        <EmptyState title="User not found">
          It does not exist or is outside the organizations you manage. <Link to="/admin/users">Back to Users</Link>
        </EmptyState>
      ) : null}

      {status === "ready" && user && options ? (
        <>
          <header className="admin-header">
            <div>
              <h1 className="admin-header__title" data-testid="user-heading">
                {user.display_name}
                {user.is_self ? <span className="admin-tag">You</span> : null}
              </h1>
              <p className="admin-header__subtitle">
                {user.role_label} · {user.organization_name ?? (user.access_scope_mode === "GLOBAL" ? "WiseWatts staff" : "—")} ·{" "}
                {describeAccess(user)} · created {CREATED_DATE_FORMAT.format(new Date(user.created_at))}
              </p>
            </div>
          </header>
          <DetailsSection user={user} onSaved={setUser} />
          <AccessSection user={user} options={options} onSaved={setUser} />
          <StatusSection user={user} onSaved={setUser} />
          {user.is_self ? <ChangeOwnPasswordSection minLength={options.password_policy.min_length} /> : <ResetPasswordSection user={user} options={options} />}
        </>
      ) : null}
    </section>
  );
}
