/**
 * Analytics Data quality (F6) -- pure, no React: the applied query's series
 * response as the Data quality section's groups and as the chart tooltip's
 * per-period lines.
 *
 * Specification: docs/07-features/analytics/README.md "Data quality"
 * (ADR-022 Amendment 6, DQ1-DQ23). Everything comes from the API's own
 * fields (Amendment 6 "Backend mapping"); nothing is inferred:
 *   1 Series not shown in chart  -- series status / status_reasons, and the
 *                                   selections the catalogue cannot serve (D4)
 *   2 Incomplete data            -- bucket interval counts
 *   3 Meter resets and rollovers -- RESET_DETECTED / ROLLOVER_DETECTED
 *   4 No recent data             -- series stale and last_data_at
 *   5 Values after missing readings -- GAPS_DETECTED
 *   6 Reconstructed timing       -- RECONSTRUCTED_TIMING / reconstructed_intervals
 *   7 Shown as System values     -- 3 Phase with a TOTAL (System) series
 *
 * A group is present only when its condition applies; with none the section
 * is absent (general rule). Internal status, reason and flag codes are never
 * part of the output.
 */
import type {
  AnalyticsCatalogResponse,
  AnalyticsSeries,
  AnalyticsSeriesPoint,
  AnalyticsSeriesResponse,
} from "../../api/types";
import type { AnalyticsSelection } from "../../api/endpoints";
import { localDateKey } from "../../time/calendarRanges";
import { formatSiteLocalDateTime } from "../../time/siteLocalTicks";
import { formatDateKey } from "./AnalyticsDateRange";
import { isEnergySeries, selectionName, seriesName } from "./analyticsSeriesName";

export type DataQualityGroupId =
  | "not-shown"
  | "incomplete"
  | "resets"
  | "no-recent-data"
  | "after-missing"
  | "reconstructed"
  | "system-values";

export type DataQualityEntry = { key: string; name: string; lines: string[] };

export type DataQualityGroup = {
  id: DataQualityGroupId;
  /** e.g. "Incomplete data · 2 series". */
  heading: string;
  explanation: string[];
  entries: DataQualityEntry[];
};

/** Approved wording (README "Data quality" table). */
export const DQ_TEXT = {
  notShownHeading: "Series not shown in chart",
  incompleteHeading: "Incomplete data",
  incompleteExplanation:
    "Data is incomplete for the selected range. Some expected meter readings were not received or could not be used.",
  incompleteEnergyExplanation:
    "Energy used while readings were missing can appear in the next value after readings resume. Energy from readings that could not be used is not included.",
  resetsHeading: "Meter resets and rollovers",
  resetsExplanation:
    "The meter's cumulative Energy register changed unexpectedly or rolled over during the selected range. Energy values around these events may be affected.",
  noRecentHeading: "No recent data",
  noRecentExplanation:
    "The latest available data for these series is older than expected. The chart has no values after the time shown.",
  afterMissingHeading: "Values after missing readings",
  afterMissingExplanation:
    "After missing readings, the next value includes Energy used while readings were missing. It is shown in the period when readings resumed, because when that Energy was used is not known.",
  reconstructedHeading: "Reconstructed timing",
  reconstructedExplanation:
    "Some Energy values are reconstructed when valid meter data arrives late or after a data gap. Totals come from the meter; only the timing is reconstructed.",
  systemValuesHeading: "Shown as System values",
  systemValuesExplanation:
    "3 Phase is selected, but per-phase values are not available for these series. Their System values are shown.",
  // "Series not shown in chart" reason lines (approved 2026-09-29).
  reasonNotAssigned: "This data point was not assigned to the asset during the selected range.",
  reasonFuture: "The selected range is in the future.",
  reasonNoData: "No data available for the selected range.",
  reasonNotAvailable: "This selection is not available.",
  reasonResolutionCoarse: "Data is not available at the selected resolution for this site.",
  reasonPolicyGap: "Data is unavailable for part of the selected range.",
  reasonPolicyChange: "Data availability changed during the selected range.",
  reasonTimezone: "Daily data is not available consistently for the selected range.",
  // Tooltip lines.
  tipNotReceived: "Incomplete: some readings not received",
  tipNotUsed: "Incomplete: some readings could not be used",
  tipNotReceivedOrNotUsed: "Incomplete: some readings not received or could not be used",
  tipNoneReceived: "Incomplete: no readings received",
  tipNoneUsable: "Incomplete: readings could not be used",
  tipReset: "Meter reset",
  tipRollover: "Meter rollover",
  tipAfterMissing: "Includes Energy used while readings were missing",
  tipReconstructed: "Timing reconstructed",
} as const;

