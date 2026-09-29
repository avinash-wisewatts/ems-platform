/**
 * Shared time-range abstraction.
 *
 * Users pick meaningful ranges (Today, 7 Days, ...). This module is the ONLY
 * place that translates a preset into what the Phase 7 API actually accepts:
 * an explicit { from, to } (ISO-8601 UTC, half-open) and an explicit
 * `resolution`. No database / CAGG terminology is ever shown to users.
 *
 * The Phase 7 first slice cannot represent every preset for every data kind
 * (space measurements have no resolution beyond 1h, capped at 31 days). Those
 * cases are reported as "unsupported" here and handled cleanly by the UI --
 * the API is NOT expanded to satisfy the frontend.
 */

import type { EnergyResolution, MeasurementResolution, PowerQualityResolution } from "../api/types";
import { CALENDAR_PRESETS, calendarDayCount, calendarRange, localDateKey, localMidnightUtc } from "./calendarRanges";

export const TIME_RANGE_PRESETS = CALENDAR_PRESETS;
export type TimeRangePreset = (typeof TIME_RANGE_PRESETS)[number];

export const PRESET_LABELS: Record<TimeRangePreset, string> = {
  TODAY: "Today",
  "7D": "7 Days",
  "30D": "30 Days",
  "3M": "3 Months",
  "1Y": "1 Year",
};

/**
 * Slice B (A1): widened to reserve "demand" and "power-quality" for the
 * Demand and Power Quality screens. Deliberately minimal for this increment
 * -- the corresponding planDemandRequest/planPowerQualityRequest functions
 * (and isPresetSupported's dispatch for them) are added in Phase 2/3 once
 * the real resolution caps are known from the actual backend functions
 * (B1/D1), not guessed here.
 */
export type DataKind = "measurement" | "energy" | "demand" | "power-quality";

export type AbsoluteRange = { from: string; to: string };

const DAY_MS = 86_400_000;

/**
 * Resolve a preset to its half-open calendar range in the site's timezone:
 * local midnight of the first day to the EXCLUSIVE next local midnight after
 * today (application-wide calendar semantics, ADR-022 Amendment 5, D61/D62;
 * see ./calendarRanges). `timeZone` is the site's IANA timezone; null or
 * undefined falls back to UTC.
 */
export function resolveRange(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): AbsoluteRange {
  return calendarRange(preset, timeZone, now);
}

// Phase 7 caps (seconds). Kept in sync with analytics_api_service.py.
// Backend follow-up (Product Owner, 2026-09-29): the calendar 1 Year preset
// spans 367 days when it contains 29 February, over the 366-day "1d" caps
// below. The API limit is to be extended to 367 days before 29 Feb 2028; until
// then such a range is reported as not served, never shortened (see
// docs/07-features/energy/README.md, Known limitations).
// Exported (MVP-6, Site Performance Report) so the report's own
// arbitrary-range planning (sitePerformanceReportRanges.ts) can reuse the
// exact same, already-enforced caps instead of duplicating the numbers --
// no new threshold is introduced by exporting these unchanged constants.
export const MEASUREMENT_MAX_WINDOW_S: Record<MeasurementResolution, number> = {
  raw: 24 * 3600,
  "1h": 31 * 86400,
};
export const ENERGY_MAX_WINDOW_S: Record<EnergyResolution, number> = {
  "1h": 31 * 86400,
  "1d": 366 * 86400,
  // "1w"/"1mo"/"1y" (migration 248) are server-side aggregations of the
  // same "1d" historian -- a separate, generous engineering safety
  // backstop (ENERGY_PERIODIC_RESOLUTION_MAX_WINDOW in
  // analytics_api_service.py), not a product-facing availability limit.
  // The Main Dashboard Energy Usage chart's own selectable-range decision
  // is made entirely from GET .../energy/consumption/availability
  // (migration 247), never from this cap.
  "1w": 3660 * 86400,
  "1mo": 3660 * 86400,
  "1y": 3660 * 86400,
};

// Slice B caps -- kept in sync with analytics_api_service.py's
// DEMAND_MAX_WINDOW / POWER_QUALITY_RESOLUTION_MAX_WINDOW.
export const DEMAND_MAX_WINDOW_S = 31 * 86400;
export const POWER_QUALITY_MAX_WINDOW_S: Record<PowerQualityResolution, number> = {
  "15min": 7 * 86400,
  "1h": 31 * 86400,
  "1d": 366 * 86400,
};

export type MeasurementPlan = {
  supported: true;
  resolution: MeasurementResolution;
  range: AbsoluteRange;
};
export type EnergyPlan = {
  supported: true;
  resolution: EnergyResolution;
  range: AbsoluteRange;
};
/** No `resolution` field -- analytics.demand_intervals has no coarser
 *  persisted tier to select between (see analytics_api_service.py). */
