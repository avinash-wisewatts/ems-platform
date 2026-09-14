/**
 * MVP-6 -- Q76 Site Performance Report. Time-period support distinct from
 * ../time/ranges.ts's preset system (see ADR-015 gap resolution 3):
 *
 *   - Predefined periods are CURRENT-CALENDAR Weekly/Monthly/Quarterly/
 *     Yearly windows (this week/month/quarter/year, to now) -- not the
 *     rolling N-day windows TimeRangePicker's presets use. Pure client-side
 *     date arithmetic; no new analytics.
 *   - Custom periods accept any {from, to} the customer picks. No
 *     data-availability bound is enforced -- no API exposes a site's
 *     actual data-available date range (ADR-015 gap resolution 2); a
 *     fabricated bound would be inventing behavior the repository doesn't
 *     establish.
 *
 * Every resolved period is then planned per-domain using the *exact same*
 * window caps ../time/ranges.ts already enforces for every existing
 * screen (re-exported from there, not duplicated) -- this module adds no
 * new threshold. planEnergyTypicalReferenceRequestForRange additionally
 * carries forward that endpoint's existing whole-day-window constraint
 * (1/7/30/90/365 days only) -- see ADR-015 gap resolution 6: a
 * calendar-to-date period essentially never satisfies it, so Attention/
 * Site Health legitimately read as unavailable for most report periods.
 * This module does not work around that constraint -- doing so would be
 * inventing a new comparison mechanism.
 */

import type { EnergyResolution, PowerQualityResolution } from "../api/types";
import {
  DEMAND_MAX_WINDOW_S,
  ENERGY_MAX_WINDOW_S,
  POWER_QUALITY_MAX_WINDOW_S,
  windowSeconds,
  type AbsoluteRange,
} from "../time/ranges";

export const REPORT_PERIODS = ["WEEKLY", "MONTHLY", "QUARTERLY", "YEARLY", "CUSTOM"] as const;
export type ReportPeriod = (typeof REPORT_PERIODS)[number];

export const REPORT_PERIOD_LABELS: Record<ReportPeriod, string> = {
  WEEKLY: "Weekly (this week)",
  MONTHLY: "Monthly (this month)",
  QUARTERLY: "Quarterly (this quarter)",
  YEARLY: "Yearly (this year)",
  CUSTOM: "Custom",
};

/** Current-calendar week/month/quarter/year, UTC, from the period's start
 *  to "now" -- a to-date window, matching ranges.ts's own TODAY convention
 *  (start-of-period to now, not a full future-inclusive period). */
export function resolveCalendarPeriod(period: Exclude<ReportPeriod, "CUSTOM">, now: Date = new Date()): AbsoluteRange {
  const y = now.getUTCFullYear();
  const m = now.getUTCMonth();
  let from: Date;
  switch (period) {
    case "WEEKLY": {
      // ISO week: Monday start. getUTCDay() is 0=Sun..6=Sat.
      const dow = now.getUTCDay();
      const daysSinceMonday = dow === 0 ? 6 : dow - 1;
      from = new Date(Date.UTC(y, m, now.getUTCDate() - daysSinceMonday));
      break;
    }
    case "MONTHLY":
      from = new Date(Date.UTC(y, m, 1));
      break;
    case "QUARTERLY": {
      const quarterStartMonth = Math.floor(m / 3) * 3;
      from = new Date(Date.UTC(y, quarterStartMonth, 1));
      break;
    }
    case "YEARLY":
      from = new Date(Date.UTC(y, 0, 1));
      break;
  }
  return { from: from.toISOString(), to: now.toISOString() };
}

export type ReportRangeUnsupported = { supported: false; reason: string };

export function planReportEnergyRequest(
  range: AbsoluteRange,
): { supported: true; resolution: EnergyResolution; range: AbsoluteRange } | ReportRangeUnsupported {
  const span = windowSeconds(range);
  const resolution: EnergyResolution = span <= ENERGY_MAX_WINDOW_S["1h"] ? "1h" : "1d";
  if (span > ENERGY_MAX_WINDOW_S[resolution]) {
    return { supported: false, reason: "This period is longer than the analytics API currently serves for energy." };
  }
  return { supported: true, resolution, range };
}

export function planReportDemandRequest(range: AbsoluteRange): { supported: true; range: AbsoluteRange } | ReportRangeUnsupported {
  const span = windowSeconds(range);
  if (span > DEMAND_MAX_WINDOW_S) {
    return {
      supported: false,
      reason: "This period is longer than the analytics API currently serves for demand (max 31 days).",
    };
  }
  return { supported: true, range };
}

export function planReportPowerQualityRequest(
  range: AbsoluteRange,
): { supported: true; resolution: PowerQualityResolution; range: AbsoluteRange } | ReportRangeUnsupported {
  const span = windowSeconds(range);
  const resolution: PowerQualityResolution =
    span <= POWER_QUALITY_MAX_WINDOW_S["15min"] ? "15min" : span <= POWER_QUALITY_MAX_WINDOW_S["1h"] ? "1h" : "1d";
  if (span > POWER_QUALITY_MAX_WINDOW_S[resolution]) {
    return {
      supported: false,
      reason: "This period is longer than the analytics API currently serves for power quality.",
    };
  }
  return { supported: true, resolution, range };
}

/** The Slice C typical-reference endpoint's own constraint (unchanged,
 *  not relaxed): (to - from) must be an EXACT whole number of days.
 *  Reused verbatim from ../time/ranges.ts's planEnergyTypicalReferenceRequest
 *  documentation -- see ADR-015 gap resolution 6 for why this makes
 *  Attention/Site Health unavailable for most calendar-to-date periods. */
export function planReportEnergyTypicalReferenceRequest(range: AbsoluteRange): { supported: true; current: AbsoluteRange } | ReportRangeUnsupported {
  const spanMs = Date.parse(range.to) - Date.parse(range.from);
  const wholeDays = spanMs / 86_400_000;
  if (!Number.isInteger(wholeDays) || wholeDays <= 0) {
    return {
      supported: false,
      reason:
        "Site Health and Attention require an exact whole-day period (the analytics API's typical-reference comparison) and aren't available for this period.",
    };
  }
  return { supported: true, current: range };
}