export function reasonBeforeFloor(date: string): string {
  return `Data is not available at this resolution for the full selected range. Data is available from ${date}.`;
}

// ---- Durations and periods ------------------------------------------------------

const UNITS: readonly [string, number][] = [
  ["d", 86_400],
  ["h", 3_600],
  ["min", 60],
  ["s", 1],
];

/** A duration in its two largest units, e.g. "2 h 15 min", "1 d 3 h", "45 min". */
export function formatDuration(seconds: number): string {
  let rest = Math.max(0, Math.round(seconds));
  const parts: string[] = [];
  for (const [unit, size] of UNITS) {
    if (parts.length === 2) break;
    const n = Math.floor(rest / size);
    rest -= n * size;
    // Once the largest unit is found the next one is shown only when non-zero.
    if (n > 0) parts.push(`${n} ${unit}`);
    else if (parts.length === 1) break;
  }
  return parts.length > 0 ? parts.join(" ") : "0 min";
}

/** Seconds per interval of a bucket -- the site's capture interval: the
 *  bucket width over its expected interval count. Null when unknown. */
function intervalSeconds(p: AnalyticsSeriesPoint): number | null {
  if (!p.expected_intervals || p.expected_intervals <= 0) return null;
  return (Date.parse(p.bucket_end) - Date.parse(p.bucket_start)) / 1000 / p.expected_intervals;
}

/** "{time} – {time} · {k} periods", or "{time} · 1 period"; times are the
 *  first and last affected periods' starts, site-local. */
export function periodRange(points: readonly AnalyticsSeriesPoint[], timeZone: string | null | undefined): string {
  const first = Date.parse(points[0]!.bucket_start);
  if (points.length === 1) return `${formatSiteLocalDateTime(first, timeZone)} · 1 period`;
  const last = Date.parse(points[points.length - 1]!.bucket_start);
  return `${formatSiteLocalDateTime(first, timeZone)} – ${formatSiteLocalDateTime(last, timeZone)} · ${points.length} periods`;
}

// ---- Per-bucket conditions --------------------------------------------------------

/** Expected, elapsed intervals with no reading, and readings that could not
 *  be used (DQ1-DQ7). Reconstructed intervals count as accounted for; the
 *  API already leaves out what is not expected (first-ever reading,
 *  unassigned, before the first / after the latest data, future). */
export function incompleteCounts(p: AnalyticsSeriesPoint): { notReceived: number; notUsable: number; accepted: number } {
  const accepted = p.valid_intervals + p.reconstructed_intervals;
  const notUsable = p.invalid_intervals;
  const notReceived = Math.max(0, (p.assigned_expected_intervals ?? 0) - accepted - notUsable);
  return { notReceived, notUsable, accepted };
}

function isIncomplete(p: AnalyticsSeriesPoint): boolean {
  const c = incompleteCounts(p);
  return c.notReceived > 0 || c.notUsable > 0;
}

