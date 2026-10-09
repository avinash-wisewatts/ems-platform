/**
 * Analytics Statistics (F6) -- pure, no React: one row per charted series
 * (README "Statistics"; D19-D21, D26; ADR-022 Amendment 7).
 *
 * Every figure is the API's own series summary for the full applied range
 * (never the zoomed window), and nothing is computed here; a value the API
 * does not return is shown as not available. API semantics (Amendment 7):
 * Total includes the in-progress period (Energy so far); Average, Minimum and
 * Maximum use completed periods only. No cross-series totals.
 *
 * Catch-up disclosure (Amendment 7, decision 2): a Minimum or Maximum whose
 * period the API marks as following missing readings (GAPS_DETECTED) is
 * flagged -- from that evidence only, never from the value's size.
 */
import type { AnalyticsCatalogResponse, AnalyticsSeries, AnalyticsSeriesResponse } from "../../api/types";
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
  /** The Minimum's period includes Energy from missing readings. */
  minAfterMissing: boolean;
  max: number | null;
  maxAt: string | null;
  maxAfterMissing: boolean;
};

export type StatisticsModel = {
  rows: StatisticsRow[];
  /** The Total column is shown only when an Energy series is charted. */
  showTotal: boolean;
  /** Daily periods: Minimum / Maximum show the date only. */
  dateOnly: boolean;
};

/** Whether the API marks the period starting at `at` as following missing readings. */
function afterMissing(s: AnalyticsSeries, at: string | null): boolean {
  if (at == null) return false;
  const t = Date.parse(at);
  return s.points.some((p) => Date.parse(p.bucket_start) === t && p.evidence_flags.includes("GAPS_DETECTED"));
}

/** Charted (status OK) series in chart order -- the Statistics order. */
export function buildStatistics(
  response: AnalyticsSeriesResponse | null,
  catalog?: AnalyticsCatalogResponse | null,
): StatisticsModel {
  const charted = (response?.series ?? []).filter((s) => s.status === "OK");
  const rows = charted.map<StatisticsRow>((s, index) => {
    const minAt = s.summary.min == null ? null : s.summary.min_at;
    const maxAt = s.summary.max == null ? null : s.summary.max_at;
    return {
      key: `${s.asset_id}:${s.data_point}:${s.qualifier}`,
      name: seriesName(s, catalog),
      unit: s.unit,
      index,
      total: isEnergySeries(s) ? s.summary.total : undefined,
      average: s.summary.average,
      min: s.summary.min,
      minAt,
      minAfterMissing: afterMissing(s, minAt),
      max: s.summary.max,
      maxAt,
      maxAfterMissing: afterMissing(s, maxAt),
    };
  });
  return { rows, showTotal: charted.some(isEnergySeries), dateOnly: response?.resolution === "1d" };
}
