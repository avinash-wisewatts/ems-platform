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
 * - The tooltip lists each period's Data quality lines in group order (D22,
 *   DQ9; analyticsDataQualityModel.ts).
 * - Card title "<N assets | asset name>, <range> – <resolution>, <phase>".
 */
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import type { ChartBucket, ChartSeries } from "../../components/ChartFrame";
import { addDays, localDateKey, localMidnightUtc, type CalendarRange } from "../../time/calendarRanges";
import { formatSiteLocalDateTime } from "../../time/siteLocalTicks";
import { formatDateKey } from "./AnalyticsDateRange";
import { bucketQualityNotes } from "./analyticsDataQualityModel";
import { RESOLUTION_OPTIONS, type AnalyticsDraft } from "./analyticsQuery";
import { seriesName } from "./analyticsSeriesName";
import type { AppliedQuery } from "./useAnalyticsState";

export type AnalyticsChartModel = {
  buckets: ChartBucket[];
  series: ChartSeries[];
  range: { from: number; to: number };
};

export { seriesName } from "./analyticsSeriesName";

/** The applied response as chart buckets and series (OK series only), each
 *  bucket carrying its Data quality lines for the tooltip (D22, DQ9). */
export function buildChartModel(
  response: AnalyticsSeriesResponse | null,
  range: CalendarRange,
  catalog?: AnalyticsCatalogResponse | null,
  timeZone?: string | null,
): AnalyticsChartModel {
  const drawn = (response?.series ?? []).filter((s) => s.status === "OK");
  const ends = new Map<number, number>();
  for (const s of drawn) {
    for (const p of s.points) ends.set(Date.parse(p.bucket_start), Date.parse(p.bucket_end));
  }
  const buckets = [...ends.entries()].sort((a, b) => a[0] - b[0]).map(([start, end]) => ({ start, end }));
  const series = drawn.map<ChartSeries>((s) => {
    const byStart = new Map(s.points.map((p) => [Date.parse(p.bucket_start), p]));
    return {
      key: `${s.asset_id}:${s.data_point}:${s.qualifier}`,
      name: seriesName(s, catalog),
      unit: s.unit,
      kind: s.chart_kind,
      values: buckets.map((b) => byStart.get(b.start)?.value ?? null),
      notes: buckets.map((b) => {
        const p = byStart.get(b.start);
        return p ? bucketQualityNotes(s, p, timeZone) : [];
      }),
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