function incompleteTooltip(p: AnalyticsSeriesPoint): string | null {
  const { notReceived, notUsable, accepted } = incompleteCounts(p);
  if (notReceived === 0 && notUsable === 0) return null;
  if (accepted === 0 && notUsable === 0) return DQ_TEXT.tipNoneReceived;
  if (accepted === 0 && notReceived === 0) return DQ_TEXT.tipNoneUsable;
  if (notUsable === 0) return DQ_TEXT.tipNotReceived;
  if (notReceived === 0) return DQ_TEXT.tipNotUsed;
  return DQ_TEXT.tipNotReceivedOrNotUsed;
}

/** An elapsed period after the latest data of a series with no recent data. */
function isAfterLatestData(s: AnalyticsSeries, p: AnalyticsSeriesPoint): boolean {
  return s.stale === true && s.last_data_at != null && p.data_state === "AFTER_LATEST_DATA" && p.bucket_state !== "FUTURE";
}

const has = (p: AnalyticsSeriesPoint, flag: AnalyticsSeriesPoint["evidence_flags"][number]) =>
  p.evidence_flags.includes(flag);

/**
 * One period's Data quality lines for the tooltip, in group order (D22,
 * DQ9). Groups 1 and 7 have no tooltip line.
 */
export function bucketQualityNotes(
  s: AnalyticsSeries,
  p: AnalyticsSeriesPoint,
  timeZone: string | null | undefined,
): string[] {
  const notes: string[] = [];
  const incomplete = incompleteTooltip(p);
  if (incomplete) notes.push(incomplete);
  if (has(p, "RESET_DETECTED")) notes.push(DQ_TEXT.tipReset);
  if (has(p, "ROLLOVER_DETECTED")) notes.push(DQ_TEXT.tipRollover);
  if (isAfterLatestData(s, p)) {
    notes.push(`No data available after ${formatSiteLocalDateTime(Date.parse(s.last_data_at!), timeZone)}`);
  }
  if (has(p, "GAPS_DETECTED")) notes.push(DQ_TEXT.tipAfterMissing);
  if (has(p, "RECONSTRUCTED_TIMING")) notes.push(DQ_TEXT.tipReconstructed);
  return notes;
}

// ---- Groups ---------------------------------------------------------------------------

/** The customer reason line for a series that is not charted. */
export function notShownReason(s: AnalyticsSeries, timeZone: string | null | undefined): string {
  const reasons = s.status_reasons;
  switch (s.status) {
    case "NO_DATA":
      if (reasons.includes("NOT_ASSIGNED_IN_RANGE")) return DQ_TEXT.reasonNotAssigned;
      if (reasons.includes("RANGE_IN_FUTURE")) return DQ_TEXT.reasonFuture;
      return DQ_TEXT.reasonNoData;
    case "RESOLUTION_UNAVAILABLE":
      if (reasons.includes("CAPTURE_INTERVAL_TOO_COARSE")) return DQ_TEXT.reasonResolutionCoarse;
      if (s.resolution_available_from) {
        return reasonBeforeFloor(formatDateKey(localDateKey(new Date(s.resolution_available_from), timeZone)));
      }
      return DQ_TEXT.reasonResolutionCoarse;
    case "DATA_UNAVAILABLE":
      // All reasons that apply are listed by the API; show the first in the
      // table's order.
      if (reasons.includes("CAPTURE_POLICY_GAP")) return DQ_TEXT.reasonPolicyGap;
      if (reasons.includes("CAPTURE_POLICY_CHANGE")) return DQ_TEXT.reasonPolicyChange;
      if (reasons.includes("TIMEZONE_MISMATCH")) return DQ_TEXT.reasonTimezone;
      return DQ_TEXT.reasonNoData;
    case "NOT_AVAILABLE":
    default:
      return DQ_TEXT.reasonNotAvailable;
  }
}

const seriesKey = (s: AnalyticsSeries) => `${s.asset_id}:${s.data_point}:${s.qualifier}`;

export type DataQualityInput = {
  /** Selected pairs the catalogue cannot serve (never requested, D4). */
  unavailable: readonly AnalyticsSelection[];
  /** Selection order: the draft's assets x data points. */
  order: readonly AnalyticsSelection[];
  response: AnalyticsSeriesResponse | null;
};

