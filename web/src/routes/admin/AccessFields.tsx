/**
 * Role + access assignment fields shared by Create user and the user detail
 * page. The choices come from GET /api/admin/v1/users/options, i.e. only what
 * THIS administrator may grant (their assignable roles, scopes no wider than
 * their own, their organizations and accessible sites). The server and the
 * database re-check every submission; nothing here is a security boundary.
 */

import type { AccessScopeMode, RoleCode, UserManagementOptions } from "../../api/adminUsers";

export type AccessDraft = {
  role_code: RoleCode | "";
  access_scope_mode: AccessScopeMode | "";
  organization_id: string;
  site_ids: string[];
};

/** Client-side pre-check (the server's message wins if it disagrees). */
export function accessDraftProblem(draft: AccessDraft): string | null {
  if (!draft.role_code) return "Select a role.";
  if (!draft.access_scope_mode) return "Select the access.";
  if (draft.access_scope_mode !== "GLOBAL" && !draft.organization_id) return "Select an organization.";
  if (draft.access_scope_mode === "SELECTED_SITES" && draft.site_ids.length === 0) return "Select at least one site.";
  return null;
}

/** The request fields for a draft (organization / sites only where the scope uses them). */
export function accessPayload(draft: AccessDraft) {
  const mode = draft.access_scope_mode as AccessScopeMode;
  return {
    access_scope_mode: mode,
    organization_id: mode === "GLOBAL" ? null : draft.organization_id || null,
    site_ids: mode === "SELECTED_SITES" ? draft.site_ids : [],
  };
}

export function AccessFields({
  options,
  draft,
  onChange,
  disabled = false,
  idPrefix,
}: {
  options: UserManagementOptions;
  draft: AccessDraft;
  onChange: (next: AccessDraft) => void;
  disabled?: boolean;
  idPrefix: string;
}) {
  const tenantActor = options.actor.access_scope_mode !== "GLOBAL";
  const orgSites = options.sites.filter((s) => s.organization_id === draft.organization_id);
  const role = options.roles.find((r) => r.role_code === draft.role_code);

  const set = (patch: Partial<AccessDraft>) => onChange({ ...draft, ...patch });

  return (
    <div className="admin-form__grid">
      <label className="admin-field" htmlFor={`${idPrefix}-role`}>
        <span className="admin-field__label">Role</span>
        <select
          id={`${idPrefix}-role`}
          value={draft.role_code}
          disabled={disabled}
          onChange={(e) => set({ role_code: e.target.value as RoleCode })}
          data-testid={`${idPrefix}-role`}
        >
          <option value="">Select a role…</option>
          {options.roles
            .filter((r) => r.assignable || r.role_code === draft.role_code)
            .map((r) => (
              <option key={r.role_code} value={r.role_code} disabled={!r.assignable}>
                {r.display_name}
              </option>
            ))}
        </select>
        {role ? <span className="admin-field__hint">{role.description}</span> : null}
      </label>

      <label className="admin-field" htmlFor={`${idPrefix}-scope`}>
        <span className="admin-field__label">Access</span>
        <select
          id={`${idPrefix}-scope`}
          value={draft.access_scope_mode}
          disabled={disabled}
          onChange={(e) => {
            const mode = e.target.value as AccessScopeMode;
            set({
              access_scope_mode: mode,
              organization_id:
                mode === "GLOBAL" ? "" : tenantActor ? (options.actor.organization_id ?? "") : draft.organization_id,
              site_ids: mode === "SELECTED_SITES" ? draft.site_ids : [],
            });
          }}
          data-testid={`${idPrefix}-scope`}
        >
          <option value="">Select the access…</option>
          {options.scopes.map((s) => (
            <option key={s.access_scope_mode} value={s.access_scope_mode}>
              {s.label}
            </option>
          ))}
        </select>
      </label>

      {draft.access_scope_mode && draft.access_scope_mode !== "GLOBAL" ? (
        <label className="admin-field" htmlFor={`${idPrefix}-org`}>
          <span className="admin-field__label">Organization</span>
          <select
            id={`${idPrefix}-org`}
            value={draft.organization_id}
            disabled={disabled || tenantActor}
            onChange={(e) => set({ organization_id: e.target.value, site_ids: [] })}
            data-testid={`${idPrefix}-org`}
          >
            <option value="">Select an organization…</option>
            {options.organizations.map((o) => (
              <option key={o.organization_id} value={o.organization_id}>
                {o.organization_name}
              </option>
            ))}
          </select>
        </label>
      ) : null}

      {draft.access_scope_mode === "SELECTED_SITES" ? (
        <fieldset className="admin-field admin-sites" disabled={disabled} data-testid={`${idPrefix}-sites`}>
          <legend className="admin-field__label">Sites</legend>
          {!draft.organization_id ? <p className="admin-field__hint">Select an organization first.</p> : null}
          {draft.organization_id && orgSites.length === 0 ? (
            <p className="admin-field__hint">This organization has no active sites you can assign.</p>
          ) : null}
          {orgSites.map((site) => (
            <label key={site.site_id} className="admin-check">
              <input
                type="checkbox"
                checked={draft.site_ids.includes(site.site_id)}
                onChange={(e) =>
                  set({
                    site_ids: e.target.checked
                      ? [...draft.site_ids, site.site_id]
                      : draft.site_ids.filter((id) => id !== site.site_id),
                  })
                }
                data-testid={`${idPrefix}-site-${site.site_id}`}
              />
              <span>{site.site_name}</span>
            </label>
          ))}
        </fieldset>
      ) : null}
    </div>
  );
}
