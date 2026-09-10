/**
 * Navigation model for the shell. Every item here is FOUNDATION-only: it is a
 * placeholder route, not a working feature. Permission codes gate VISIBILITY
 * (UX) only; the backend remains authoritative for access.
 *
 * `PLANNED_FEATURE_AREAS` is documentation the placeholder route renders so the
 * shell is honest about what does not exist yet.
 */

export type NavItem = {
  key: string;
  label: string;
  /** in-app path (client-side, under the /app basename) */
  to: string;
  /** any-of these permissions required to SEE the item; empty = always shown */
  requiresAnyOf: readonly string[];
};

export const PRIMARY_NAV: readonly NavItem[] = [
  { key: "home", label: "Home", to: "/home", requiresAnyOf: ["dashboard.view"] },
  { key: "features", label: "Feature areas (later phases)", to: "/features", requiresAnyOf: ["dashboard.view"] },
];

/** Admin-only shell affordances (still placeholders in Phase 8). */
export const SECONDARY_NAV: readonly NavItem[] = [
  {
    key: "admin",
    label: "Administration (later phases)",
    to: "/features/admin",
    requiresAnyOf: ["organization.manage", "user.manage", "site.manage"],
  },
];

export const PLANNED_FEATURE_AREAS: readonly { key: string; label: string }[] = [
  { key: "site-overview", label: "Site overview" },
  { key: "space-environment", label: "Space environment (temperature / humidity / dew point)" },
  { key: "energy", label: "Energy consumption" },
];

export function visibleNav(items: readonly NavItem[], permissions: readonly string[]): NavItem[] {
  return items.filter(
    (item) => item.requiresAnyOf.length === 0 || item.requiresAnyOf.some((p) => permissions.includes(p)),
  );
}