export type DemandPlan = {
  supported: true;
  range: AbsoluteRange;
};
export type PowerQualityPlan = {
  supported: true;
  resolution: PowerQualityResolution;
  range: AbsoluteRange;
};
export type UnsupportedPlan = {
  supported: false;
  reason: string;
};

/** Exported (MVP-6) for reuse by sitePerformanceReportRanges.ts's
 *  arbitrary-range planning -- unchanged behavior for every existing caller. */
export function windowSeconds(range: AbsoluteRange): number {
  return (Date.parse(range.to) - Date.parse(range.from)) / 1000;
}

/** How to request space measurements for a preset, or why it can't be. */
export function planMeasurementRequest(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): MeasurementPlan | UnsupportedPlan {
  const range = resolveRange(preset, timeZone, now);
  const span = windowSeconds(range);
  const resolution: MeasurementResolution = span <= MEASUREMENT_MAX_WINDOW_S.raw ? "raw" : "1h";
  if (span > MEASUREMENT_MAX_WINDOW_S[resolution]) {
    return {
      supported: false,
      reason: `The "${PRESET_LABELS[preset]}" range is longer than the analytics API currently serves for environmental measurements (max 30 days). Choose a shorter range.`,
    };
  }
  return { supported: true, resolution, range };
}

/** How to request site energy consumption for a preset, or why it can't be. */
export function planEnergyRequest(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): EnergyPlan | UnsupportedPlan {
  const range = resolveRange(preset, timeZone, now);
  const span = windowSeconds(range);
  const resolution: EnergyResolution = span <= ENERGY_MAX_WINDOW_S["1h"] ? "1h" : "1d";
  if (span > ENERGY_MAX_WINDOW_S[resolution]) {
    return {
      supported: false,
      reason: `The "${PRESET_LABELS[preset]}" range is longer than the analytics API currently serves.`,
    };
  }
  return { supported: true, resolution, range };
}

/** How to request site demand for a preset, or why it can't be. No
 *  resolution to choose -- see DemandPlan. */
export function planDemandRequest(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): DemandPlan | UnsupportedPlan {
  const range = resolveRange(preset, timeZone, now);
  const span = windowSeconds(range);
  if (span > DEMAND_MAX_WINDOW_S) {
    return {
      supported: false,
      reason: `The "${PRESET_LABELS[preset]}" range is longer than the analytics API currently serves for demand.`,
    };
  }
  return { supported: true, range };
}

/** How to request site power quality for a preset, or why it can't be. */
export function planPowerQualityRequest(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): PowerQualityPlan | UnsupportedPlan {
  const range = resolveRange(preset, timeZone, now);
  const span = windowSeconds(range);
  const resolution: PowerQualityResolution =
    span <= POWER_QUALITY_MAX_WINDOW_S["15min"]
      ? "15min"
      : span <= POWER_QUALITY_MAX_WINDOW_S["1h"]
        ? "1h"
        : "1d";
  if (span > POWER_QUALITY_MAX_WINDOW_S[resolution]) {
    return {
      supported: false,
      reason: `The "${PRESET_LABELS[preset]}" range is longer than the analytics API currently serves for power quality.`,
    };
  }
  return { supported: true, resolution, range };
}

function planForKind(kind: DataKind, preset: TimeRangePreset, timeZone: string | null | undefined, now: Date) {
  switch (kind) {
    case "measurement":
      return planMeasurementRequest(preset, timeZone, now);
    case "demand":
      return planDemandRequest(preset, timeZone, now);
    case "power-quality":
      return planPowerQualityRequest(preset, timeZone, now);
    case "energy":
    default:
      return planEnergyRequest(preset, timeZone, now);
  }
}

/** Whether `kind` can serve `preset`. Support depends only on the range's
 *  length, which the site timezone changes by at most a DST hour; omitting it
 *  evaluates in UTC. */
export function isPresetSupported(
  preset: TimeRangePreset,
  kind: DataKind,
  now: Date = new Date(),
  timeZone: string | null | undefined = null,
): boolean {
  return planForKind(kind, preset, timeZone, now).supported;
}

// ---------------------------------------------------------------------------
// Slice A -- Energy comparison ranges.
//
// Per the approved MVP comparison model (Q54/Q56), this increment implements
// PREVIOUS_PERIOD and SAME_PERIOD_PREVIOUSLY only. Both are derived entirely
// client-side from the already-resolved current range -- NO new API
// endpoint, NO change to ENERGY_MAX_WINDOW_S.
//
// Slice C adds TYPICAL_HISTORICAL_REFERENCE below -- the approved
// comparable-period historical reference (median of up to 8 coverage-
// eligible comparable periods), computed server-side by migration 236 /
// GET .../energy/consumption/typical-reference. This REPLACES the earlier,
// provisional client-side "ROLLING_AVERAGE" (N=4 trailing mean) -- that
// code was never applied/shipped and is removed outright, not deprecated
// alongside the new implementation. Configured expectation (Q54-B) remains
// out of scope: no schema, no defined shape/owner exists for it.
// ---------------------------------------------------------------------------

