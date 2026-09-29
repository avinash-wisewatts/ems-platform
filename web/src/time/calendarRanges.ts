/**
 * Calendar-based quick ranges in a site's own timezone -- the application-wide
 * semantics decided for Analytics v1 (ADR-022 Amendment 5, D8, D11-D13,
 * D61, D62; see docs/07-features/analytics/README.md "Date and time range"):
 *
 *   Today    the whole current local calendar day
 *   7 Days   today plus the preceding 6 local days
 *   30 Days  today plus the preceding 29 local days
 *   3 Months from the same day-of-month 3 calendar months back
 *   1 Year   from the same day-of-month 1 calendar year back
 *
 * Every range starts at a local midnight and ends at the EXCLUSIVE next local
 * midnight after today (so Today is never shortened to "now"). When the
 * target month has no such day-of-month, its last valid day is used (D62:
 * 3 Months from 31 May starts 28 Feb; 1 Year from 29 Feb 2028 starts 28 Feb
 * 2027). Local midnights are resolved in the site's IANA timezone, so DST days
 * are 23 or 25 hours long. The shared week-start convention is Sunday.
 */

export const CALENDAR_PRESETS = ["TODAY", "7D", "30D", "3M", "1Y"] as const;
export type CalendarPreset = (typeof CALENDAR_PRESETS)[number];

/** The shared week-start convention (D13, D61): Sunday, as in `Date.getDay()`. */
export const WEEK_START_DAY = 0;

export type CalendarRange = { from: string; to: string };

const DAY_MS = 86_400_000;

type DateKey = { year: number; month: number; day: number };

function parseKey(key: string): DateKey {
  return { year: Number(key.slice(0, 4)), month: Number(key.slice(5, 7)), day: Number(key.slice(8, 10)) };
}

function formatKey({ year, month, day }: DateKey): string {
  return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** The local calendar date ("YYYY-MM-DD") that `instant` falls on in `timeZone`. */
export function localDateKey(instant: Date, timeZone: string | null | undefined): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timeZone ?? "UTC",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(instant);
}

/** Calendar arithmetic on a date key (no timezone involved). */
export function addDays(key: string, days: number): string {
  const { year, month, day } = parseKey(key);
  const d = new Date(Date.UTC(year, month - 1, day + days));
  return formatKey({ year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() });
}

/** Same day-of-month `months` calendar months away; the target month's last
 *  valid day when it has no such day (D62). */
export function addMonthsClamped(key: string, months: number): string {
  const { year, month, day } = parseKey(key);
  const index = year * 12 + (month - 1) + months;
  const targetYear = Math.floor(index / 12);
  const targetMonth = (index % 12) + 1;
  return formatKey({ year: targetYear, month: targetMonth, day: Math.min(day, daysInMonth(targetYear, targetMonth)) });
}

/** How far the zone's wall clock reads ahead of UTC at `ms`. */
function offsetMs(ms: number, timeZone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(new Date(ms));
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? "0");
  const wallClockAsUtc = Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second"));
  return wallClockAsUtc - Math.floor(ms / 1000) * 1000;
}

/**
 * The UTC instant of local midnight at the start of calendar date `key` in
 * `timeZone`. DST-correct: the offset is taken at midnight itself, not at
 * another time of that day. If a zone skips midnight, the first instant of
 * that local day is returned.
 */
export function localMidnightUtc(key: string, timeZone: string | null | undefined): Date {
  const tz = timeZone ?? "UTC";
  const { year, month, day } = parseKey(key);
  const naive = Date.UTC(year, month - 1, day);
  const first = naive - offsetMs(naive, tz);
  const candidate = naive - offsetMs(first, tz);
  const candidates = [first, candidate].filter((ms) => localDateKey(new Date(ms), tz) === key);
  if (candidates.length > 0) {
    const earliest = Math.min(...candidates);
    // A skipped midnight: step back to the first instant that is still `key`.
    const previousHour = earliest - 3_600_000;
    return new Date(localDateKey(new Date(previousHour), tz) === key ? previousHour : earliest);
  }
  // Midnight does not exist and both probes landed on the previous day.
  return new Date(Math.max(first, candidate) + 3_600_000);
}

/** The first local date of `preset`, counting today as `todayKey`. */
export function presetStartKey(preset: CalendarPreset, todayKey: string): string {
  switch (preset) {
    case "TODAY":
      return todayKey;
    case "7D":
      return addDays(todayKey, -6);
    case "30D":
      return addDays(todayKey, -29);
    case "3M":
      return addMonthsClamped(todayKey, -3);
    case "1Y":
      return addMonthsClamped(todayKey, -12);
  }
}

/** [local midnight of the first day, next local midnight after today), as UTC ISO strings. */
export function calendarRange(
  preset: CalendarPreset,
  timeZone: string | null | undefined,
  now: Date = new Date(),
): CalendarRange {
  const todayKey = localDateKey(now, timeZone);
  return {
    from: localMidnightUtc(presetStartKey(preset, todayKey), timeZone).toISOString(),
    to: localMidnightUtc(addDays(todayKey, 1), timeZone).toISOString(),
  };
}

/** Number of local calendar days in a range made of whole local days (a DST
 *  day of 23 or 25 hours still counts as one day). */
export function calendarDayCount(range: CalendarRange): number {
  return Math.round((Date.parse(range.to) - Date.parse(range.from)) / DAY_MS);
}
