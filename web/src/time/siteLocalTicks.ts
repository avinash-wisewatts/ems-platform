/**
 * Site-local time-axis ticks and labels (Analytics chart, D24/D25).
 *
 * Ticks fall on the site's own wall-clock boundaries -- local quarter hours,
 * hours, midnights, month starts -- never on the UTC grid, so an IST chart
 * shows 06:00, not 05:30 or :30-offset labels. Label density adapts to the
 * visible range: the finest step that keeps at most `maxTicks` ticks.
 * DST-correct through localDateTimeUtc / localMidnightUtc.
 */
import { addDays, addMonthsClamped, localDateKey, localDateTimeUtc, localMidnightUtc } from "./calendarRanges";

export type TimeTick = { t: number; label: string };

const MINUTE_MS = 60_000;
const DAY_MS = 86_400_000;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Candidate steps, finest first. Sub-day steps divide a day exactly. */
const MINUTE_STEPS = [15, 30, 60, 120, 180, 360, 720];
const DAY_STEPS = [1, 2, 7, 14];
const MONTH_STEPS = [1, 3, 6, 12];

const pad = (n: number) => String(n).padStart(2, "0");

/** "2026-09-01" -> "01 Sep". */
function dayMonth(key: string): string {
  return `${key.slice(8, 10)} ${MONTHS[Number(key.slice(5, 7)) - 1]}`;
}

/** "HH:MM · DD Mon YYYY" in the site timezone (UTC when unknown). */
export function formatSiteLocalDateTime(t: number, timeZone: string | null | undefined): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timeZone ?? "UTC",
    hourCycle: "h23",
    year: "numeric",
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(new Date(t));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${part("hour")}:${part("minute")} · ${part("day")} ${part("month")} ${part("year")}`;
}

function minuteTicks(from: number, to: number, step: number, timeZone: string | null | undefined): TimeTick[] {
  const ticks: TimeTick[] = [];
  const seen = new Set<number>();
  const lastKey = localDateKey(new Date(to), timeZone);
  for (let key = localDateKey(new Date(from), timeZone); key <= lastKey; key = addDays(key, 1)) {
    for (let minutes = 0; minutes < 1440; minutes += step) {
      const t = localDateTimeUtc(key, `${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}`, timeZone).getTime();
      // A wall time inside a DST gap resolves to the instant after it; keep it once.
      if (t < from || t > to || seen.has(t)) continue;
      seen.add(t);
      ticks.push({ t, label: minutes === 0 ? dayMonth(key) : `${pad(Math.floor(minutes / 60))}:${pad(minutes % 60)}` });
    }
  }
  return ticks;
}

function dayTicks(from: number, to: number, step: number, timeZone: string | null | undefined): TimeTick[] {
  const ticks: TimeTick[] = [];
  const lastKey = localDateKey(new Date(to), timeZone);
  for (let key = localDateKey(new Date(from), timeZone); key <= lastKey; key = addDays(key, step)) {
    const t = localMidnightUtc(key, timeZone).getTime();
    if (t >= from && t <= to) ticks.push({ t, label: dayMonth(key) });
  }
  return ticks;
}

function monthTicks(from: number, to: number, step: number, timeZone: string | null | undefined): TimeTick[] {
  const ticks: TimeTick[] = [];
  const startKey = `${localDateKey(new Date(from), timeZone).slice(0, 7)}-01`;
  for (let i = 0; ; i += step) {
    const key = addMonthsClamped(startKey, i);
    const t = localMidnightUtc(key, timeZone).getTime();
    if (t > to) break;
    if (t >= from) ticks.push({ t, label: `${MONTHS[Number(key.slice(5, 7)) - 1]} ${key.slice(0, 4)}` });
  }
  return ticks;
}

/** Ticks for [from, to] (epoch ms) on the site's local grid, at most `maxTicks`. */
export function siteLocalTicks(
  from: number,
  to: number,
  timeZone: string | null | undefined,
  maxTicks = 8,
): TimeTick[] {
  const span = to - from;
  if (!(span > 0)) return [];
  for (const step of MINUTE_STEPS) {
    if (span / (step * MINUTE_MS) <= maxTicks) return minuteTicks(from, to, step, timeZone);
  }
  for (const step of DAY_STEPS) {
    if (span / (step * DAY_MS) <= maxTicks) return dayTicks(from, to, step, timeZone);
  }
  for (const step of MONTH_STEPS) {
    if (span / (step * 30.44 * DAY_MS) <= maxTicks) return monthTicks(from, to, step, timeZone);
  }
  return monthTicks(from, to, 12, timeZone);
}
