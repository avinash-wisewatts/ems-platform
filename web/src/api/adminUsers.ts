/**
 * Admin -> Users: the Administration App's user management
 * (app/src/routers/user_management_api.py), served under /api/admin/v1 by the
 * Administration App only. Every rule -- who may see, create or change whom,
 * which roles and scopes may be granted, tenant isolation, audit -- is
 * enforced by the server and the database; the types here only describe it.
 */

import { adminApiRequest } from "./client";

export type RoleCode = "ADMIN" | "OPERATOR" | "VIEWER";
export type AccessScopeMode = "GLOBAL" | "ORGANIZATION" | "SELECTED_SITES";

export type ManagedUserSite = { site_id: string; site_name: string | null; site_code: string | null };

export type ManagedUser = {
  portal_user_id: number;
  username: string;
  display_name: string;
  email: string | null;
  role_code: RoleCode;
  role_label: string;
  access_scope_mode: AccessScopeMode;
  organization_id: string | null;
  organization_name: string | null;
  sites: ManagedUserSite[];
  is_active: boolean;
  created_at: string;
  updated_at: string;
  is_self: boolean;
};

export type RoleOption = {
  role_code: RoleCode;
  display_name: string;
  description: string;
  permissions: string[];
  assignable: boolean;
};

export type UserManagementOptions = {
  actor: {
    portal_user_id: number;
    role_code: RoleCode;
    access_scope_mode: AccessScopeMode;
    organization_id: string | null;
  };
  roles: RoleOption[];
  scopes: { access_scope_mode: AccessScopeMode; label: string }[];
  organizations: { organization_id: string; organization_name: string; organization_code: string }[];
  sites: { site_id: string; site_name: string; site_code: string; organization_id: string; organization_name: string }[];
  password_policy: { min_length: number; max_length: number };
};

export type AccessAssignment = {
  access_scope_mode: AccessScopeMode;
  organization_id: string | null;
  site_ids: string[];
};

export type CreateUserInput = {
  username: string;
  display_name: string;
  email: string;
  role_code: RoleCode;
  is_active: boolean;
  /** Omitted: the server generates a temporary password and returns it once. */
  password?: string;
} & AccessAssignment;

export type UpdateUserInput = Partial<
  { display_name: string; email: string; role_code: RoleCode; is_active: boolean } & AccessAssignment
>;

export type UserWithTemporaryPassword = { user: ManagedUser; temporary_password: string | null };

export function getUserManagementOptions(): Promise<UserManagementOptions> {
  return adminApiRequest("GET", "/users/options");
}

export function listManagedUsers(): Promise<{ users: ManagedUser[] }> {
  return adminApiRequest("GET", "/users");
}

export function getManagedUser(portalUserId: number): Promise<UserWithTemporaryPassword> {
  return adminApiRequest("GET", `/users/${encodeURIComponent(String(portalUserId))}`);
}

export function createManagedUser(input: CreateUserInput): Promise<UserWithTemporaryPassword> {
  return adminApiRequest("POST", "/users", input);
}

export function updateManagedUser(portalUserId: number, input: UpdateUserInput): Promise<UserWithTemporaryPassword> {
  return adminApiRequest("PATCH", `/users/${encodeURIComponent(String(portalUserId))}`, input);
}

export function resetManagedUserPassword(
  portalUserId: number,
  password?: string,
): Promise<{ portal_user_id: number; temporary_password: string | null }> {
  return adminApiRequest(
    "POST",
    `/users/${encodeURIComponent(String(portalUserId))}/password`,
    password ? { password } : {},
  );
}

export function changeOwnPassword(currentPassword: string, newPassword: string): Promise<void> {
  return adminApiRequest("POST", "/me/password", {
    current_password: currentPassword,
    new_password: newPassword,
  });
}

/** Plain-language access summary for tables and detail views. */
export function describeAccess(user: Pick<ManagedUser, "access_scope_mode" | "organization_name" | "sites">): string {
  if (user.access_scope_mode === "GLOBAL") return "All organizations";
  if (user.access_scope_mode === "ORGANIZATION") return "All sites";
  const names = user.sites.map((s) => s.site_name ?? s.site_code ?? s.site_id);
  return names.length === 0 ? "No sites" : names.join(", ");
}
