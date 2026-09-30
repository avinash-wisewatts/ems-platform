/**
 * Analytics page state (F3): the draft the filters edit, the query last
 * applied by a successful Update, and the request lifecycle.
 *
 * Rules (docs/07-features/analytics/README.md "User experience"):
 * - Every visit and every site change starts fresh; nothing is persisted
 *   (D1, D3, D35, D56, D69).
 * - Nothing reloads until Update (EMS-REQ-133). Update is enabled whenever
 *   there are unapplied changes, shown as "Changes not applied" (D46, D47).
 * - Update validates before any request and shows one message (D45, D48,
 *   D78); a failed validation keeps the selections (D49).
 * - While loading, the previous result stays until the new one is ready (D7).
 * - A failed request keeps the previous result and the selections and shows
 *   "Unable to load selected data. Please try again." (D50, D80).
 * - Assets (10) and data points (5) are hard-stopped while selecting (D5).
 */
import { useCallback, useEffect, useReducer, useRef } from "react";
import { getAnalyticsSeries, type AnalyticsSelection } from "../../api/endpoints";
import type {
  AnalyticsCatalogResponse,
  AnalyticsDataPointCode,
  AnalyticsPhase,
  AnalyticsRequestedResolution,
  AnalyticsSeriesResponse,
} from "../../api/types";
import type { CalendarRange } from "../../time/calendarRanges";
import {
  INITIAL_DRAFT,
  MESSAGES,
  draftsEqual,
  isResolutionAvailable,
  limitsFrom,
  planSelections,
  resolveDraftRange,
  validateForUpdate,
  type AnalyticsDraft,
  type AnalyticsRangeSelection,
} from "./analyticsQuery";

/** The result of the last successful Update. */
export type AppliedQuery = {
  draft: AnalyticsDraft;
  range: CalendarRange;
  selections: AnalyticsSelection[];
  /** Selected combinations the catalogue cannot serve (D4) -- never requested. */
  unavailable: AnalyticsSelection[];
  /** Null when no selected combination could be requested. */
  response: AnalyticsSeriesResponse | null;
};

export type AnalyticsState = {
  draft: AnalyticsDraft;
  applied: AppliedQuery | null;
  loading: boolean;
  validationMessage: string | null;
  errorMessage: string | null;
  /** D68 notice, shown until the range or resolution changes again. */
  resolutionNotice: string | null;
};

export const INITIAL_STATE: AnalyticsState = {
  draft: INITIAL_DRAFT,
  applied: null,
  loading: false,
  validationMessage: null,
  errorMessage: null,
  resolutionNotice: null,
};

export type AnalyticsAction =
  | { type: "reset" }
  | { type: "toggleAsset"; assetId: string; maxAssets: number }
  | { type: "setAssets"; assetIds: string[]; maxAssets: number }
  | { type: "toggleDataPoint"; dataPoint: AnalyticsDataPointCode; maxDataPoints: number }
  | { type: "setDataPoints"; dataPoints: AnalyticsDataPointCode[]; maxDataPoints: number }
  | { type: "setPhase"; phase: AnalyticsPhase }
  | { type: "setResolution"; resolution: AnalyticsRequestedResolution }
  | { type: "setRange"; range: AnalyticsRangeSelection; resolutionAvailable: boolean }
  | { type: "validationFailed"; message: string }
  | { type: "requestStarted" }
  | { type: "requestSucceeded"; applied: AppliedQuery }
  | { type: "requestFailed" };

function toggle<T>(list: T[], item: T, max: number): T[] {
  if (list.includes(item)) return list.filter((x) => x !== item);
  return list.length >= max ? list : [...list, item];
}

function unique<T>(list: T[]): T[] {
  return list.filter((x, i) => list.indexOf(x) === i);
}

function withDraft(state: AnalyticsState, draft: AnalyticsDraft): AnalyticsState {
  // A changed draft makes a previous validation message stale.
  return { ...state, draft, validationMessage: null };
}

