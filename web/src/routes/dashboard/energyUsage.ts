/**
 * Main Dashboard -- Energy Usage bar chart. Pure time/aggregation logic
 * only; no network, no React -- same discipline as energy/comparison.ts and
 * this folder's own dateWindows.ts.
 *
 * Revision (this session, following a read-only architecture investigation
 * reported separately): Weekly/Monthly/Yearly are now SERVER-SIDE
 * aggregations (GET /sites/{id}/energy/consumption with resolution=1w/1mo/
 * 1y, migration 248) of analytics.energy_consumption_daily -- this module
 * does NOT reconstruct those buckets in the browser any more. The date-
 * range picker remains bounded by the site's ACTUAL persisted energy-data
 * availability (api/endpoints.ts#getSiteEnergyAvailability, migration 247)
 * -- never by time/ranges.ts#ENERGY_MAX_WINDOW_S, a per-request query-
 * window cap, not a data-availability fact.
 *
 * Each display resolution now maps 1:1 to its own API resolution -- there
 * is no shared source between any two of them any more:
 *
 *   HOURLY  -> "1h"   (analytics.energy_consumption_hourly)
 *   DAILY   -> "1d"   (analytics.energy_consumption_daily)
 *   WEEKLY  -> "1w"   (server-aggregated from energy_consumption_daily)
 *   MONTHLY -> "1mo"  (server-aggregated from energy_consumption_daily)
 *   YEARLY  -> "1y"   (server-aggregated from energy_consumption_daily)
 *
 * Hourly is a DIRECT passthrough of the API's own hourly buckets (gap-filled
 * for missing hours). Its bucket_start grid is whole UTC hours (postgres/
 * migrations/217_hourly_forward_window_utc_alignment.sql: `date_bin('1
 * hour', ..., '2000-01-01 00:00:00+00')`), NOT site-local hour boundaries --
 * a site whose UTC offset includes a half-hour component (e.g. Asia/
 * Kolkata, UTC+5:30) therefore has hourly bars that start on the half-hour
 * in local time -- an honest reflection of the real underlying grid, not a
 * bug. Daily is a direct passthrough gap-filled per calendar day. Weekly/
 * Monthly/Yearly are a direct, ungapped passthrough of whatever periods the
 * server actually returns -- see bucketEnergyUsage's own doc comment for
 * why gap-filling is intentionally NOT attempted for those three client-side.
 *
 * RESOLUTION AVAILABILITY is a function of the APPLIED date range's actual
 * duration, per explicit product decision: Hourly is offered only for a
 * range of 31 days or less (availableEnergyUsageResolutions below) --
 * reusing the exact "31 days" figure this codebase already established as
 * its own definition of "1 month" for Hourly (time/ranges.ts#
 * ENERGY_MAX_WINDOW_S["1h"] / analytics_api_service.py#
 * ENERGY_RESOLUTION_MAX_WINDOW["1h"]), not a newly invented threshold.
 * Daily/Weekly/Monthly/Yearly are always offered, at any range length --
 * no additional product rule for them is established anywhere in this
 * codebase, and none is invented here.
 */

import { dateKeyInTimeZone, siteLocalDateToUtcInstant } from "../../time/format";
import { ENERGY_MAX_WINDOW_S, windowSeconds, type AbsoluteRange } from "../../time/ranges";
import type { EnergyConsumptionPoint, EnergyResolution, SiteEnergyAvailabilityResponse } from "../../api/types";

const DAY_MS = 86_400_000;
const HOUR_MS = 3_600_000;

/** The established "1 month" figure for Hourly's own range limit -- reused,
 *  not reinvented (see module docstring). */
const HOURLY_MAX_RANGE_DAYS = 31;

export type EnergyUsageResolution = "HOURLY" | "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";

export const ENERGY_USAGE_RESOLUTIONS: readonly EnergyUsageResolution[] = [
  "HOURLY",
  "DAILY",
  "WEEKLY",
  "MONTHLY",
  "YEARLY",
];

export const ENERGY_USAGE_RESOLUTION_LABELS: Record<EnergyUsageResolution, string> = {
  HOURLY: "Hourly",
  DAILY: "Daily",
  WEEKLY: "Weekly",
  MONTHLY: "Monthly",
  YEARLY: "Yearly",
};

/** Which GET /energy/consumption resolution a display resolution is
 *  sourced from -- see the module docstring. Each is now a 1:1 mapping. */