/** Group 1: each series not charted once, in selection order. */
function notShownEntries(
  input: DataQualityInput,
  catalog: AnalyticsCatalogResponse | null | undefined,
  timeZone: string | null | undefined,
): DataQualityEntry[] {
  const series = input.response?.series ?? [];
  const unavailable = new Set(input.unavailable.map((u) => `${u.assetId}:${u.dataPoint}`));
  const entries: DataQualityEntry[] = [];
  const seen = new Set<AnalyticsSeries>();
  for (const pair of input.order) {
    const pairKey = `${pair.assetId}:${pair.dataPoint}`;
    if (unavailable.has(pairKey)) {
      entries.push({
        key: `unavailable:${pairKey}`,
        name: selectionName(catalog, pair.assetId, pair.dataPoint),
        lines: [DQ_TEXT.reasonNotAvailable],
      });
      continue;
    }
    for (const s of series) {
      if (s.asset_id !== pair.assetId || s.data_point !== pair.dataPoint || seen.has(s)) continue;
      seen.add(s);
      if (s.status !== "OK") entries.push({ key: seriesKey(s), name: seriesName(s, catalog), lines: [notShownReason(s, timeZone)] });
    }
  }
  // Anything the API returned outside the selection order (never expected).
  for (const s of series) {
    if (!seen.has(s) && s.status !== "OK") {
      entries.push({ key: seriesKey(s), name: seriesName(s, catalog), lines: [notShownReason(s, timeZone)] });
    }
  }
  return entries;
}

function incompleteEntry(s: AnalyticsSeries, name: string, timeZone: string | null | undefined): DataQualityEntry | null {
  const affected = s.points.filter(isIncomplete);
  if (affected.length === 0) return null;
  let notReceived = 0;
  let notUsable = 0;
  let durationKnown = true;
  for (const p of affected) {
    const c = incompleteCounts(p);
    const width = intervalSeconds(p);
    if (width == null) {
      durationKnown = false;
      continue;
    }
    notReceived += c.notReceived * width;
    notUsable += c.notUsable * width;
  }
  const durations: string[] = [];
  if (durationKnown && notReceived > 0) durations.push(`Not received: ${formatDuration(notReceived)}`);
  if (durationKnown && notUsable > 0) durations.push(`Could not be used: ${formatDuration(notUsable)}`);
  const lines = durations.length > 0 ? [durations.join(" · ")] : [];
  lines.push(periodRange(affected, timeZone));
  return { key: seriesKey(s), name, lines };
}

function resetEntry(s: AnalyticsSeries, name: string, timeZone: string | null | undefined): DataQualityEntry | null {
  const lines: string[] = [];
  for (const p of s.points) {
    const at = formatSiteLocalDateTime(Date.parse(p.bucket_start), timeZone);
    if (has(p, "RESET_DETECTED")) lines.push(`${DQ_TEXT.tipReset} · ${at}`);
    if (has(p, "ROLLOVER_DETECTED")) lines.push(`${DQ_TEXT.tipRollover} · ${at}`);
  }
  return lines.length > 0 ? { key: seriesKey(s), name, lines } : null;
}

function noRecentEntry(s: AnalyticsSeries, name: string, asOf: string | undefined, timeZone: string | null | undefined): DataQualityEntry | null {
  if (s.stale !== true || s.last_data_at == null) return null;
  const last = Date.parse(s.last_data_at);
  const parts = [`Latest data: ${formatSiteLocalDateTime(last, timeZone)}`];
  if (asOf) parts.push(`${formatDuration((Date.parse(asOf) - last) / 1000)} before the chart was updated`);
  return { key: seriesKey(s), name, lines: [parts.join(" · ")] };
}