export type ComparisonBasis = "PREVIOUS_PERIOD" | "SAME_PERIOD_PREVIOUSLY" | "TYPICAL_HISTORICAL_REFERENCE";

/**
 * The subset of ComparisonBasis that shiftRangeForComparison /
 * planEnergyComparisonRequest understand -- a single before/after shift.
 * TYPICAL_HISTORICAL_REFERENCE is deliberately excluded: its comparable
 * periods are selected server-side (migration 236), not by a client-side
 * shift, and must never be passed to these two functions.
 */
export type HistoricalShiftBasis = Extract<ComparisonBasis, "PREVIOUS_PERIOD" | "SAME_PERIOD_PREVIOUSLY">;

export const COMPARISON_BASIS_LABELS: Record<ComparisonBasis, string> = {
  PREVIOUS_PERIOD: "Previous period",
  SAME_PERIOD_PREVIOUSLY: "Same period, one year earlier",
  TYPICAL_HISTORICAL_REFERENCE: "Typical historical consumption",
};

/**
 * PREVIOUS_PERIOD: the immediately preceding window of equal length.
 * SAME_PERIOD_PREVIOUSLY: the same calendar window exactly one year earlier
 * (UTC calendar fields -- not merely a fixed millisecond shift, so month/day
 * boundaries stay meaningful).
 */
export function shiftRangeForComparison(range: AbsoluteRange, basis: HistoricalShiftBasis): AbsoluteRange {
  if (basis === "PREVIOUS_PERIOD") {
    const spanMs = Date.parse(range.to) - Date.parse(range.from);
    return {
      from: new Date(Date.parse(range.from) - spanMs).toISOString(),
      to: new Date(Date.parse(range.to) - spanMs).toISOString(),
    };
  }
  const shiftOneYear = (iso: string): string => {
    const d = new Date(iso);
    return new Date(
      Date.UTC(
        d.getUTCFullYear() - 1,
        d.getUTCMonth(),
        d.getUTCDate(),
        d.getUTCHours(),
        d.getUTCMinutes(),
        d.getUTCSeconds(),
      ),
    ).toISOString();
  };
  return { from: shiftOneYear(range.from), to: shiftOneYear(range.to) };
}

/**
 * Comparisons use only the ELAPSED portion of the selected calendar range
 * (Product Owner decision, 2026-09-29): the displayed range (with its future
 * empty buckets, D16) is unchanged, but unelapsed time never enters a
 * comparison or an Energy Attention threshold. The elapsed portion ends at the
 * last boundary the data can represent exactly on both sides: the last
 * completed UTC hour for the hourly historian (1h), today's local midnight for
 * the site-local daily historian (1d). Never before the range's start.
 */
export function comparisonCutoff(
  range: AbsoluteRange,
  resolution: EnergyResolution,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): string {
  const from = Date.parse(range.from);
  const to = Date.parse(range.to);
  const boundary =
    resolution === "1h"
      ? Math.floor(now.getTime() / 3_600_000) * 3_600_000
      : localMidnightUtc(localDateKey(now, timeZone), timeZone).getTime();
  return new Date(Math.max(from, Math.min(boundary, to))).toISOString();
}

/** The historical window covering the same elapsed portion as [range.from,
 *  cutoff): the preceding period of the range's full length, cut to the same
 *  elapsed duration (PREVIOUS_PERIOD), or the same calendar window one year
 *  earlier (SAME_PERIOD_PREVIOUSLY). */
export function elapsedComparisonWindow(
  range: AbsoluteRange,
  cutoff: string,
  basis: HistoricalShiftBasis,
): AbsoluteRange {
  if (basis === "PREVIOUS_PERIOD") {
    const spanMs = Date.parse(range.to) - Date.parse(range.from);
    return {
      from: new Date(Date.parse(range.from) - spanMs).toISOString(),
      to: new Date(Date.parse(cutoff) - spanMs).toISOString(),
    };
  }
  return shiftRangeForComparison({ from: range.from, to: cutoff }, basis);
}

export type EnergyComparisonPlan = {
  supported: true;
  resolution: EnergyResolution;
  /** The displayed calendar range -- the chart and the "This period" total. */
  current: AbsoluteRange;
  /** End of the elapsed portion used for the comparison ([current.from, comparedUntil)). */
  comparedUntil: string;
  /** The historical window covering the same elapsed portion; null while
   *  nothing has elapsed yet (e.g. the first minutes of Today). */
  comparison: AbsoluteRange | null;
};