export function sourceResolutionFor(resolution: EnergyUsageResolution): EnergyResolution {
  switch (resolution) {
    case "HOURLY":
      return "1h";
    case "DAILY":
      return "1d";
    case "WEEKLY":
      return "1w";
    case "MONTHLY":
      return "1mo";
    case "YEARLY":
      return "1y";
  }
}

function daysBetweenDateKeys(fromKey: string, toKey: string): number {
  const parse = (key: string) => ({
    year: Number(key.slice(0, 4)),
    month: Number(key.slice(5, 7)),
    day: Number(key.slice(8, 10)),
  });
  const f = parse(fromKey);
  const t = parse(toKey);
  const fromMs = Date.UTC(f.year, f.month - 1, f.day);
  const toMs = Date.UTC(t.year, t.month - 1, t.day);
  return Math.round((toMs - fromMs) / DAY_MS) + 1; // inclusive of both endpoints
}

/**
 * Which display resolutions are offered for a selected [fromKey, toKey]
 * (site-local calendar dates, inclusive) -- driven entirely by the ACTUAL
 * duration of that range, never by a preset label (there are no presets any
 * more) and never by shrinking the date range itself. Hourly is excluded
 * once the range exceeds 31 days; every other resolution is always offered.
 */
export function availableEnergyUsageResolutions(fromKey: string, toKey: string): EnergyUsageResolution[] {
  const durationDays = daysBetweenDateKeys(fromKey, toKey);
  const resolutions: EnergyUsageResolution[] = [];
  if (durationDays <= HOURLY_MAX_RANGE_DAYS) resolutions.push("HOURLY");
  resolutions.push("DAILY", "WEEKLY", "MONTHLY", "YEARLY");
  return resolutions;
}

/**
 * If `current` is still offered for `available`, keeps it. Otherwise steps
 * forward through ENERGY_USAGE_RESOLUTIONS's own Hourly -> Daily -> Weekly
 * -> Monthly -> Yearly order to the next resolution that IS offered --
 * "the next appropriate available resolution," per the product decision,
 * without hardcoding which one that has to be. Today, the only way
 * `current` can become invalid is Hourly on a range beyond 31 days, which
 * this always resolves to Daily.
 */
export function resolveValidResolution(
  current: EnergyUsageResolution,
  available: readonly EnergyUsageResolution[],
): EnergyUsageResolution {
  if (available.includes(current)) return current;
  const currentIndex = ENERGY_USAGE_RESOLUTIONS.indexOf(current);
  const next = ENERGY_USAGE_RESOLUTIONS.slice(currentIndex + 1).find((r) => available.includes(r));
  return next ?? available[0] ?? current;
}

// ---------------------------------------------------------------------------
// Availability -- bounding the date-range picker in real data, not a cap.
// ---------------------------------------------------------------------------

export type EnergyUsageAvailability = {
  hasData: boolean;
  /** Site-local "YYYY-MM-DD". The picker's inclusive lower bound: the
   *  site's real earliest data date, or -- if the site has no data at all
   *  -- today (so a brand-new site's picker still has a valid, if
   *  single-day, range rather than an empty/broken one). */
  minDateKey: string;
  /** Site-local "YYYY-MM-DD". The picker's inclusive upper bound: never
   *  later than "today" (a future date can never have data), and never
   *  earlier than today either -- "today" is always selectable as the
   *  default even on a site whose availability read hasn't yet caught up
   *  with a still-in-progress day (see resolveDefaultEnergyUsageSelection).
   */
  maxDateKey: string;
};

/**
 * Derives the date-picker's actual selectable bounds from the site's real
 * availability response. `now`/`siteTimezone` are needed only to compute
 * "today" for the two edge cases above (no data yet; latest data lags
 * today) -- they never widen the bound past real earliest data.
 */
export function deriveEnergyUsageAvailability(
  response: SiteEnergyAvailabilityResponse,
  siteTimezone: string | null,
  now: Date = new Date(),
): EnergyUsageAvailability {
  const todayKey = dateKeyInTimeZone(now, siteTimezone);
  if (!response.has_data || !response.earliest || !response.latest) {
    return { hasData: false, minDateKey: todayKey, maxDateKey: todayKey };
  }
  const earliestKey = dateKeyInTimeZone(new Date(response.earliest), siteTimezone);
  const latestKey = dateKeyInTimeZone(new Date(response.latest), siteTimezone);
  return {
    hasData: true,
    minDateKey: earliestKey,
    maxDateKey: latestKey > todayKey ? latestKey : todayKey,
  };
}

