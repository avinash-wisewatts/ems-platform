/**
 * Year-to-date / month-to-date window helpers for the Main Dashboard's
 * Total Energy cards. Pure date math only -- no network, no new comparison
 * semantics registered with time/ranges.ts's approved Slice A/C comparison-
 * basis model (PREVIOUS_PERIOD / SAME_PERIOD_PREVIOUSLY /
 * TYPICAL_HISTORICAL_REFERENCE), which is scoped to the TimeRangePicker
 * presets (TODAY/7D/30D/3M/1Y) and does not cover YTD/MTD. Both ranges are
 * sent, unmodified, to the existing GET /sites/{id}/energy/consumption --
 * no new backend endpoint.
 */

import type { AbsoluteRange } from "../../time/ranges";

/** [Jan 1 00:00 UTC of the current year, now). */
export function ytdRange(now: Date = new Date()): AbsoluteRange {
  const from = new Date(Date.UTC(now.getUTCFullYear(), 0, 1));
  return { from: from.toISOString(), to: now.toISOString() };
}

/** [1st of the current month 00:00 UTC, now). */
export function mtdRange(now: Date = new Date()): AbsoluteRange {
  const from = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  return { from: from.toISOString(), to: now.toISOString() };
}

function daysInMonth(year: number, monthIndex0: number): number {
  return new Date(Date.UTC(year, monthIndex0 + 1, 0)).getUTCDate();
}

/**
 * The same partial-month window exactly one calendar month earlier (e.g.
 * MTD "1-16 Sep" -> "1-16 Aug"), for the MTD "vs. Previous Month" card. The
 * day-of-month is clamped to the shorter month's length so, e.g., the 31st
 * never rolls forward into the following month.
 */
export function previousMonthRange(range: AbsoluteRange): AbsoluteRange {
  const shift = (iso: string): string => {
    const d = new Date(iso);
    const year = d.getUTCFullYear();
    const month = d.getUTCMonth();
    const targetYear = month === 0 ? year - 1 : year;
    const targetMonth = month === 0 ? 11 : month - 1;
    const day = Math.min(d.getUTCDate(), daysInMonth(targetYear, targetMonth));
    return new Date(
      Date.UTC(targetYear, targetMonth, day, d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds()),
    ).toISOString();
  };
  return { from: shift(range.from), to: shift(range.to) };
}
