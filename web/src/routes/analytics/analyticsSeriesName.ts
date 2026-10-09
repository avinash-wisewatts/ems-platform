/**
 * Customer-facing series names, shared by the chart legend and tooltip, the
 * Statistics table and Data quality so one series reads the same everywhere.
 *
 * Qualifiers are never shown (D83): System is the plain series name, phase
 * series are P1-P3, E1-E3, Ex1-Ex3 etc. (D55, D63, D74). Registry codes are
 * never shown either: a missing label falls back to the catalogue's label,
 * then to a generic word.
 */
import type { AnalyticsCatalogResponse, AnalyticsDataPointCode, AnalyticsSeries } from "../../api/types";

/** Phase series labels (D55, D63, D74): P1-P3, I1-I3, V1-V3, PF1-PF3,
 *  E1-E3, Ex1-Ex3. */
const PHASE_PREFIX: Readonly<Record<string, string>> = {
  ACTIVE_POWER: "P",
  CURRENT: "I",
  VOLTAGE_LINE_NEUTRAL: "V",
  POWER_FACTOR: "PF",
  ENERGY_IMPORT: "E",
  ENERGY_EXPORT: "Ex",
};
const PHASE_NUMBER: Readonly<Record<string, string>> = { L1: "1", L2: "2", L3: "3" };

const FALLBACK_ASSET = "Asset";
const FALLBACK_DATA_POINT = "Data point";

/** The catalogue's asset name, if the catalogue still lists the asset. */
export function catalogAssetName(catalog: AnalyticsCatalogResponse | null | undefined, assetId: string): string | null {
  return catalog?.assets.find((a) => a.asset_id === assetId)?.asset_name ?? null;
}

/** The catalogue's label for a data point (the same on every asset). */
export function catalogDataPointLabel(
  catalog: AnalyticsCatalogResponse | null | undefined,
  dataPoint: AnalyticsDataPointCode,
): string | null {
  for (const asset of catalog?.assets ?? []) {
    const point = asset.data_points.find((p) => p.data_point === dataPoint);
    if (point) return point.label;
  }
  return null;
}

/** "Asset · Data point" for a selection, without a series behind it. */
export function selectionName(
  catalog: AnalyticsCatalogResponse | null | undefined,
  assetId: string,
  dataPoint: AnalyticsDataPointCode,
): string {
  const asset = catalogAssetName(catalog, assetId) ?? FALLBACK_ASSET;
  return `${asset} · ${catalogDataPointLabel(catalog, dataPoint) ?? FALLBACK_DATA_POINT}`;
}

/** Legend / tooltip / table name: "Asset · Data point" for System, "Asset - P1"
 *  for a phase series. */
export function seriesName(s: AnalyticsSeries, catalog?: AnalyticsCatalogResponse | null): string {
  const asset = s.asset_name ?? catalogAssetName(catalog, s.asset_id) ?? FALLBACK_ASSET;
  const label = s.label ?? catalogDataPointLabel(catalog, s.data_point) ?? FALLBACK_DATA_POINT;
  const phase = PHASE_NUMBER[s.qualifier];
  if (phase) {
    const prefix = PHASE_PREFIX[s.data_point];
    return prefix ? `${asset} - ${prefix}${phase}` : `${asset} · ${label} ${phase}`;
  }
  return `${asset} · ${label}`;
}

/** Energy is the summed data point (business rule 10): it has a Total and
 *  the Energy-only Data quality wording. */
export function isEnergySeries(s: Pick<AnalyticsSeries, "aggregation">): boolean {
  return s.aggregation === "sum";
}