function afterMissingEntry(s: AnalyticsSeries, name: string, timeZone: string | null | undefined): DataQualityEntry | null {
  const affected = s.points.filter((p) => has(p, "GAPS_DETECTED"));
  return affected.length > 0 ? { key: seriesKey(s), name, lines: [periodRange(affected, timeZone)] } : null;
}

function reconstructedEntry(s: AnalyticsSeries, name: string, timeZone: string | null | undefined): DataQualityEntry | null {
  const affected = s.points.filter((p) => has(p, "RECONSTRUCTED_TIMING") || p.reconstructed_intervals > 0);
  if (affected.length === 0) return null;
  let seconds = 0;
  let known = true;
  for (const p of affected) {
    const width = intervalSeconds(p);
    if (width == null) known = false;
    else seconds += p.reconstructed_intervals * width;
  }
  const lines = known && seconds > 0 ? [`Timing reconstructed: ${formatDuration(seconds)}`] : [];
  lines.push(periodRange(affected, timeZone));
  return { key: seriesKey(s), name, lines };
}

function group(id: DataQualityGroupId, title: string, explanation: string[], entries: DataQualityEntry[], countSuffix = " series"): DataQualityGroup | null {
  if (entries.length === 0) return null;
  return { id, heading: `${title} · ${entries.length}${countSuffix}`, explanation, entries };
}

/**
 * The Data quality groups of an applied query, in the fixed order (DQ9,
 * DQ23). Charted series follow the Statistics order (the response order);
 * "Series not shown" follows the selection order. Empty when no condition
 * applies -- the section is then absent.
 */
export function buildDataQuality(
  input: DataQualityInput,
  catalog: AnalyticsCatalogResponse | null | undefined,
  timeZone: string | null | undefined,
): DataQualityGroup[] {
  const response = input.response;
  const charted = (response?.series ?? []).filter((s) => s.status === "OK");
  const named = charted.map((s) => ({ s, name: seriesName(s, catalog) }));
  const collect = (f: (s: AnalyticsSeries, name: string) => DataQualityEntry | null) =>
    named.flatMap(({ s, name }) => {
      const entry = f(s, name);
      return entry ? [entry] : [];
    });

  const incomplete = collect((s, name) => incompleteEntry(s, name, timeZone));
  const incompleteExplanation: string[] = [DQ_TEXT.incompleteExplanation];
  if (charted.some((s) => isEnergySeries(s) && s.points.some(isIncomplete))) {
    incompleteExplanation.push(DQ_TEXT.incompleteEnergyExplanation);
  }

  const groups = [
    group("not-shown", DQ_TEXT.notShownHeading, [], notShownEntries(input, catalog, timeZone), ""),
    group("incomplete", DQ_TEXT.incompleteHeading, incompleteExplanation, incomplete),
    group("resets", DQ_TEXT.resetsHeading, [DQ_TEXT.resetsExplanation], collect((s, name) => resetEntry(s, name, timeZone))),
    group(
      "no-recent-data",
      DQ_TEXT.noRecentHeading,
      [DQ_TEXT.noRecentExplanation],
      collect((s, name) => noRecentEntry(s, name, response?.as_of, timeZone)),
    ),
    group(
      "after-missing",
      DQ_TEXT.afterMissingHeading,
      [DQ_TEXT.afterMissingExplanation],
      collect((s, name) => afterMissingEntry(s, name, timeZone)),
    ),
    group(
      "reconstructed",
      DQ_TEXT.reconstructedHeading,
      [DQ_TEXT.reconstructedExplanation],
      collect((s, name) => reconstructedEntry(s, name, timeZone)),
    ),
    group(
      "system-values",
      DQ_TEXT.systemValuesHeading,
      [DQ_TEXT.systemValuesExplanation],
      response?.phase === "three_phase"
        ? collect((s, name) => (s.qualifier === "TOTAL" ? { key: seriesKey(s), name, lines: [] } : null))
        : [],
    ),
  ];
  return groups.filter((g): g is DataQualityGroup => g !== null);
}