/**
 * How to request the current AND comparison energy windows for a preset --
 * two independent calls to the existing, unmodified
 * GET /sites/{id}/energy/consumption, both at the same resolution so the
 * two series are directly comparable. The comparison window covers only the
 * elapsed portion of the current range (comparisonCutoff). Unsupported exactly
 * when the current window itself is unsupported (the comparison window is
 * never longer, so it satisfies the same resolution cap).
 */
export function planEnergyComparisonRequest(
  preset: TimeRangePreset,
  basis: HistoricalShiftBasis,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): EnergyComparisonPlan | UnsupportedPlan {
  const currentPlan = planEnergyRequest(preset, timeZone, now);
  if (!currentPlan.supported) return currentPlan;
  const comparedUntil = comparisonCutoff(currentPlan.range, currentPlan.resolution, timeZone, now);
  return {
    supported: true,
    resolution: currentPlan.resolution,
    current: currentPlan.range,
    comparedUntil,
    comparison:
      Date.parse(comparedUntil) > Date.parse(currentPlan.range.from)
        ? elapsedComparisonWindow(currentPlan.range, comparedUntil, basis)
        : null,
  };
}

// ---------------------------------------------------------------------------
// Slice C -- Typical historical reference (comparable-period) planning.
//
// A THIRD comparison basis, not a replacement for PREVIOUS_PERIOD/
// SAME_PERIOD_PREVIOUSLY above. Unlike those two, the 8 comparable periods
// are selected and aggregated entirely SERVER-SIDE (migration 236) -- this
// function's only job is to compute the window to send as [from, to) to
// GET .../energy/consumption/typical-reference.
//
// That endpoint requires (to - from) to be an EXACT whole number of 24-hour
// days, one of 1/7/30/90/365. The customer's calendar range (resolveRange)
// is not always such a span: 3 Months is 90-93 days, 1 Year is 366 days (367
// across 29 February), and a DST change makes a local week 1 hour shorter or
// longer. Product Owner decision (2026-09-29): the customer's calendar range
// stays authoritative for actual consumption; typical reference uses the
// nearest supported fixed window -- 1/7/30/90/365 days for Today/7 Days/
// 30 Days/3 Months/1 Year -- ENDING at the calendar range's end, and is never
// shown as unavailable because of the mismatch. When the day counts differ,
// average consumption per calendar day is compared, not raw totals.
//
// Elapsed portion (Product Owner decisions, 2026-09-29): comparisons use only
// the elapsed part of the range, and for Typical only COMPLETE elapsed local
// days -- the typical value comes from the site-local daily historian, which
// cannot represent part of a day. The actual consumption compared is read for
// those complete days (`basisRange`, at 1d); the typical per day is scaled to
// the same number of days. Today has no complete day, so it has no Typical
// comparison until the day is complete.
// ---------------------------------------------------------------------------

/** The fixed typical-reference window length, in days, for each preset. */
export const TYPICAL_REFERENCE_WINDOW_DAYS: Record<TimeRangePreset, number> = {
  TODAY: 1,
  "7D": 7,
  "30D": 30,
  "3M": 90,
  "1Y": 365,
};

export type EnergyTypicalReferencePlan = {
  supported: true;
  /** [from, to) sent to GET .../energy/consumption/typical-reference.
   *  Always an exact whole-day span (1/7/30/90/365 days) ending at the
   *  calendar range's end. */
  current: AbsoluteRange;
  /** The complete elapsed local days of the customer's range, [range start,
   *  today's local midnight) -- the actual consumption compared, read at 1d.
   *  Null when no complete day has elapsed (Today). */
  basisRange: AbsoluteRange | null;
  /** Number of complete elapsed local days in basisRange (0 for Today). */
  basisDays: number;
  /** Days in the reference window. */
  referenceDays: number;
};

export function planEnergyTypicalReferenceRequest(
  preset: TimeRangePreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): EnergyTypicalReferencePlan | UnsupportedPlan {
  const currentPlan = planEnergyRequest(preset, timeZone, now);
  if (!currentPlan.supported) return currentPlan;

  const referenceDays = TYPICAL_REFERENCE_WINDOW_DAYS[preset];
  const to = currentPlan.range.to;
  const from = new Date(Date.parse(to) - referenceDays * DAY_MS).toISOString();
  const completeUntil = comparisonCutoff(currentPlan.range, "1d", timeZone, now);
  const basisRange =
    Date.parse(completeUntil) > Date.parse(currentPlan.range.from)
      ? { from: currentPlan.range.from, to: completeUntil }
      : null;
  return {
    supported: true,
    current: { from, to },
    basisRange,
    basisDays: basisRange ? calendarDayCount(basisRange) : 0,
    referenceDays,
  };
}
