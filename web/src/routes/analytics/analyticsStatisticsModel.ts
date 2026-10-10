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
 * Order (Product Owner, 2026-10-10): rows are grouped by data point -- Energy
 * first, then every other data point alphabetically by its customer label --
 * and within a data point by asset name (natural order, so "Chiller 2" comes
 * before "Chiller 10"), then phase (System, then L1-L3 / L12-L31). Minimum and
 * Maximum show values only; their times are not shown.
 *
 * Catch-up disclosure (Amendment 7, decision 2): a Minimum or Maximum whose
 * period the API marks as following missing readings (GAPS_DETECTED) is
 * flagged -- from that evidence only, never from the value's size.
 */
import type { AnalyticsCatalogResponse, AnalyticsSeries, AnalyticsSeriesResponse } from "../../api/types";
import { catalogAssetName, catalogDataPointLabel, isEnergySeries, seriesName } from "./analyticsSeriesName";
import { seriesKey } from "./analyticsSeriesStyles";

export type StatisticsRow = {
  key: string;
  name: string;
  unit: string | null;
  kind: "bar" | "line";
  /** undefined = not an Energy series (no Total); null = not available. */
  total: number | null | undefined;
  average: number | null;
  min: number | null;
  /** The Minimum's period includes Energy from missing readings. */
  minAfterMissing: boolean;
  max: number | null;
  maxAfterMissing: boolean;
};

export type StatisticsGroup = {
  /** The data point (registry code); never shown. */
  dataPoint: string;
  /** Customer label of the data point, e.g. "Energy", "Power". */
  label: string;
  rows: StatisticsRow[];
};

export type StatisticsModel = {
  groups: StatisticsGroup[];
  /** Every row, in display order. */
  rows: StatisticsRow[];
  /** The Total column is shown only when an Energy series is charted. */
  showTotal: boolean;
};

/** Energy (consumed / imported) always leads the table. */
const LEADING_DATA_POINT = "ENERGY_IMPORT";
/** Phase order within a data point and asset. */
const PHASE_ORDER = ["TOTAL", "L1", "L2", "L3", "L12", "L23", "L31"];

const collator = new Intl.Collator("en", { numeric: true, sensitivity: "base" });

/** Whether the API marks the period starting at `at` as following missing readings. */
function afterMissing(s: AnalyticsSeries, at: string | null): boolean {
  if (at == null) return false;
  const t = Date.parse(at);
  return s.points.some((p) => Date.parse(p.bucket_start) === t && p.evidence_flags.includes("GAPS_DETECTED"));
}

function phaseRank(qualifier: string): number {
  const i = PHASE_ORDER.indexOf(qualifier);
  return i < 0 ? PHASE_ORDER.length : i;
}

/** Charted (status OK) series, grouped by data point (Energy first, then by
 *  label) and ordered by asset name and phase within each group. */
export function buildStatistics(
  response: AnalyticsSeriesResponse | null,
  catalog?: AnalyticsCatalogResponse | null,
): StatisticsModel {
  const charted = (response?.series ?? []).filter((s) => s.status === "OK");
  const label = (s: AnalyticsSeries) => s.label ?? catalogDataPointLabel(catalog, s.data_point) ?? s.data_point;
  const asset = (s: AnalyticsSeries) => s.asset_name ?? catalogAssetName(catalog, s.asset_id) ?? "";

  const byDataPoint = new Map<string, AnalyticsSeries[]>();
  for (const s of charted) byDataPoint.set(s.data_point, [...(byDataPoint.get(s.data_point) ?? []), s]);

  const groups = [...byDataPoint.entries()]
    .map(([dataPoint, members]) => ({ dataPoint, label: label(members[0]!), members }))
    .sort((a, b) => {
      if (a.dataPoint === LEADING_DATA_POINT) return -1;
      if (b.dataPoint === LEADING_DATA_POINT) return 1;
      return collator.compare(a.label, b.label) || collator.compare(a.dataPoint, b.dataPoint);
    })
    .map<StatisticsGroup>(({ dataPoint, label: groupLabel, members }) => ({
      dataPoint,
      label: groupLabel,
      rows: [...members]
        .sort(
          (a, b) =>
            collator.compare(asset(a), asset(b)) ||
            collator.compare(a.asset_id, b.asset_id) ||
            phaseRank(a.qualifier) - phaseRank(b.qualifier),
        )
        .map<StatisticsRow>((s) => {
          const minAt = s.summary.min == null ? null : s.summary.min_at;
          const maxAt = s.summary.max == null ? null : s.summary.max_at;
          return {
            key: seriesKey(s),
            name: seriesName(s, catalog),
            unit: s.unit,
            kind: s.chart_kind,
            total: isEnergySeries(s) ? s.summary.total : undefined,
            average: s.summary.average,
            min: s.summary.min,
            minAfterMissing: afterMissing(s, minAt),
            max: s.summary.max,
            maxAfterMissing: afterMissing(s, maxAt),
          };
        }),
    }));

  return { groups, rows: groups.flatMap((g) => g.rows), showTotal: charted.some(isEnergySeries) };
}
