/**
 * Admin -> Users: the users this administrator may manage, with search and
 * filters, and Create user.
 *
 * The list is exactly what the database returns for the signed-in
 * administrator (admin.list_manageable_portal_users): a tenant administrator
 * never receives another organization's users, so the filters below only
 * narrow an already-scoped list. Creating a user goes through the same
 * audited database function as the Administration App's Users page.
 */

import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { Link } from "react-router-dom";
import {
  createManagedUser,
  describeAccess,
  getUserManagementOptions,
  listManagedUsers,
  type ManagedUser,
  type UserManagementOptions,
} from "../../api/adminUsers";
import { ApiError } from "../../api/errors";
import { ErrorState } from "../../components/states/ErrorState";
import { Loading } from "../../components/states/Loading";
import { AccessFields, accessDraftProblem, accessPayload, type AccessDraft } from "./AccessFields";
import { TemporaryPasswordNotice } from "./TemporaryPasswordNotice";

export const CREATED_DATE_FORMAT = new Intl.DateTimeFormat(undefined, { year: "numeric", month: "short", day: "numeric" });

export const EMAIL_PATTERN = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

type Status = "loading" | "ready" | "error";

type CreateDraft = AccessDraft & {
  username: string;
  display_name: string;
  email: string;
  is_active: boolean;
  password_mode: "generate" | "set";
  password: string;
  password_confirm: string;
};

function emptyDraft(options: UserManagementOptions): CreateDraft {
  const tenantActor = options.actor.access_scope_mode !== "GLOBAL";
  return {
    username: "",
    display_name: "",
    email: "",
    is_active: true,
    password_mode: "generate",
    password: "",
    password_confirm: "",
    role_code: "",
    access_scope_mode: tenantActor ? (options.scopes[0]?.access_scope_mode ?? "") : "",
    organization_id: tenantActor ? (options.actor.organization_id ?? "") : "",
    site_ids: [],
  };
}

function createProblem(draft: CreateDraft, options: UserManagementOptions): string | null {
  if (!draft.username.trim()) return "Enter a username.";
  if (!draft.display_name.trim()) return "Enter the full name.";
  if (!EMAIL_PATTERN.test(draft.email.trim())) return "Enter a valid email address.";
  const access = accessDraftProblem(draft);
  if (access) return access;
  if (draft.password_mode === "set") {
    if (draft.password.length < options.password_policy.min_length)
      return `Passwords must contain at least ${options.password_policy.min_length} characters.`;
    if (draft.password.length > options.password_policy.max_length)
      return `Passwords must contain at most ${options.password_policy.max_length} characters.`;
    if (draft.password !== draft.password_confirm) return "The passwords do not match.";
  }
  return null;
}

