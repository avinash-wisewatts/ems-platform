/** Shared "weekday, day month year, hour:minute" formatter -- used by the
 *  header's live clock (AppLayout) and the Main Dashboard's "Last data
 *  update" timestamp, so the two read consistently. */
export const DATE_TIME_FORMAT = new Intl.DateTimeFormat(undefined, {
  weekday: "short",
  day: "2-digit",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
});

/**
 * Formats an ISO timestamp in a given IANA timezone (e.g. a site's own
 * `timezone` field from GET /api/v1/sites) rather than the viewer's browser
 * timezone. A screen showing a SITE's operational data (demand occurrence,
 * chart axes, "last updated") must read consistently for every viewer
 * regardless of where they personally are -- unlike DATE_TIME_FORMAT above,
 * which is deliberately viewer-local (a header clock, a "when did I last
 * refresh" cue). Falls back to the browser's own timezone only when the
 * site has none configured (`timezone: null`), never silently assumes UTC
 * or the browser zone represents the site.
 */
export function formatInTimeZone(
  iso: string,
  timeZone: string | null | undefined,
  options: Intl.DateTimeFormatOptions,
): string {
  return new Intl.DateTimeFormat(undefined, { ...options, timeZone: timeZone ?? undefined }).format(new Date(iso));
}

const MONTH_ABBREVIATIONS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];

/**
 * "HH:MM, DD MMM" in the given timezone -- e.g. a Demand peak's occurrence
 * time. This shape is fixed regardless of viewer locale, matching the
 * approved Asset View Demand card presentation exactly. Extracts numeric
 * day/hour/minute/month fields via Intl.DateTimeFormat (so the timezone
 * conversion itself is still correct, locale-independent, IANA-aware math),
 * then maps the month to a hardcoded three-letter abbreviation rather than
 * trusting Intl's own `month: "short"` output -- the runtime's ICU data can
 * render a longer form ("Sept" instead of "Sep") depending on environment,
 * which would silently break this fixed-format contract.
 */
export function formatTimeAndDateInTimeZone(iso: string, timeZone: string | null | undefined): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timeZone ?? undefined,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    day: "2-digit",
    month: "numeric",
  }).formatToParts(new Date(iso));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  const month = MONTH_ABBREVIATIONS[Number(part("month")) - 1] ?? "";
  return `${part("hour")}:${part("minute")}, ${part("day")} ${month}`;
}

/**
 * "HH:MMAM"/"HH:MMPM" in the given timezone -- e.g. "06:00PM" -- the Asset
 * View Demand tile's Max Demand occurrence time, which (unlike
 * formatTimeAndDateInTimeZone above) never needs a date: the tile's window
 * is always "today", so only the time of day is meaningful. Zero-pads the
 * hour itself (Intl's own hour12 output is not reliably zero-padded across
 * environments) and strips any locale punctuation from the day-period
 * ("AM."/"a.m." -> "AM") so the shape stays fixed regardless of viewer
 * locale.
 */
export function formatTime12hInTimeZone(iso: string, timeZone: string | null | undefined): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timeZone ?? undefined,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).formatToParts(new Date(iso));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  const hour = part("hour").padStart(2, "0");
  const dayPeriod = part("dayPeriod").replace(/[^a-zA-Z]/g, "").toUpperCase();
  return `${hour}:${part("minute")}${dayPeriod}`;
}

/**
 * The UTC instant of local midnight, for the calendar day that `date` falls
 * on in `timeZone` -- the building block for calendar-aligned windows
 * ("Today", "Yesterday", "1 Week", "1 Month" on Asset View's time-range
 * selector), as opposed to a pure rolling duration (which needs no
 * timezone at all -- "now minus 24h" is the same instant everywhere).
 *
 * Works by reading `date`'s Y/M/D as seen in `timeZone` (via
 * formatToParts), then correcting for that zone's current UTC offset:
 * `offsetMs` is how far ahead the zone's wall clock reads versus the real
 * UTC instant (computed by re-interpreting the same wall-clock fields as if
 * they were UTC and diffing against the real instant), and local midnight's
 * real UTC instant is the "midnight-as-UTC" instant minus that offset.
 *
 * Known limitation (shared with this codebase's other calendar-day
 * handling, e.g. time/ranges.ts's own documented UTC-midnight TODO): if a
 * DST transition happens to fall within the requested window, a boundary
 * derived by subtracting whole 24h multiples from this result (as
 * ./assetView/timeRange.ts does for Yesterday/1 Week/1 Month) can be off by
 * the DST delta. None of this product's currently configured site
 * timezones observe DST, so this does not currently occur in practice.
 */
export function startOfDayInTimeZone(date: Date, timeZone: string | null | undefined): Date {
  const tz = timeZone ?? undefined;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const part = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? "0");

  const wallClockAsUtc = Date.UTC(part("year"), part("month") - 1, part("day"), part("hour"), part("minute"), part("second"));
  const offsetMs = wallClockAsUtc - date.getTime();

  const midnightAsUtc = Date.UTC(part("year"), part("month") - 1, part("day"), 0, 0, 0);
  return new Date(midnightAsUtc - offsetMs);
}

/**
 * "YYYY-MM-DD" for the calendar date `date` falls on in `timeZone` -- the
 * shape a native `<input type="date">` uses for both its `value` and its
 * `min`/`max` attributes. `en-CA` is used purely as an implementation
 * detail: that locale's default date order already happens to be
 * year-month-day with `-` separators, matching the input's own format
 * exactly, with no manual field reassembly needed.
 */
export function dateKeyInTimeZone(date: Date, timeZone: string | null | undefined): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: timeZone ?? undefined,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

/**
 * The inverse of startOfDayInTimeZone: given an EXPLICIT "YYYY-MM-DD" (e.g.
 * a date-range picker's own selected value, which must be read as the
 * SITE's own calendar date, never the browser's), returns the UTC instant
 * of that calendar date's local midnight in `timeZone`.
 *
 * Technique: probes local NOON (not midnight) UTC for that calendar date,
 * then reuses startOfDayInTimeZone's own offset-correction on that probe.
 * Noon is deliberately chosen so the probe instant still falls on the SAME
 * calendar date once read back in `timeZone`, for any zone within +/-11h of
 * UTC -- every timezone this product currently configures a site with. A
 * timezone offset beyond +/-12h (e.g. Pacific/Kiribati, UTC+14) is not
 * handled and none is currently configured.
 */
export function siteLocalDateToUtcInstant(dateKey: string, timeZone: string | null | undefined): Date {
  const year = Number(dateKey.slice(0, 4));
  const month = Number(dateKey.slice(5, 7));
  const day = Number(dateKey.slice(8, 10));
  const noonProbe = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
  return startOfDayInTimeZone(noonProbe, timeZone);
}
