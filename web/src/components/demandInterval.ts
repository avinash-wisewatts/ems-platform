/**
 * Completed demand interval presentation helpers (T1.3a, revised run 11).
 *
 * The Admin Portal shows calculated demand only as the LAST COMPLETED
 * interval (GET .../demand/current -> last_completed_interval, the newest
 * analytics.demand_intervals row of any status). No provisional or
 * in-progress value is displayed anywhere (D-011): a value is shown only
 * once its interval has been finalized, always with its own site-local
 * start-end and its data-quality status.
 *
 * Only a VALID interval's value is presented as demand. INCOMPLETE and the
 * unavailable statuses are shown as a status with no value, so incomplete
 * or unavailable data is never presented as reliable demand.
 *
 * Interval boundaries are absolute instants (the site-local wall-clock
 * boundaries demand was calculated on, already converted by the database),
 * so they are formatted in the site's timezone for display.
 */

import type { DemandIntervalPoint } from "../api/types";
import { formatTimeAndDateInTimeZone } from "../time/format";

/** "10:00–10:15, 13 Oct" in the site's timezone. The date is the date of
 *  the interval's start, so the last interval of a day reads
 *  "23:45–00:00, 12 Oct". Built from formatTimeAndDateInTimeZone's fixed
 *  "HH:MM, DD MMM" shape (locale- and ICU-independent month names). */
export function formatDemandInterval(
  intervalStart: string,
  intervalEnd: string,
  timeZone: string | null | undefined,
): string {
  const [startTime, startDate] = formatTimeAndDateInTimeZone(intervalStart, timeZone).split(", ");
  const [endTime] = formatTimeAndDateInTimeZone(intervalEnd, timeZone).split(", ");
  return `${startTime}–${endTime}, ${startDate}`;
}

/** Interval length in whole minutes ("15-min"), from its own boundaries
 *  rather than assuming the 15-minute policy. */
export function demandIntervalLengthLabel(intervalStart: string, intervalEnd: string): string {
  const minutes = Math.round((Date.parse(intervalEnd) - Date.parse(intervalStart)) / 60_000);
  return `${minutes}-min`;
}

/** The interval's demand value, or null when it must not be presented as
 *  demand: only a VALID interval with a value qualifies. */
export function reliableDemandKw(point: DemandIntervalPoint): number | null {
  return point.quality_status === "VALID" ? point.demand_kw : null;
}

/** DRAFT customer wording (plan Q-14) for a completed interval's
 *  quality_status. Unknown values fall back to "Data unavailable", never
 *  the raw technical string. */
const COMPLETED_INTERVAL_STATUS_LABELS: Record<string, string> = {
  VALID: "Complete data",
  INCOMPLETE: "Incomplete data",
  NO_DATA: "Data unavailable",
  INVALID_SOURCE: "Data unavailable",
  SOURCE_BOUNDARY: "Data unavailable",
  INSUFFICIENT_SOURCE_RESOLUTION: "Data unavailable",
};

const UNAVAILABLE_EXPLANATION =
  "There were not enough usable meter readings to calculate demand for this interval, so no value is shown.";

/** DRAFT, as above. */
const COMPLETED_INTERVAL_STATUS_EXPLANATIONS: Record<string, string> = {
  VALID: "Calculated from the meter readings for the whole interval.",
  INCOMPLETE:
    "Some meter readings for this interval are missing, so its demand value is not reliable and is not shown.",
};

export function completedIntervalStatusLabel(qualityStatus: string | null | undefined): string {
  if (!qualityStatus) return "Data unavailable";
  return COMPLETED_INTERVAL_STATUS_LABELS[qualityStatus] ?? "Data unavailable";
}

export function completedIntervalStatusExplanation(qualityStatus: string | null | undefined): string {
  if (!qualityStatus) return UNAVAILABLE_EXPLANATION;
  return COMPLETED_INTERVAL_STATUS_EXPLANATIONS[qualityStatus] ?? UNAVAILABLE_EXPLANATION;
}

/** "Incomplete data (72% coverage)" -- the status label, with coverage
 *  when the interval is INCOMPLETE and coverage is known. */
export function completedIntervalStatusText(point: DemandIntervalPoint): string {
  const label = completedIntervalStatusLabel(point.quality_status);
  if (point.quality_status === "INCOMPLETE" && point.coverage_percent !== null) {
    return `${label} (${point.coverage_percent.toFixed(0)}% coverage)`;
  }
  return label;
}
