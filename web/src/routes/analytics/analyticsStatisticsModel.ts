/**
 * Analytics Statistics (F6) -- pure, no React: one row per charted series
 * (README "Statistics"; D19-D21, D26).
 *
 * Every figure is the API's own series summary for the full applied range
 * (never the zoomed window): Total (Energy only), Average, Minimum and
 * Maximum with their times. Nothing is computed here; a value the API does
 * not return is shown as not available. No cross-series totals.
 */
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";
import { isEnergySeries, seriesName } from "./analyticsSeriesName";

export type StatisticsRow = {
  key: string;
  name: string;
  unit: string | null;
  /** Position among charted series: the chart colour. */
  index: number;
  /** undefined = not an Energy series (no Total); null = not available. */
  total: number | null | undefined;
  average: number | null;
  min: number | null;
  minAt: string | null;
  max: number | null;
  maxAt: string | null;
};

export type StatisticsModel = {
  rows: StatisticsRow[];
  /** The Total column is shown only when an Energy series is charted. */
  showTotal: boolean;
};

/** Charted (status OK) series in chart order -- the Statistics order. */
export function buildStatistics(
  response: AnalyticsSeriesResponse | null,
  catalog?: AnalyticsCatalogResponse | null,
): StatisticsModel {
  const charted = (response?.series ?? []).filter((s) => s.status === "OK");
  const rows = charted.map<StatisticsRow>((s, index) => ({
    key: `${s.asset_id}:${s.data_point}:${s.qualifier}`,
    name: seriesName(s, catalog),
    unit: s.unit,
    index,
    total: isEnergySeries(s) ? s.summary.total : undefined,
    average: s.summary.average,
    min: s.summary.min,
    minAt: s.summary.min == null ? null : s.summary.min_at,
    max: s.summary.max,
    maxAt: s.summary.max == null ? null : s.summary.max_at,
  }));
  return { rows, showTotal: charted.some(isEnergySeries) };
}
