/**
 * Asset View's own time-range presets -- calendar-day-aligned windows in
 * the SELECTED SITE's configured timezone (never the viewer's browser
 * timezone), unlike time/ranges.ts's own TimeRangePicker presets, which
 * this screen doesn't reuse.
 *
 * Today    -- site-local midnight of the current day, through now
 *             (a partial day -- today isn't over yet).
 * Yesterday -- site-local midnight of the previous day, through site-local
 *             midnight of today (a complete, closed day).
 * 1 Week   -- site-local midnight 6 days before today, through now (a
 *             rolling 7-calendar-day window that includes today's partial
 *             day so far, anchored to local midnight rather than to a pure
 *             "now minus 7*24h" duration).
 * 1 Month  -- the same rolling pattern as 1 Week, over 30 calendar days.
 *
 * Default on initial load is "Today" (AssetView.tsx's own useState).
 *
 * Boundaries are computed via time/format.ts#startOfDayInTimeZone -- see
 * its own doc comment for the calculation and its one documented
 * limitation (a DST transition inside the window, not applicable to any of
 * this product's currently configured site timezones).
 */

import { startOfDayInTimeZone } from "../../time/format";

export const ASSET_TIME_RANGE_PRESETS = ["TODAY", "YESTERDAY", "1W", "1M"] as const;
export type AssetTimeRangePreset = (typeof ASSET_TIME_RANGE_PRESETS)[number];

export const ASSET_TIME_RANGE_LABELS: Record<AssetTimeRangePreset, string> = {
  TODAY: "Today",
  YESTERDAY: "Yesterday",
  "1W": "1 Week",
  "1M": "1 Month",
};

const DAY_MS = 86_400_000;

export type AbsoluteRange = { from: string; to: string };

/** Resolve a preset to a half-open [from, to) range, in `siteTimezone`.
 *  `siteTimezone` is the selected site's own `timezone` field (may be
 *  null, in which case startOfDayInTimeZone falls back to the runtime's
 *  own zone rather than silently assuming UTC or the viewer's zone
 *  represents the site). */
export function resolveAssetTimeRange(
  preset: AssetTimeRangePreset,
  siteTimezone: string | null,
  now: Date = new Date(),
): AbsoluteRange {
  const todayStart = startOfDayInTimeZone(now, siteTimezone);

  switch (preset) {
    case "TODAY":
      return { from: todayStart.toISOString(), to: now.toISOString() };
    case "YESTERDAY": {
      const yesterdayStart = new Date(todayStart.getTime() - DAY_MS);
      return { from: yesterdayStart.toISOString(), to: todayStart.toISOString() };
    }
    case "1W": {
      const from = new Date(todayStart.getTime() - 6 * DAY_MS);
      return { from: from.toISOString(), to: now.toISOString() };
    }
    case "1M": {
      const from = new Date(todayStart.getTime() - 29 * DAY_MS);
      return { from: from.toISOString(), to: now.toISOString() };
    }
  }
}

/**
 * Shifts both endpoints of a range back by exactly one day (24h) -- used
 * for the Energy tile's "vs. Yesterday" comparison. Deliberately NOT
 * time/ranges.ts#shiftRangeForComparison's own "PREVIOUS_PERIOD" (the
 * immediately preceding window of the SAME DURATION as `range`): for a
 * "Today" window (site-local midnight through now, a PARTIAL day whose
 * duration keeps growing as the day goes on), that would shift back by
 * only that partial duration -- e.g. at 10:00 "today" is a 10-hour window,
 * so PREVIOUS_PERIOD would land on [yesterday 14:00, today 00:00), not
 * "yesterday 00:00-10:00" at all. A fixed 24h shift always lands on
 * exactly the same site-local clock-time window one calendar day earlier,
 * regardless of how much of today has elapsed -- a pure duration
 * subtraction, so (like resolveAssetTimeRange's own 1W/1M) it needs no
 * timezone itself, only whatever timezone `range`'s own boundaries were
 * already computed in.
 */
export function shiftRangeByOneDay(range: AbsoluteRange): AbsoluteRange {
  return {
    from: new Date(Date.parse(range.from) - DAY_MS).toISOString(),
    to: new Date(Date.parse(range.to) - DAY_MS).toISOString(),
  };
}
