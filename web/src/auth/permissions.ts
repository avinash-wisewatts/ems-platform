/**
 * Frontend permission helpers.
 *
 * These gate NAVIGATION and UX ONLY. They are not a security boundary. The
 * backend (session middleware + admin.portal_user_has_permission + the Phase 7
 * SECURITY DEFINER functions) remains authoritative for authentication,
 * organization access, site access, space access, and tenant isolation.
 * Organization / site / space IDs from the browser are never trusted.
 */

import type { CurrentUser } from "../api/types";

/** The one permission the Phase 8 shell itself requires; held by every role. */
export const SHELL_MINIMUM_PERMISSION = "dashboard.view";

export function hasPermission(user: Pick<CurrentUser, "permissions"> | null, code: string): boolean {
  return !!user && user.permissions.includes(code);
}

export function hasAnyPermission(
  user: Pick<CurrentUser, "permissions"> | null,
  codes: readonly string[],
): boolean {
  return codes.some((c) => hasPermission(user, c));
}

/** Can this identity use the Phase 8 shell at all? */
export function canUseShell(user: Pick<CurrentUser, "permissions"> | null): boolean {
  return hasPermission(user, SHELL_MINIMUM_PERMISSION);
}