/** Clamps a candidate date-key into [availability.minDateKey,
 *  availability.maxDateKey] (plain string comparison is safe -- "YYYY-MM-DD"
 *  sorts lexicographically in calendar order). */
export function clampDateKey(dateKey: string, availability: EnergyUsageAvailability): string {
  if (dateKey < availability.minDateKey) return availability.minDateKey;
  if (dateKey > availability.maxDateKey) return availability.maxDateKey;
  return dateKey;
}

export type EnergyUsageSelection = {
  from: string; // site-local "YYYY-MM-DD"
  to: string; // site-local "YYYY-MM-DD"
  resolution: EnergyUsageResolution;
};

/**
 * The chart's default state, per explicit product direction: "Today" (the
 * SITE's own calendar day, not the browser's) at Hourly resolution --
 * never a rolling preset. Needs no availability response: it is purely a
 * function of the site's timezone. A single-day range is always <= 31
 * days, so this default is always internally consistent with
 * availableEnergyUsageResolutions -- Hourly is always valid for it.
 */
export function resolveDefaultEnergyUsageSelection(
  siteTimezone: string | null,
  now: Date = new Date(),
): EnergyUsageSelection {
  const todayKey = dateKeyInTimeZone(now, siteTimezone);
  return { from: todayKey, to: todayKey, resolution: "HOURLY" };
}

function nextDateKey(dateKey: string): string {
  const year = Number(dateKey.slice(0, 4));
  const month = Number(dateKey.slice(5, 7));
  const day = Number(dateKey.slice(8, 10));
  return dateKeyInTimeZone(new Date(Date.UTC(year, month - 1, day + 1, 12, 0, 0)), "UTC");
}

/**
 * Resolves a selected [fromKey, toKey] (inclusive, site-local calendar
 * dates) into the half-open [from, to) instant range to request. When
 * `toKey` is "today" (site-local), `to` is `now` -- a partial day so far,
 * matching every other "Today" window in this app (e.g. assetView/
 * timeRange.ts#resolveAssetTimeRange). Otherwise `to` is the site-local
 * midnight that STARTS the day after `toKey` -- the selected day's own
 * calendar boundary, complete.
 */
export function resolveEnergyUsageRequestRange(
  fromKey: string,
  toKey: string,
  siteTimezone: string | null,
  now: Date = new Date(),
): AbsoluteRange {
  const from = siteLocalDateToUtcInstant(fromKey, siteTimezone);
  const todayKey = dateKeyInTimeZone(now, siteTimezone);
  const to = toKey === todayKey ? now : siteLocalDateToUtcInstant(nextDateKey(toKey), siteTimezone);
  return { from: from.toISOString(), to: to.toISOString() };
}

export type EnergyUsageFetchPlan =
  | { supported: true; resolution: EnergyResolution; range: AbsoluteRange }
  | { supported: false; reason: string };

/**
 * Whether the CURRENTLY selected [from, to] can actually be requested at
 * the given display resolution's source resolution. In normal operation
 * the UI never lets the user reach an unsupported combination -- the
 * resolution dropdown is already filtered by availableEnergyUsageResolutions
 * -- this is a defense-in-depth check against each source resolution's own
 * backend safety cap (ENERGY_MAX_WINDOW_S; see that module's doc comment
 * for why this is an engineering backstop, never the product's own
 * selectable-range decision).
 */
export function planEnergyUsageFetch(
  selection: EnergyUsageSelection,
  siteTimezone: string | null,
  now: Date = new Date(),
): EnergyUsageFetchPlan {
  const resolution = sourceResolutionFor(selection.resolution);
  const range = resolveEnergyUsageRequestRange(selection.from, selection.to, siteTimezone, now);
  const span = windowSeconds(range);
  const maxWindow = ENERGY_MAX_WINDOW_S[resolution];
  if (span > maxWindow) {
    const maxDays = Math.floor(maxWindow / 86_400);
    return {
      supported: false,
      reason: `${ENERGY_USAGE_RESOLUTION_LABELS[selection.resolution]} resolution requires a range of ${maxDays} days or less. Choose a shorter range or a coarser resolution.`,
    };
  }
  return { supported: true, resolution, range };
}

