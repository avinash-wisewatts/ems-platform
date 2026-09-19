/**
 * Navigation model for the shell. Every item here is FOUNDATION-only: it is a
 * placeholder route, not a working feature. Permission codes gate VISIBILITY
 * (UX) only; the backend remains authoritative for access.
 *
 * `PLANNED_FEATURE_AREAS` is documentation the placeholder route renders so the
 * shell is honest about what does not exist yet.
 *
 * IA correction (MVP-1 closeout): Energy / Demand / Power Quality are
 * capabilities of the current Site, not unrelated global destinations, and
 * Spaces / Assets are the Site -> Space -> Asset drill-down levels beneath
 * it -- per the agreed IA (docs/product/ems-product-owner-workshop-baseline.md
 * Q69/Q101: "Where" = Portfolio -> Site -> Space -> Asset; "What" = Overview
 * -> Energy -> Demand -> Power Quality -> Performance -> Attention). `group`
 * records that distinction for rendering; it changes no route (`to`) and no
 * `key`, so it carries no risk to the Slice A/B/C screens or their tests.
 */

export type NavGroup = "site" | "hierarchy";

export type NavItem = {
  key: string;
  label: string;
  /** in-app path (client-side, under the /app basename) */
  to: string;
  /** any-of these permissions required to SEE the item; empty = always shown */
  requiresAnyOf: readonly string[];
  /** Where this item sits in the agreed IA; undefined = not yet part of it
   *  (rendered without a section heading, e.g. the later-phases catch-all). */
  group?: NavGroup;
};

export const NAV_GROUP_LABELS: Record<NavGroup, string> = {
  site: "Site",
  hierarchy: "Spaces & Assets",
};

export const PRIMARY_NAV: readonly NavItem[] = [
  { key: "home", label: "Overview", to: "/home", requiresAnyOf: ["dashboard.view"], group: "site" },
  { key: "energy", label: "Energy", to: "/features/energy", requiresAnyOf: ["dashboard.view"], group: "site" },
  { key: "demand", label: "Demand", to: "/features/demand", requiresAnyOf: ["dashboard.view"], group: "site" },
  {
    key: "power-quality",
    label: "Power Quality",
    to: "/features/power-quality",
    requiresAnyOf: ["dashboard.view"],
    group: "site",
  },
  {
    key: "reports",
    label: "Reports",
    to: "/features/reports",
    requiresAnyOf: ["dashboard.view"],
    group: "site",
  },
  {
    key: "alerts",
    label: "Alerts",
    to: "/features/alerts",
    requiresAnyOf: ["dashboard.view"],
    group: "site",
  },
  { key: "spaces", label: "Spaces", to: "/features/spaces", requiresAnyOf: ["dashboard.view"], group: "hierarchy" },
  { key: "assets", label: "Assets", to: "/features/assets", requiresAnyOf: ["dashboard.view"], group: "hierarchy" },
  { key: "features", label: "Other feature areas (later phases)", to: "/features", requiresAnyOf: ["dashboard.view"] },
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

/** MVP-3: Site Overview shipped -- removed from the planned list. Nothing
 *  else exists yet, so this is empty for now, not deleted (PlaceholderArea
 *  keeps rendering it honestly as later screens are added here). */
export const PLANNED_FEATURE_AREAS: readonly { key: string; label: string }[] = [];

export function visibleNav(items: readonly NavItem[], permissions: readonly string[]): NavItem[] {
  return items.filter(
    (item) => item.requiresAnyOf.length === 0 || item.requiresAnyOf.some((p) => permissions.includes(p)),
  );
}

/**
 * WiseWatts dashboard redesign -- the new primary shell navigation shown at
 * the top of the sidebar. Deliberately a SEPARATE list from PRIMARY_NAV/
 * SECONDARY_NAV above, which are untouched and keep rendering exactly as
 * before, just relocated into a bottom "Archive" section by AppShell so nothing
 * already shipped is deleted or broken.
 *
 * "Asset View" points at routes/assetView/AssetView.tsx, its own real
 * screen (the earlier placeholder reuse of AssetsList was superseded once
 * the real Asset View was built -- AssetsList itself is untouched and still
 * exists, just no longer linked from primary nav). "Alerts" still reuses
 * the already-implemented AlertsArea screen under its existing /features/*
 * route -- no duplicate screen is built. "Analytics", "Single Line Diagram"
 * and "Settings" have no implementation yet, so they route into the
 * existing, honest /features/* catch-all (PlaceholderArea) exactly like
 * every other not-yet-built feature area -- never a fabricated screen.
 */
export const SHELL_PRIMARY_NAV: readonly NavItem[] = [
  {
    key: "main-dashboard",
    label: "Main Dashboard",
    to: "/dashboard",
    requiresAnyOf: ["dashboard.view"],
  },
  { key: "asset-view", label: "Asset View", to: "/asset-view", requiresAnyOf: ["dashboard.view"] },
  { key: "analytics", label: "Analytics", to: "/features/analytics", requiresAnyOf: ["dashboard.view"] },
  {
    key: "single-line-diagram",
    label: "Single Line Diagram",
    to: "/features/single-line-diagram",
    requiresAnyOf: ["dashboard.view"],
  },
  { key: "shell-alerts", label: "Alerts", to: "/features/alerts", requiresAnyOf: ["dashboard.view"] },
  { key: "settings", label: "Settings", to: "/features/settings", requiresAnyOf: ["dashboard.view"] },
];

export type NavSection = {
  /** undefined for the trailing, not-yet-grouped items (e.g. "features"). */
  group: NavGroup | undefined;
  items: NavItem[];
};

/**
 * Partitions an already-visibility-filtered nav list into contiguous
 * sections by `group`, preserving item order. Does not reorder, add, or
 * remove items -- purely a rendering split so the shell can show a "Site"
 * heading over Energy/Demand/Power Quality and a separate heading over
 * Spaces/Assets, matching the agreed IA.
 */
export function groupNav(items: readonly NavItem[]): NavSection[] {
  const sections: NavSection[] = [];
  for (const item of items) {
    const last = sections[sections.length - 1];
    if (last && last.group === item.group) {
      last.items.push(item);
    } else {
      sections.push({ group: item.group, items: [item] });
    }
  }
  return sections;
}
