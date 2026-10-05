/**
 * Analytics chart model (F5) -- pure, no React: the applied query's series
 * response mapped onto the chart foundation, and the chart card title.
 *
 * Rules (docs/07-features/analytics/README.md "Chart", "Date and time range"):
 * - Only series with status OK are drawn; any other series is omitted from
 *   the chart and the legend (D6) -- Data quality reports it (F6).
 * - Every grid bucket is kept: a null value (future, gap, no data) is a gap,
 *   never 0 (D16); the in-progress bucket is drawn as returned (D17).
 * - The X axis covers exactly the applied range (D24).
 * - Card title "<N assets | asset name>, <range> – <resolution>, <phase>".
 */
import type { AnalyticsCatalogResponse, AnalyticsSeries, AnalyticsSeriesResponse } from "../../api/types";
import type { ChartBucket, ChartSeries } from "../../components/ChartFrame";
import { addDays, localDateKey, localMidnightUtc, type CalendarRange } from "../../time/calendarRanges";
import { formatSiteLocalDateTime } from "../../time/siteLocalTicks";
import { formatDateKey } from "./AnalyticsDateRange";
import { RESOLUTION_OPTIONS, type AnalyticsDraft } from "./analyticsQuery";
import type { AppliedQuery } from "./useAnalyticsState";

export type AnalyticsChartModel = {
  buckets: ChartBucket[];
  series: ChartSeries[];
  range: { from: number; to: number };
};

/** Phase series labels (D55, D63, D74): P1-P3, I1-I3, V1-V3, PF1-PF3,
 *  E1-E3, Ex1-Ex3. Qualifiers themselves are never shown (D83). */
const PHASE_PREFIX: Readonly<Record<string, string>> = {
  ACTIVE_POWER: "P",
  CURRENT: "I",
  VOLTAGE_LINE_NEUTRAL: "V",
  POWER_FACTOR: "PF",
  ENERGY_IMPORT: "E",
  ENERGY_EXPORT: "Ex",
};
const PHASE_NUMBER: Readonly<Record<string, string>> = { L1: "1", L2: "2", L3: "3" };

/** Legend / tooltip name: "Asset · Data point" for System, "Asset - P1" for
 *  a phase series. */
export function seriesName(s: AnalyticsSeries): string {
  const asset = s.asset_name ?? "";
  const phase = PHASE_NUMBER[s.qualifier];
  if (phase) {
    const prefix = PHASE_PREFIX[s.data_point];
    return prefix ? `${asset} - ${prefix}${phase}` : `${asset} · ${s.label ?? s.data_point} ${phase}`;
  }
  return `${asset} · ${s.label ?? s.data_point}`;
}

/** The applied response as chart buckets and series (OK series only). */
export function buildChartModel(response: AnalyticsSeriesResponse | null, range: CalendarRange): AnalyticsChartModel {
  const drawn = (response?.series ?? []).filter((s) => s.status === "OK");
  const ends = new Map<number, number>();
  for (const s of drawn) {
    for (const p of s.points) ends.set(Date.parse(p.bucket_start), Date.parse(p.bucket_end));
  }
  const buckets = [...ends.entries()].sort((a, b) => a[0] - b[0]).map(([start, end]) => ({ start, end }));
  const series = drawn.map<ChartSeries>((s) => {
    const byStart = new Map(s.points.map((p) => [Date.parse(p.bucket_start), p.value]));
    return {
      key: `${s.asset_id}:${s.data_point}:${s.qualifier}`,
      name: seriesName(s),
      unit: s.unit,
      kind: s.chart_kind,
      values: buckets.map((b) => byStart.get(b.start) ?? null),
    };
  });
  return { buckets, series, range: { from: Date.parse(range.from), to: Date.parse(range.to) } };
}

/** The applied range as inclusive local dates (D15), or local date-times
 *  when it does not run midnight to midnight. */
export function appliedRangeLabel(range: CalendarRange, timeZone: string | null | undefined): string {
  const from = Date.parse(range.from);
  const to = Date.parse(range.to);
  const fromKey = localDateKey(new Date(from), timeZone);
  const toKey = localDateKey(new Date(to), timeZone);
  const wholeDays =
    localMidnightUtc(fromKey, timeZone).getTime() === from && localMidnightUtc(toKey, timeZone).getTime() === to;
  if (!wholeDays) return `${formatSiteLocalDateTime(from, timeZone)} – ${formatSiteLocalDateTime(to, timeZone)}`;
  const lastKey = addDays(toKey, -1);
  return lastKey === fromKey ? formatDateKey(fromKey) : `${formatDateKey(fromKey)} – ${formatDateKey(lastKey)}`;
}

function resolutionLabel(response: AnalyticsSeriesResponse | null, draft: AnalyticsDraft): string {
  // The resolution actually served (Auto resolved); the requested one when
  // nothing could be requested.
  const value = response?.resolution ?? draft.resolution;
  return RESOLUTION_OPTIONS.find((o) => o.value === value)?.label ?? value;
}

/** "<N assets | asset name>, <range> – <resolution>, <phase>". */
export function chartTitle(
  applied: Pick<AppliedQuery, "draft" | "range" | "response">,
  catalog: AnalyticsCatalogResponse | null,
  timeZone: string | null | undefined,
): string {
  const { assetIds, phase } = applied.draft;
  const only = assetIds.length === 1 ? assetIds[0] : undefined;
  const assets = only
    ? (catalog?.assets.find((a) => a.asset_id === only)?.asset_name ??
      applied.response?.series.find((s) => s.asset_id === only)?.asset_name ??
      "1 asset")
    : `${assetIds.length} assets`;
  const phaseLabel = phase === "three_phase" ? "3 Phase" : "System";
  return `${assets}, ${appliedRangeLabel(applied.range, timeZone)} – ${resolutionLabel(applied.response, applied.draft)}, ${phaseLabel}`;
}