// ---------------------------------------------------------------------------
// Bucketing -- HOURLY/DAILY only. WEEKLY/MONTHLY/YEARLY are a direct
// passthrough of the server's own already-aggregated periods (see below).
// ---------------------------------------------------------------------------

export type EnergyUsageBar = {
  /** epoch ms of this bar's own start, fed to ChartFrame's `t` field. */
  t: number;
  /** kWh for this bar; null when no source data is present -- a true gap,
   *  never a fabricated 0. */
  kwh: number | null;
};

/** HOURLY: direct passthrough of the API's own "1h" buckets, gap-filled
 *  over every whole UTC hour in [range.from, range.to) so a missing hour
 *  renders as a gap rather than silently compressing the timeline. The
 *  enumeration grid is anchored to the UTC-hour grid itself (ceil(from) to
 *  floor(to)), not to `range.from` directly, since `range.from` is a
 *  site-local-midnight instant that will not itself sit on the UTC-hour
 *  grid for a half-hour-offset site (e.g. Asia/Kolkata) -- see the module
 *  docstring. */
function bucketEnergyUsageHourly(points: EnergyConsumptionPoint[], range: AbsoluteRange): EnergyUsageBar[] {
  const byHourStart = new Map<number, number | null>();
  for (const point of points) {
    byHourStart.set(Date.parse(point.bucket_start), point.import_kwh);
  }

  const fromMs = Date.parse(range.from);
  const toMs = Date.parse(range.to);
  const firstHour = Math.ceil(fromMs / HOUR_MS) * HOUR_MS;

  const bars: EnergyUsageBar[] = [];
  for (let hourStart = firstHour; hourStart < toMs; hourStart += HOUR_MS) {
    bars.push({ t: hourStart, kwh: byHourStart.get(hourStart) ?? null });
  }
  return bars;
}

/** DAILY: direct passthrough of the API's own "1d" buckets, gap-filled over
 *  every site-local calendar day in [range.from, range.to) -- a missing day
 *  renders as a gap, not a fabricated 0 or a compressed timeline. */
function bucketEnergyUsageDaily(points: EnergyConsumptionPoint[], range: AbsoluteRange): EnergyUsageBar[] {
  const byDayStart = new Map<number, number | null>();
  for (const point of points) {
    byDayStart.set(Date.parse(point.bucket_start), point.import_kwh);
  }

  const fromMs = Date.parse(range.from);
  const toMs = Date.parse(range.to);

  const bars: EnergyUsageBar[] = [];
  for (let dayStart = fromMs; dayStart < toMs; dayStart += DAY_MS) {
    bars.push({ t: dayStart, kwh: byDayStart.get(dayStart) ?? null });
  }
  return bars;
}

/** WEEKLY/MONTHLY/YEARLY: the server (migration 248) already returns one
 *  row per period, summed correctly from the site-local daily historian --
 *  this is a PLAIN passthrough, deliberately with NO client-side gap-
 *  filling or re-aggregation. Reconstructing the expected period grid here
 *  (to detect a wholly-missing period) would mean re-deriving the exact
 *  Monday/calendar-month/calendar-year boundaries this migration moved
 *  server-side specifically to avoid duplicating -- so a period with zero
 *  underlying data simply does not appear as a row, rather than as an
 *  explicit gap bar. This is still honest (every bar shown is a real,
 *  server-computed total; no bar is ever fabricated), just less granular
 *  than Hourly/Daily's own gap-filling for the (rare) case of a fully empty
 *  week/month/year in the middle of an otherwise-covered range. */
function bucketEnergyUsagePeriodic(points: EnergyConsumptionPoint[]): EnergyUsageBar[] {
  return points.map((point) => ({ t: Date.parse(point.bucket_start), kwh: point.import_kwh }));
}

/** Single entry point MainDashboard calls -- dispatches by display
 *  resolution. `points` must already come from
 *  sourceResolutionFor(resolution); this function does no resolution
 *  validation of its own. */
export function bucketEnergyUsage(
  points: EnergyConsumptionPoint[],
  resolution: EnergyUsageResolution,
  range: AbsoluteRange,
): EnergyUsageBar[] {
  if (resolution === "HOURLY") return bucketEnergyUsageHourly(points, range);
  if (resolution === "DAILY") return bucketEnergyUsageDaily(points, range);
  return bucketEnergyUsagePeriodic(points);
}
