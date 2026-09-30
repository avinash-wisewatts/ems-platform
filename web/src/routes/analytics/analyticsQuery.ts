/**
 * Analytics v1 query model (F3): the draft the filter panel edits, the pure
 * rules applied to it, and the approved customer wording. No React, no
 * network -- see useAnalyticsState for the page state machine.
 *
 * Canonical source: docs/07-features/analytics/README.md "User experience"
 * (ADR-022 Amendments 2, 3, 5, 6). Decision numbers are the Product Owner's.
 */
import type {
  AnalyticsCatalogResponse,
  AnalyticsDataPointCode,
  AnalyticsPhase,
  AnalyticsRequestedResolution,
  AnalyticsResolutionCode,
} from "../../api/types";
import type { AnalyticsSelection } from "../../api/endpoints";
import { calendarRange, type CalendarPreset, type CalendarRange } from "../../time/calendarRanges";

// ---- Approved wording (D48, D78, D80, D68) -----------------------------------

export const MESSAGES = {
  selectAssetAndDataPoint: "Select at least one asset and one data point to update the chart.",
  selectDataPoint: "Select at least one data point to update the chart.",
  selectAsset: "Select at least one asset to update the chart.",
  tooManySeries: "You can display up to 25 series at a time. Reduce your selections and try again.",
  updateFailed: "Unable to load selected data. Please try again.",
  changesNotApplied: "Changes not applied",
  resolutionChangedToAuto: "Resolution changed to Auto because the selected resolution is not available for this range.",
  emptyStateTitle: "Select data to explore",
  emptyStateDetail: "Choose an asset and data point to get started.",
} as const;

// ---- Limits (ADR-022 decision 7; D5, D70) ------------------------------------

export type AnalyticsLimitValues = { maxAssets: number; maxDataPoints: number; maxSeries: number };

/** The documented limits, used until the catalogue (which returns them) has loaded. */
export const DEFAULT_LIMITS: AnalyticsLimitValues = { maxAssets: 10, maxDataPoints: 5, maxSeries: 25 };

export function limitsFrom(catalog: AnalyticsCatalogResponse | null): AnalyticsLimitValues {
  if (!catalog) return DEFAULT_LIMITS;
  return {
    maxAssets: catalog.limits.max_assets,
    maxDataPoints: catalog.limits.max_data_points,
    maxSeries: catalog.limits.max_series,
  };
}

// ---- Draft query -------------------------------------------------------------

/** F3 holds a quick-range preset; the custom date/time range is F4's date picker. */
export type AnalyticsRangeSelection = { kind: "preset"; preset: CalendarPreset };

export type AnalyticsDraft = {
  range: AnalyticsRangeSelection;
  resolution: AnalyticsRequestedResolution;
  phase: AnalyticsPhase;
  /** In selection order (D6/DQ9 order Series not shown by selection). */
  assetIds: string[];
  /** Semantic data points, in selection order. */
  dataPoints: AnalyticsDataPointCode[];
};

/** Every visit and every site change starts here (D1, D3, D35, D56, D69). */
export const INITIAL_DRAFT: AnalyticsDraft = {
  range: { kind: "preset", preset: "TODAY" },
  resolution: "auto",
  phase: "system",
  assetIds: [],
  dataPoints: [],
};

export function draftsEqual(a: AnalyticsDraft, b: AnalyticsDraft): boolean {
  return (
    a.range.kind === b.range.kind &&
    a.range.preset === b.range.preset &&
    a.resolution === b.resolution &&
    a.phase === b.phase &&
    a.assetIds.length === b.assetIds.length &&
    a.assetIds.every((id, i) => id === b.assetIds[i]) &&
    a.dataPoints.length === b.dataPoints.length &&
    a.dataPoints.every((dp, i) => dp === b.dataPoints[i])
  );
}

/** The absolute calendar range of a draft in the site's timezone (F1, D8/D61/D62). */
export function resolveDraftRange(
  range: AnalyticsRangeSelection,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): CalendarRange {
  return calendarRange(range.preset, timeZone, now);
}

// ---- Selections --------------------------------------------------------------

export type SelectionPlan = {
  /** Catalogue-supported (asset, data point) pairs to request, assets in
   *  selection order, then data points in selection order. */
  selections: AnalyticsSelection[];
  /** Selected combinations the catalogue cannot serve. Not requested; reported
   *  under "Series not shown" as not available (D4). */
  unavailable: AnalyticsSelection[];
};

/**
 * Assets and data points are selected independently (D4, D42, D43); every
 * combination is considered. Only the pairs the catalogue serves are
 * requested -- the server never forms a cross-product itself (ADR-022
 * decision 14) and counts every selection it receives toward its 25-series
 * limit.
 */
export function planSelections(draft: AnalyticsDraft, catalog: AnalyticsCatalogResponse | null): SelectionPlan {
  const served = new Set<string>();
  for (const asset of catalog?.assets ?? []) {
    for (const point of asset.data_points) served.add(`${asset.asset_id}:${point.data_point}`);
  }
  const plan: SelectionPlan = { selections: [], unavailable: [] };
  for (const assetId of draft.assetIds) {
    for (const dataPoint of draft.dataPoints) {
      const selection = { assetId, dataPoint };
      (served.has(`${assetId}:${dataPoint}`) ? plan.selections : plan.unavailable).push(selection);
    }
  }
  return plan;
}

/** Rendered series after phase expansion (D70): 3 per pair under 3 Phase where
 *  the catalogue has per-phase values for it, otherwise 1 (System, D57). */
export function renderedSeriesCount(
  selections: AnalyticsSelection[],
  phase: AnalyticsPhase,
  catalog: AnalyticsCatalogResponse | null,
): number {
  if (phase === "system") return selections.length;
  const threePhase = new Set<string>();
  for (const asset of catalog?.assets ?? []) {
    for (const point of asset.data_points) {
      if (point.phases.three_phase) threePhase.add(`${asset.asset_id}:${point.data_point}`);
    }
  }
  return selections.reduce((n, s) => n + (threePhase.has(`${s.assetId}:${s.dataPoint}`) ? 3 : 1), 0);
}

/** The validation message for an Update, or null when it may be sent (D45, D46, D48, D78). */
export function validateForUpdate(draft: AnalyticsDraft, catalog: AnalyticsCatalogResponse | null): string | null {
  if (draft.assetIds.length === 0 && draft.dataPoints.length === 0) return MESSAGES.selectAssetAndDataPoint;
  if (draft.dataPoints.length === 0) return MESSAGES.selectDataPoint;
  if (draft.assetIds.length === 0) return MESSAGES.selectAsset;
  const { selections } = planSelections(draft, catalog);
  if (renderedSeriesCount(selections, draft.phase, catalog) > limitsFrom(catalog).maxSeries) {
    return MESSAGES.tooManySeries;
  }
  return null;
}

// ---- Resolution availability (EMS-REQ-134, D9/D68) ---------------------------

/** A resolution is available for a range when the range fits its maximum
 *  window. Auto is always available (the server resolves it, floor-aware). */
export function isResolutionAvailable(
  resolution: AnalyticsRequestedResolution,
  range: CalendarRange,
  catalog: AnalyticsCatalogResponse | null,
): boolean {
  if (resolution === "auto" || !catalog) return true;
  const window = catalog.resolutions.find((r) => r.resolution === (resolution as AnalyticsResolutionCode));
  if (!window) return false;
  return (Date.parse(range.to) - Date.parse(range.from)) / 1000 <= window.max_window_seconds;
}
