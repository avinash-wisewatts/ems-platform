/**
 * Grouping for the Analytics selectors (F4) -- pure, no React.
 *
 * Assets (D37, D38, D65, D71, D72): Group by Space (default) or Group by Asset
 * Type. Named groups sorted by name; assets without a Space in "Unassigned"
 * and without an Asset Type in "Other", both at the bottom (PO 2026-09-30 for
 * "Other"). Assets sorted by name within a group. The resulting order is the
 * "current visual order" used for bulk selection (D44, D65).
 *
 * Data points (D39, D40, D41, D59, D66, D67, D75): organizational groups only,
 * in the recorded order; a group appears only where the catalogue has points
 * for it. Frequently Used repeats points shown in their own group -- selecting
 * one selects the same underlying data point.
 */
import type { AnalyticsCatalogAsset, AnalyticsCatalogResponse, AnalyticsDataPoint } from "../../api/types";

export type AssetGrouping = "space" | "assetType";

export type AssetGroup = { key: string; name: string; assets: AnalyticsCatalogAsset[] };

const byName = (a: string, b: string) => a.localeCompare(b, undefined, { sensitivity: "base", numeric: true });

export const UNASSIGNED_GROUP = "Unassigned";
export const OTHER_GROUP = "Other";

export function groupAssets(assets: readonly AnalyticsCatalogAsset[], grouping: AssetGrouping, search = ""): AssetGroup[] {
  const needle = search.trim().toLocaleLowerCase();
  const visible = needle ? assets.filter((a) => a.asset_name.toLocaleLowerCase().includes(needle)) : [...assets];
  const named = new Map<string, AssetGroup>();
  const fallback: AssetGroup = {
    key: grouping === "space" ? "__unassigned" : "__other",
    name: grouping === "space" ? UNASSIGNED_GROUP : OTHER_GROUP,
    assets: [],
  };
  for (const asset of visible) {
    const id = grouping === "space" ? asset.space_id : asset.asset_type_id;
    const name = grouping === "space" ? asset.space_name : asset.asset_type_name;
    if (!id || !name) {
      fallback.assets.push(asset);
      continue;
    }
    const group = named.get(id) ?? { key: id, name, assets: [] };
    group.assets.push(asset);
    named.set(id, group);
  }
  const groups = [...named.values()].sort((a, b) => byName(a.name, b.name));
  if (fallback.assets.length > 0) groups.push(fallback);
  for (const group of groups) group.assets.sort((a, b) => byName(a.asset_name, b.asset_name));
  return groups;
}

/** Asset ids in visual order (every visible group, top to bottom). */
export function visualOrder(groups: readonly AssetGroup[]): string[] {
  return groups.flatMap((g) => g.assets.map((a) => a.asset_id));
}

/**
 * Add `candidates` to `selected` in the given (visual) order until `max` is
 * reached; returns the new selection (existing selections keep their place)
 * and whether some candidates were left out (D44, D65).
 */
export function fillToLimit(
  selected: readonly string[],
  candidates: readonly string[],
  max: number,
): { selection: string[]; limited: boolean } {
  const selection = [...selected];
  let limited = false;
  for (const id of candidates) {
    if (selection.includes(id)) continue;
    if (selection.length >= max) {
      limited = true;
      break;
    }
    selection.push(id);
  }
  return { selection, limited };
}

// ---- Data points ---------------------------------------------------------------

/** The recorded group order (D40, D67). */
export const DATA_POINT_GROUP_ORDER = [
  "Frequently Used",
  "Power",
  "Input/Output",
  "Environmental",
  "Conversion",
  "Misc/Other",
] as const;
export type DataPointGroupName = (typeof DATA_POINT_GROUP_ORDER)[number];

/**
 * Platform parameter code (config.parameters) -> its D67 groups (as revised
 * by D75). Frequently Used is the fixed, non-personalised WiseWatts list
 * (Current, Energy, Power, Power Factor, Voltage); an item that also belongs
 * to another group is the same underlying data point there. The selector shows every data point the site catalogue returns;
 * this table only decides where each one is listed. It covers every platform
 * parameter whose D67 placement is unambiguous:
 * - Frequently Used: CURRENT (Current), ENERGY_IMPORT (Energy, also in
 *   Power), POWER_FACTOR (Power Factor), VOLTAGE_LINE_NEUTRAL (Voltage). The
 *   Frequently Used item "Power" (active power) has no platform parameter yet.
 * - Power: ENERGY_EXPORT, APPARENT_ENERGY, APPARENT_POWER, FREQUENCY,
 *   REACTIVE_POWER, VOLTAGE_LINE_LINE (Line to Line Voltage).
 * - Environmental: TEMPERATURE, HUMIDITY (Relative Humidity), ILLUMINANCE
 *   (Light Level).
 * - Misc/Other: BATTERY_VOLTAGE.
 * Codes with no unambiguous D67 item (CURRENT_THD, PHASE_ANGLE, DEW_POINT,
 * OCCUPANCY_ACTIVITY, OCCUPANCY_TIME_SINCE_LAST_EVENT) and codes added later
 * are listed under Misc/Other, so a catalogue point is never hidden. The v1
 * registry serves only ENERGY_IMPORT and ENERGY_EXPORT (ADR-022 decision 3).
 */
export const DATA_POINT_GROUPS: Readonly<Record<string, readonly DataPointGroupName[]>> = {
  CURRENT: ["Frequently Used"],
  ENERGY_IMPORT: ["Frequently Used", "Power"],
  POWER_FACTOR: ["Frequently Used"],
  VOLTAGE_LINE_NEUTRAL: ["Frequently Used"],
  ENERGY_EXPORT: ["Power"],
  APPARENT_ENERGY: ["Power"],
  APPARENT_POWER: ["Power"],
  FREQUENCY: ["Power"],
  REACTIVE_POWER: ["Power"],
  VOLTAGE_LINE_LINE: ["Power"],
  TEMPERATURE: ["Environmental"],
  HUMIDITY: ["Environmental"],
  ILLUMINANCE: ["Environmental"],
  BATTERY_VOLTAGE: ["Misc/Other"],
};

export type DataPointOption = { code: string; label: string };
export type DataPointGroup = { name: DataPointGroupName; points: DataPointOption[] };

/** Every data point in the site catalogue (independent of the selected assets, D42). */
export function siteDataPoints(catalog: AnalyticsCatalogResponse | null): DataPointOption[] {
  const byCode = new Map<string, AnalyticsDataPoint>();
  for (const asset of catalog?.assets ?? []) {
    for (const point of asset.data_points) if (!byCode.has(point.data_point)) byCode.set(point.data_point, point);
  }
  return [...byCode.values()].map((p) => ({ code: p.data_point, label: p.label }));
}

export function groupDataPoints(points: readonly DataPointOption[], search = ""): DataPointGroup[] {
  const needle = search.trim().toLocaleLowerCase();
  const visible = needle ? points.filter((p) => p.label.toLocaleLowerCase().includes(needle)) : points;
  return DATA_POINT_GROUP_ORDER.map((name) => ({
    name,
    points: visible
      .filter((p) => (DATA_POINT_GROUPS[p.code] ?? ["Misc/Other"]).includes(name))
      .sort((a, b) => byName(a.label, b.label)),
  })).filter((g) => g.points.length > 0);
}

/** Data point codes in visual order, each once (Frequently Used first). */
export function dataPointVisualOrder(groups: readonly DataPointGroup[]): string[] {
  const order: string[] = [];
  for (const group of groups) for (const p of group.points) if (!order.includes(p.code)) order.push(p.code);
  return order;
}