export function analyticsReducer(state: AnalyticsState, action: AnalyticsAction): AnalyticsState {
  switch (action.type) {
    case "reset":
      return INITIAL_STATE;
    case "toggleAsset":
      return withDraft(state, { ...state.draft, assetIds: toggle(state.draft.assetIds, action.assetId, action.maxAssets) });
    case "setAssets":
      return withDraft(state, { ...state.draft, assetIds: unique(action.assetIds).slice(0, action.maxAssets) });
    case "toggleDataPoint":
      return withDraft(state, {
        ...state.draft,
        dataPoints: toggle(state.draft.dataPoints, action.dataPoint, action.maxDataPoints),
      });
    case "setDataPoints":
      return withDraft(state, { ...state.draft, dataPoints: unique(action.dataPoints).slice(0, action.maxDataPoints) });
    case "setPhase":
      return withDraft(state, { ...state.draft, phase: action.phase });
    case "setResolution":
      return { ...withDraft(state, { ...state.draft, resolution: action.resolution }), resolutionNotice: null };
    case "setRange": {
      // D9/D68: a manually chosen resolution the new range cannot use switches
      // to Auto, with a small non-blocking notice.
      const switchToAuto = state.draft.resolution !== "auto" && !action.resolutionAvailable;
      return {
        ...withDraft(state, {
          ...state.draft,
          range: action.range,
          resolution: switchToAuto ? "auto" : state.draft.resolution,
        }),
        resolutionNotice: switchToAuto ? MESSAGES.resolutionChangedToAuto : null,
      };
    }
    case "validationFailed":
      return { ...state, validationMessage: action.message };
    case "requestStarted":
      return { ...state, loading: true, validationMessage: null, errorMessage: null };
    case "requestSucceeded":
      return { ...state, loading: false, applied: action.applied, errorMessage: null };
    case "requestFailed":
      return { ...state, loading: false, errorMessage: MESSAGES.updateFailed };
  }
}

/** Whether the draft differs from what the chart shows (or, before any
 *  Update, from the fresh starting state). */
export function hasUnappliedChanges(state: AnalyticsState): boolean {
  return !draftsEqual(state.draft, state.applied ? state.applied.draft : INITIAL_DRAFT);
}

export type UseAnalyticsState = {
  state: AnalyticsState;
  hasUnappliedChanges: boolean;
  toggleAsset: (assetId: string) => void;
  setAssets: (assetIds: string[]) => void;
  toggleDataPoint: (dataPoint: AnalyticsDataPointCode) => void;
  setDataPoints: (dataPoints: AnalyticsDataPointCode[]) => void;
  setPhase: (phase: AnalyticsPhase) => void;
  setResolution: (resolution: AnalyticsRequestedResolution) => void;
  setRange: (range: AnalyticsRangeSelection) => void;
  update: () => void;
};

export function useAnalyticsState({
  siteId,
  timeZone,
  catalog,
  now = () => new Date(),
}: {
  siteId: string | null;
  timeZone: string | null | undefined;
  catalog: AnalyticsCatalogResponse | null;
  /** Clock injection for tests. */
  now?: () => Date;
}): UseAnalyticsState {
  const [state, dispatch] = useReducer(analyticsReducer, INITIAL_STATE);
  // Only the latest request may land; a site change invalidates in-flight ones.
  const requestSeq = useRef(0);

  useEffect(() => {
    requestSeq.current += 1;
    dispatch({ type: "reset" });
  }, [siteId]);

  const limits = limitsFrom(catalog);

  const setRange = useCallback(
    (range: AnalyticsRangeSelection) => {
      const absolute = resolveDraftRange(range, timeZone, now());
      dispatch({
        type: "setRange",
        range,
        resolutionAvailable: isResolutionAvailable(state.draft.resolution, absolute, catalog),
      });
    },
    [timeZone, now, state.draft.resolution, catalog],
  );

  const update = useCallback(() => {
    if (!siteId) return;
    const message = validateForUpdate(state.draft, catalog);
    if (message !== null) {
      dispatch({ type: "validationFailed", message });
      return;
    }
    const draft = state.draft;
    const range = resolveDraftRange(draft.range, timeZone, now());
    const { selections, unavailable } = planSelections(draft, catalog);
    const seq = ++requestSeq.current;
    dispatch({ type: "requestStarted" });

    const request =
      selections.length === 0
        ? Promise.resolve(null)
        : getAnalyticsSeries(siteId, {
            from: range.from,
            to: range.to,
            resolution: draft.resolution,
            phase: draft.phase,
            selections,
          });
    request
      .then((response) => {
        if (seq !== requestSeq.current) return;
        dispatch({ type: "requestSucceeded", applied: { draft, range, selections, unavailable, response } });
      })
      .catch(() => {
        if (seq !== requestSeq.current) return;
        dispatch({ type: "requestFailed" });
      });
  }, [siteId, state.draft, catalog, timeZone, now]);

  return {
    state,
    hasUnappliedChanges: hasUnappliedChanges(state),
    toggleAsset: (assetId) => dispatch({ type: "toggleAsset", assetId, maxAssets: limits.maxAssets }),
    setAssets: (assetIds) => dispatch({ type: "setAssets", assetIds, maxAssets: limits.maxAssets }),
    toggleDataPoint: (dataPoint) =>
      dispatch({ type: "toggleDataPoint", dataPoint, maxDataPoints: limits.maxDataPoints }),
    setDataPoints: (dataPoints) =>
      dispatch({ type: "setDataPoints", dataPoints, maxDataPoints: limits.maxDataPoints }),
    setPhase: (phase) => dispatch({ type: "setPhase", phase }),
    setResolution: (resolution) => dispatch({ type: "setResolution", resolution }),
    setRange,
    update,
  };
}
