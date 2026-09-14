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

export const TIME_RANGE_PRESETS = ["TODAY", "7D", "30D", "3M", "1Y"] as const;
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

/** Resolve a preset to a half-open absolute range ending "now" (UTC). */
export function resolveRange(preset: TimeRangePreset, now: Date = new Date()): AbsoluteRange {
  const to = now;
  let from: Date;
  switch (preset) {
    case "TODAY": {
      from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
      break;
    }
    case "7D":
      from = new Date(to.getTime() - 7 * DAY_MS);
      break;
    case "30D":
      from = new Date(to.getTime() - 30 * DAY_MS);
      break;
    case "3M":
      from = new Date(to.getTime() - 90 * DAY_MS);
      break;
    case "1Y":
      from = new Date(to.getTime() - 365 * DAY_MS);
      break;
  }
  return { from: from.toISOString(), to: to.toISOString() };
}

// Phase 7 caps (seconds). Kept in sync with analytics_api_service.py.
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
  now: Date = new Date(),
): MeasurementPlan | UnsupportedPlan {
  const range = resolveRange(preset, now);
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
  now: Date = new Date(),
): EnergyPlan | UnsupportedPlan {
  const range = resolveRange(preset, now);
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
  now: Date = new Date(),
): DemandPlan | UnsupportedPlan {
  const range = resolveRange(preset, now);
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
  now: Date = new Date(),
): PowerQualityPlan | UnsupportedPlan {
  const range = resolveRange(preset, now);
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

function planForKind(kind: DataKind, preset: TimeRangePreset, now: Date) {
  switch (kind) {
    case "measurement":
      return planMeasurementRequest(preset, now);
    case "demand":
      return planDemandRequest(preset, now);
    case "power-quality":
      return planPowerQualityRequest(preset, now);
    case "energy":
    default:
      return planEnergyRequest(preset, now);
  }
}

export function isPresetSupported(preset: TimeRangePreset, kind: DataKind, now: Date = new Date()): boolean {
  return planForKind(kind, preset, now).supported;
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

export type EnergyComparisonPlan = {
  supported: true;
  resolution: EnergyResolution;
  current: AbsoluteRange;
  comparison: AbsoluteRange;
};

/**
 * How to request the current AND comparison energy windows for a preset --
 * two independent calls to the existing, unmodified
 * GET /sites/{id}/energy/consumption, both at the same resolution so the
 * two series are directly comparable. Unsupported exactly when the current
 * window itself is unsupported (the comparison window has the same span, so
 * it independently satisfies the same resolution cap).
 */
export function planEnergyComparisonRequest(
  preset: TimeRangePreset,
  basis: HistoricalShiftBasis,
  now: Date = new Date(),
): EnergyComparisonPlan | UnsupportedPlan {
  const currentPlan = planEnergyRequest(preset, now);
  if (!currentPlan.supported) return currentPlan;
  return {
    supported: true,
    resolution: currentPlan.resolution,
    current: currentPlan.range,
    comparison: shiftRangeForComparison(currentPlan.range, basis),
  };
}

// ---------------------------------------------------------------------------
// Slice C -- Typical historical reference (comparable-period) planning.
//
// A THIRD comparison basis, not a replacement for PREVIOUS_PERIOD/
// SAME_PERIOD_PREVIOUSLY above. Unlike those two, the 8 comparable periods
// are selected and aggregated entirely SERVER-SIDE (migration 236) -- this
// function's only job is to compute the CURRENT window to send as [from,
// to) to GET .../energy/consumption/typical-reference, which the server
// then uses to derive up to 8 comparable historical windows itself.
//
// The typical-reference endpoint requires (to - from) to be an EXACT whole
// number of days (1/7/30/90/365). planEnergyRequest's range already
// satisfies this for 7D/30D/3M/1Y (a pure "now minus N days" duration
// subtraction is always exactly N*86400000ms, regardless of what
// time-of-day "now" is). TODAY is the one exception: resolveRange's TODAY
// window is UTC-midnight-to-now (a PARTIAL day, since "now" is rarely
// exactly midnight) -- so here, and ONLY here, `to` is widened to exactly
// one full day after `from`, reusing resolveRange's own (UTC-midnight-
// aligned) `from` UNCHANGED.
//
// This intentionally inherits the same pre-existing UTC-vs-site-local
// TODAY imprecision already documented in the approved Slice C Historical
// Comparison specification (resolveRange's TODAY is not site-timezone-
// aware) -- NOT fixed and NOT expanded here, per that specification's
// explicit instruction to leave resolveRange/TODAY's existing behaviour
// alone and treat it as a separate, already-reported issue. The CURRENT
// VALUE the customer sees is entirely unaffected: it still comes from the
// separate, unmodified GET /energy/consumption call using its own
// unmodified midnight-to-now window; this plan's `current` is used ONLY
// as the typical-reference request's own [from, to) parameter.
// ---------------------------------------------------------------------------

export type EnergyTypicalReferencePlan = {
  supported: true;
  /** [from, to) sent to GET .../energy/consumption/typical-reference.
   *  Always an exact whole-day span (1/7/30/90/365 days). */
  current: AbsoluteRange;
};

export function planEnergyTypicalReferenceRequest(
  preset: TimeRangePreset,
  now: Date = new Date(),
): EnergyTypicalReferencePlan | UnsupportedPlan {
  const currentPlan = planEnergyRequest(preset, now);
  if (!currentPlan.supported) return currentPlan;

  if (preset === "TODAY") {
    const from = currentPlan.range.from;
    const to = new Date(Date.parse(from) + DAY_MS).toISOString();
    return { supported: true, current: { from, to } };
  }

  return { supported: true, current: currentPlan.range };
}
