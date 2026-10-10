/**
 * Analytics CSV (F7) -- pure, no React, no DOM: the applied result as a wide
 * CSV (README "CSV"; EMS-REQ-137, EMS-REQ-139; D28-D31, D77).
 *
 * - Always the full applied range, never the zoomed window (D28): rows come
 *   from the applied response, which the chart's zoom never changes.
 * - Wide format: one row per bucket start (every grid bucket the response
 *   returns, ascending), columns `Timestamp local`, `Timestamp UTC`, then one
 *   column per series in request order -- the chart's order (D29).
 * - A charted (OK) series carries its values; a missing value is blank, never
 *   0 (D30). A selected series that is not charted (no data, not available,
 *   resolution unavailable, data unavailable) stays as an all-blank column
 *   (D77). Combinations the catalogue cannot serve were never requested and
 *   have no column; Data quality lists them.
 * - Column names are the Statistics / Data quality series names with the unit
 *   ("Power-Chiller 1 (kW)", "Energy-E2-AHU 2 (kWh)"), so the same series
 *   reads the same in the table and in the file. Qualifiers and registry codes
 *   are never written (D83).
 * - Values are the API's own numbers, unrounded; nothing is computed here.
 * - Formula injection (CWE-1236): every text cell -- the column names, built
 *   from tenant-entered asset names and labels -- that starts with `=`, `+`,
 *   `-`, `@`, a tab or a line break is prefixed with `'`, so a spreadsheet
 *   shows it as text instead of evaluating it. Values are numbers and are
 *   never prefixed (a negative value stays a number).
 * - No quality or coverage columns in v1 (Product Owner, 2026-10-10).
 * - `Timestamp local` is the bucket start in the site timezone as
 *   "YYYY-MM-DD HH:mm" (24-hour); `Timestamp UTC` is the same instant as
 *   "YYYY-MM-DDTHH:mm:ssZ", which also tells apart the repeated local hour
 *   at a DST fall-back.
 * - Filename with the normalized site name and the inclusive local dates
 *   (D31): Radisson_Blu_analytics_27-Sep-2026_to_30-Sep-2026.csv.
 */
import type { AnalyticsCatalogResponse, AnalyticsSeries, AnalyticsSeriesResponse } from "../../api/types";
import { csvField } from "../../energy/energyExportCsv";
import { neutralizeSpreadsheetText } from "../../export/spreadsheetSafety";
import { localDateKey, type CalendarRange } from "../../time/calendarRanges";
import { seriesName } from "./analyticsSeriesName";

export { neutralizeSpreadsheetText } from "../../export/spreadsheetSafety";

export const CSV_TIMESTAMP_LOCAL = "Timestamp local";
export const CSV_TIMESTAMP_UTC = "Timestamp UTC";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** Column name: "<series name> (<unit>)", or the name alone without a unit. */
export function csvColumnName(s: AnalyticsSeries, catalog?: AnalyticsCatalogResponse | null): string {
  const name = seriesName(s, catalog);
  return s.unit ? `${name} (${s.unit})` : name;
}

/** "YYYY-MM-DD HH:mm" in the site timezone (UTC when unknown). */
export function formatCsvLocalTimestamp(t: number, timeZone: string | null | undefined): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: timeZone ?? "UTC",
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  }).formatToParts(new Date(t));
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")} ${part("hour")}:${part("minute")}`;
}

/** "YYYY-MM-DDTHH:mm:ssZ". */
export function formatCsvUtcTimestamp(t: number): string {
  return `${new Date(t).toISOString().slice(0, 19)}Z`;
}

/** The wide CSV of the applied response; the header alone when nothing was
 *  requested or no bucket was returned. CRLF line endings, as the Energy
 *  export. */
export function buildAnalyticsCsv(
  response: AnalyticsSeriesResponse | null,
  catalog: AnalyticsCatalogResponse | null | undefined,
  timeZone: string | null | undefined,
): string {
  const series = response?.series ?? [];
  // Every series that returns points returns the same grid (a NO_DATA series
  // returns every bucket with null values).
  const starts = new Set<number>();
  for (const s of series) for (const p of s.points) starts.add(Date.parse(p.bucket_start));
  const rows = [...starts].sort((a, b) => a - b);
  const values = series.map((s) =>
    s.status === "OK" ? new Map(s.points.map((p) => [Date.parse(p.bucket_start), p.value])) : null,
  );

  const header = [CSV_TIMESTAMP_LOCAL, CSV_TIMESTAMP_UTC, ...series.map((s) => csvColumnName(s, catalog))];
  const lines = [header.map((h) => csvField(neutralizeSpreadsheetText(h))).join(",")];
  for (const t of rows) {
    const cells = [formatCsvLocalTimestamp(t, timeZone), formatCsvUtcTimestamp(t), ...values.map((v) => v?.get(t) ?? null)];
    lines.push(cells.map(csvField).join(","));
  }
  return lines.map((line) => `${line}\r\n`).join("");
}

/** "Radisson Blu" -> "Radisson_Blu": letters and digits kept, every other run
 *  of characters one underscore. */
export function normalizeSiteName(name: string | null | undefined): string {
  const normalized = (name ?? "").replace(/[^\p{L}\p{N}]+/gu, "_").replace(/^_+|_+$/g, "");
  return normalized || "Site";
}

/** "2026-09-27" -> "27-Sep-2026". */
function filenameDate(key: string): string {
  return `${key.slice(8, 10)}-${MONTHS[Number(key.slice(5, 7)) - 1]}-${key.slice(0, 4)}`;
}

/** <Site>_analytics_<first local date>_to_<last local date>.csv; the applied
 *  range's end is exclusive, so the last date is the one its final instant
 *  falls on. */
export function analyticsCsvFilename(
  siteName: string | null | undefined,
  range: CalendarRange,
  timeZone: string | null | undefined,
): string {
  const from = localDateKey(new Date(Date.parse(range.from)), timeZone);
  const to = localDateKey(new Date(Math.max(Date.parse(range.from), Date.parse(range.to) - 1)), timeZone);
  return `${normalizeSiteName(siteName)}_analytics_${filenameDate(from)}_to_${filenameDate(to)}.csv`;
}
