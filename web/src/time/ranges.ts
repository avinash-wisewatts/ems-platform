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

import type { EnergyResolution, MeasurementResolution } from "../api/types";

export const TIME_RANGE_PRESETS = ["TODAY", "7D", "30D", "3M", "1Y"] as const;
export type TimeRangePreset = (typeof TIME_RANGE_PRESETS)[number];

export const PRESET_LABELS: Record<TimeRangePreset, string> = {
  TODAY: "Today",
  "7D": "7 Days",
  "30D": "30 Days",
  "3M": "3 Months",
  "1Y": "1 Year",
};

export type DataKind = "measurement" | "energy";

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
const MEASUREMENT_MAX_WINDOW_S: Record<MeasurementResolution, number> = {
  raw: 24 * 3600,
  "1h": 31 * 86400,
};
const ENERGY_MAX_WINDOW_S: Record<EnergyResolution, number> = {
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
export type UnsupportedPlan = {
  supported: false;
  reason: string;
};

function windowSeconds(range: AbsoluteRange): number {
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

export function isPresetSupported(preset: TimeRangePreset, kind: DataKind, now: Date = new Date()): boolean {
  const plan = kind === "measurement" ? planMeasurementRequest(preset, now) : planEnergyRequest(preset, now);
  return plan.supported;
}