function CreateUserForm({
  options,
  onCreated,
  onCancel,
}: {
  options: UserManagementOptions;
  onCreated: (user: ManagedUser, temporaryPassword: string | null) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState<CreateDraft>(() => emptyDraft(options));
  const [problem, setProblem] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const set = (patch: Partial<CreateDraft>) => setDraft((d) => ({ ...d, ...patch }));

  async function submit(event: FormEvent) {
    event.preventDefault();
    const local = createProblem(draft, options);
    setProblem(local);
    if (local) return;
    setSubmitting(true);
    try {
      const result = await createManagedUser({
        username: draft.username.trim(),
        display_name: draft.display_name.trim(),
        email: draft.email.trim(),
        role_code: draft.role_code as ManagedUser["role_code"],
        is_active: draft.is_active,
        ...accessPayload(draft),
        ...(draft.password_mode === "set" ? { password: draft.password } : {}),
      });
      onCreated(result.user, result.temporary_password);
    } catch (err) {
      setProblem(err instanceof ApiError ? err.detail || err.message : "The user could not be created.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form className="admin-card" onSubmit={submit} noValidate data-testid="create-user-form" aria-label="Create user">
      <h2 className="admin-card__title">Create user</h2>
      <div className="admin-form__grid">
        <label className="admin-field" htmlFor="create-username">
          <span className="admin-field__label">Username</span>
          <input
            id="create-username"
            autoComplete="off"
            value={draft.username}
            onChange={(e) => set({ username: e.target.value })}
            data-testid="create-username"
          />
          <span className="admin-field__hint">Used to sign in. Letters, digits and . _ @ + -; cannot be changed later.</span>
        </label>
        <label className="admin-field" htmlFor="create-display-name">
          <span className="admin-field__label">Full name</span>
          <input
            id="create-display-name"
            value={draft.display_name}
            onChange={(e) => set({ display_name: e.target.value })}
            data-testid="create-display-name"
          />
        </label>
        <label className="admin-field" htmlFor="create-email">
          <span className="admin-field__label">Email address</span>
          <input
            id="create-email"
            type="email"
            value={draft.email}
            onChange={(e) => set({ email: e.target.value })}
            data-testid="create-email"
          />
        </label>
      </div>

      <h3 className="admin-card__subtitle">Role and access</h3>
      <AccessFields options={options} draft={draft} onChange={(next) => set(next)} idPrefix="create" />

      <h3 className="admin-card__subtitle">Initial password</h3>
      <div className="admin-radio-row" role="radiogroup" aria-label="Initial password">
        <label className="admin-check">
          <input
            type="radio"
            name="password-mode"
            checked={draft.password_mode === "generate"}
            onChange={() => set({ password_mode: "generate", password: "", password_confirm: "" })}
            data-testid="create-password-generate"
          />
          <span>Generate a temporary password (shown once)</span>
        </label>
        <label className="admin-check">
          <input
            type="radio"
            name="password-mode"
            checked={draft.password_mode === "set"}
            onChange={() => set({ password_mode: "set" })}
            data-testid="create-password-set"
          />
          <span>Set a password</span>
        </label>
      </div>
      {draft.password_mode === "set" ? (
        <div className="admin-form__grid">
          <label className="admin-field" htmlFor="create-password">
            <span className="admin-field__label">Password</span>
            <input
              id="create-password"
              type="password"
              autoComplete="new-password"
              value={draft.password}
              onChange={(e) => set({ password: e.target.value })}
              data-testid="create-password"
            />
            <span className="admin-field__hint">At least {options.password_policy.min_length} characters.</span>
          </label>
          <label className="admin-field" htmlFor="create-password-confirm">
            <span className="admin-field__label">Confirm password</span>
            <input
              id="create-password-confirm"
              type="password"
              autoComplete="new-password"
              value={draft.password_confirm}
              onChange={(e) => set({ password_confirm: e.target.value })}
              data-testid="create-password-confirm"
            />
          </label>
        </div>
      ) : null}

      <label className="admin-check admin-check--standalone">
        <input
          type="checkbox"
          checked={draft.is_active}
          onChange={(e) => set({ is_active: e.target.checked })}
          data-testid="create-active"
        />
        <span>Account active (the user can sign in)</span>
      </label>

      {problem ? (
        <p className="admin-notice admin-notice--error" role="alert" data-testid="create-error">
          {problem}
        </p>
      ) : null}
      <div className="admin-actions">
        <button type="submit" className="analytics-button analytics-button--primary" disabled={submitting} data-testid="create-submit">
          {submitting ? "Creating…" : "Create user"}
        </button>
        <button type="button" className="analytics-button" onClick={onCancel} disabled={submitting}>
          Cancel
        </button>
      </div>
    </form>
  );
}

export function UsersPage() {
  const [status, setStatus] = useState<Status>("loading");
  const [error, setError] = useState<unknown>(null);
  const [options, setOptions] = useState<UserManagementOptions | null>(null);
  const [users, setUsers] = useState<ManagedUser[]>([]);
  const [nonce, setNonce] = useState(0);
  const [creating, setCreating] = useState(false);
  const [created, setCreated] = useState<{ user: ManagedUser; temporaryPassword: string | null } | null>(null);

  const [query, setQuery] = useState("");
  const [roleFilter, setRoleFilter] = useState("");
  const [orgFilter, setOrgFilter] = useState("");
  const [statusFilter, setStatusFilter] = useState<"" | "active" | "inactive">("");

  useEffect(() => {
    let active = true;
    setStatus("loading");
    Promise.all([getUserManagementOptions(), listManagedUsers()])
      .then(([opts, list]) => {
        if (!active) return;
        setOptions(opts);
        setUsers(list.users);
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
  }, [nonce]);

  const organizations = useMemo(() => {
    const names = new Map<string, string>();
    for (const u of users) if (u.organization_id) names.set(u.organization_id, u.organization_name ?? u.organization_id);
    return [...names.entries()].sort((a, b) => a[1].localeCompare(b[1]));
  }, [users]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return users.filter((u) => {
      if (q && ![u.username, u.display_name, u.email ?? ""].some((v) => v.toLowerCase().includes(q))) return false;
      if (roleFilter && u.role_code !== roleFilter) return false;
      if (orgFilter === "__global" ? u.organization_id !== null : orgFilter && u.organization_id !== orgFilter) return false;
      if (statusFilter === "active" && !u.is_active) return false;
      if (statusFilter === "inactive" && u.is_active) return false;
      return true;
    });
  }, [users, query, roleFilter, orgFilter, statusFilter]);

  return (
    <section className="page page--admin-users" data-testid="page-admin-users" aria-label="Users">
      <header className="admin-header">
        <div>
          <h1 className="admin-header__title">Users</h1>
          <p className="admin-header__subtitle">
            Accounts you can manage, their role and what they can access. Changes are recorded in the audit trail.
          </p>
        </div>
        {status === "ready" && !creating ? (
          <button
            type="button"
            className="analytics-button analytics-button--primary"
            onClick={() => {
              setCreated(null);
              setCreating(true);
            }}
            data-testid="create-user-open"
          >
            Create user
          </button>
        ) : null}
      </header>

      {status === "loading" ? <Loading label="Loading users…" /> : null}
      {status === "error" ? (
        <ErrorState error={error} title="Users could not be loaded" onRetry={() => setNonce((n) => n + 1)} />
      ) : null}

      {created ? (
        <div className="admin-card admin-card--success" data-testid="create-success" role="status">
          <p className="admin-notice">
            Created <Link to={`/admin/users/${created.user.portal_user_id}`}>{created.user.username}</Link>.
          </p>
          {created.temporaryPassword ? <TemporaryPasswordNotice password={created.temporaryPassword} /> : null}
        </div>
      ) : null}

      {status === "ready" && options && creating ? (
        <CreateUserForm
          options={options}
          onCancel={() => setCreating(false)}
          onCreated={(user, temporaryPassword) => {
            setCreating(false);
            setCreated({ user, temporaryPassword });
            setUsers((list) => [...list.filter((u) => u.portal_user_id !== user.portal_user_id), user]);
          }}
        />
      ) : null}

      {status === "ready" && options ? (
        <div className="admin-card">
          <div className="admin-filters" role="search">
            <label className="admin-field admin-field--grow" htmlFor="users-search">
              <span className="admin-field__label">Search</span>
              <input
                id="users-search"
                type="search"
                placeholder="Username, name or email"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                data-testid="users-search"
              />
            </label>
            <label className="admin-field" htmlFor="users-role-filter">
              <span className="admin-field__label">Role</span>
              <select id="users-role-filter" value={roleFilter} onChange={(e) => setRoleFilter(e.target.value)} data-testid="users-role-filter">
                <option value="">All roles</option>
                {options.roles.map((r) => (
                  <option key={r.role_code} value={r.role_code}>
                    {r.display_name}
                  </option>
                ))}
              </select>
            </label>
            <label className="admin-field" htmlFor="users-org-filter">
              <span className="admin-field__label">Organization</span>
              <select id="users-org-filter" value={orgFilter} onChange={(e) => setOrgFilter(e.target.value)} data-testid="users-org-filter">
                <option value="">All organizations</option>
                {options.actor.access_scope_mode === "GLOBAL" ? <option value="__global">WiseWatts staff (all organizations)</option> : null}
                {organizations.map(([id, name]) => (
                  <option key={id} value={id}>
                    {name}
                  </option>
                ))}
              </select>
            </label>
            <label className="admin-field" htmlFor="users-status-filter">
              <span className="admin-field__label">Status</span>
              <select
                id="users-status-filter"
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)}
                data-testid="users-status-filter"
              >
                <option value="">All</option>
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
              </select>
            </label>
          </div>

          <p className="admin-count" data-testid="users-count">
            {visible.length === users.length ? `${users.length} users` : `${visible.length} of ${users.length} users`}
          </p>

          {visible.length === 0 ? (
            <p className="admin-empty" data-testid="users-empty">
              {users.length === 0 ? "There are no users you can manage yet." : "No users match these filters."}
            </p>
          ) : (
            <div className="admin-table-wrap">
              <table className="admin-table" data-testid="users-table">
                <thead>
                  <tr>
                    <th scope="col">Username</th>
                    <th scope="col">Full name</th>
                    <th scope="col">Email</th>
                    <th scope="col">Role</th>
                    <th scope="col">Organization</th>
                    <th scope="col">Site access</th>
                    <th scope="col">Status</th>
                    <th scope="col">Created</th>
                  </tr>
                </thead>
                <tbody>
                  {visible.map((u) => (
                    <tr key={u.portal_user_id} data-testid={`users-row-${u.portal_user_id}`}>
                      <td>
                        <Link to={`/admin/users/${u.portal_user_id}`}>{u.username}</Link>
                        {u.is_self ? <span className="admin-tag">You</span> : null}
                      </td>
                      <td>{u.display_name}</td>
                      <td className="admin-table__muted">{u.email ?? "—"}</td>
                      <td>{u.role_label}</td>
                      <td>{u.organization_name ?? (u.access_scope_mode === "GLOBAL" ? "WiseWatts staff" : "—")}</td>
                      <td className="admin-table__access">{describeAccess(u)}</td>
                      <td>
                        <span className={`admin-status admin-status--${u.is_active ? "active" : "inactive"}`}>
                          {u.is_active ? "Active" : "Inactive"}
                        </span>
                      </td>
                      <td className="admin-table__muted">{CREATED_DATE_FORMAT.format(new Date(u.created_at))}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      ) : null}
    </section>
  );
}
