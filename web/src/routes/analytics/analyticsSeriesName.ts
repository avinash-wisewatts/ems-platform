/**
 * Customer-facing series names (PO naming convention, 2026-10-09), shared by
 * the chart, the Statistics table and Data quality so one series is named by
 * the same rule everywhere:
 *
 * - Chart legend and tooltip: "<Asset name>-<code>" -- System Chiller 1-P,
 *   Chiller 1-Q, Chiller 1-V, Chiller 1-I, Chiller 1-PF, Chiller 1-F; 3 Phase
 *   Chiller 1-P1 ... Chiller 1-PF3.
 * - Statistics and Data quality: "<Measurement name>[-<code><phase>]-<Asset
 *   name>" -- System Power-Chiller 1, phase Reactive Power-Q2-Chiller 1, so
 *   the same measurement on different assets never reads the same.
 * - Energy and Energy Export keep their readable names: Chiller 1-Energy,
 *   Chiller 1-Energy Export; phases E1-E3 and Ex1-Ex3 (D55).
 * - Line to Line Voltage phases are V12/V23/V31, taken from the existing
 *   source mapping (Eniscope U1/U2/U3 -> L12/L23/L31), which is still to be
 *   verified (README open question). Its System series has no agreed code
 *   and reads by name: Chiller 1-Line to Line Voltage.
 *
 * Qualifiers and registry codes are never shown (D83): a data point without
 * a code reads by its label, a missing label falls back to the catalogue's
 * label, then to a generic word.
 */
import type { AnalyticsCatalogResponse, AnalyticsDataPointCode, AnalyticsSeries } from "../../api/types";

/** System series codes (chart only). Energy, Energy Export and Line to Line
 *  Voltage have none and use their name. */
const SYSTEM_CODE: Readonly<Record<string, string>> = {
  ACTIVE_POWER: "P",
  REACTIVE_POWER: "Q",
  VOLTAGE_LINE_NEUTRAL: "V",
  CURRENT: "I",
  POWER_FACTOR: "PF",
  FREQUENCY: "F",
};
/** Phase series codes: P1-P3, Q1-Q3, V1-V3, I1-I3, PF1-PF3, E1-E3, Ex1-Ex3,
 *  line-to-line V12/V23/V31. */
const PHASE_CODE: Readonly<Record<string, string>> = {
  ACTIVE_POWER: "P",
  REACTIVE_POWER: "Q",
  VOLTAGE_LINE_NEUTRAL: "V",
  VOLTAGE_LINE_LINE: "V",
  CURRENT: "I",
  POWER_FACTOR: "PF",
  ENERGY_IMPORT: "E",
  ENERGY_EXPORT: "Ex",
};
const PHASE_NUMBER: Readonly<Record<string, string>> = {
  L1: "1",
  L2: "2",
  L3: "3",
  L12: "12",
  L23: "23",
  L31: "31",
};

const SEPARATOR = "-";
const FALLBACK_ASSET = "Asset";
/** Generic word for a data point without a label (never its registry code). */
export const FALLBACK_DATA_POINT = "Data point";

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

/** "P1", "V12"; a data point without a phase code reads "<label> 1". */
function phaseSuffix(dataPoint: string, phase: string, label: string): string {
  const code = PHASE_CODE[dataPoint];
  return code ? `${code}${phase}` : `${label} ${phase}`;
}

/** Statistics / Data quality name of a selection without a series behind it:
 *  "Power-Chiller 1". */
export function selectionName(
  catalog: AnalyticsCatalogResponse | null | undefined,
  assetId: string,
  dataPoint: AnalyticsDataPointCode,
): string {
  const asset = catalogAssetName(catalog, assetId) ?? FALLBACK_ASSET;
  return `${catalogDataPointLabel(catalog, dataPoint) ?? FALLBACK_DATA_POINT}${SEPARATOR}${asset}`;
}

/** Chart legend and tooltip name: "Chiller 1-P", "Chiller 1-P1",
 *  "Chiller 1-Energy". */
export function chartSeriesName(s: AnalyticsSeries, catalog?: AnalyticsCatalogResponse | null): string {
  const asset = s.asset_name ?? catalogAssetName(catalog, s.asset_id) ?? FALLBACK_ASSET;
  const label = s.label ?? catalogDataPointLabel(catalog, s.data_point) ?? FALLBACK_DATA_POINT;
  const phase = PHASE_NUMBER[s.qualifier];
  const suffix = phase ? phaseSuffix(s.data_point, phase, label) : (SYSTEM_CODE[s.data_point] ?? label);
  return `${asset}${SEPARATOR}${suffix}`;
}

/** Statistics and Data quality name: "Power-Chiller 1",
 *  "Reactive Power-Q1-Chiller 1", "Energy-E2-AHU 2". */
export function seriesName(s: AnalyticsSeries, catalog?: AnalyticsCatalogResponse | null): string {
  const asset = s.asset_name ?? catalogAssetName(catalog, s.asset_id) ?? FALLBACK_ASSET;
  const label = s.label ?? catalogDataPointLabel(catalog, s.data_point) ?? FALLBACK_DATA_POINT;
  const phase = PHASE_NUMBER[s.qualifier];
  let measurement = label;
  if (phase) {
    measurement = PHASE_CODE[s.data_point] ? `${label}${SEPARATOR}${phaseSuffix(s.data_point, phase, label)}` : `${label} ${phase}`;
  }
  return `${measurement}${SEPARATOR}${asset}`;
}

/** Energy is the summed data point (business rule 10): it has a Total and
 *  the Energy-only Data quality wording. */
export function isEnergySeries(s: Pick<AnalyticsSeries, "aggregation">): boolean {
  return s.aggregation === "sum";
}
