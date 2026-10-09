import type { AnalyticsCatalogResponse, AnalyticsSeries, AnalyticsSeriesPoint, AnalyticsSeriesResponse } from "../../api/types";

/** An IST site catalogue: assets a1..a12 with Energy and Energy Export; a1 and
 *  a2 also have per-phase Energy; "x1" serves only Energy Export. */
export function catalogFixture(overrides: Partial<AnalyticsCatalogResponse> = {}): AnalyticsCatalogResponse {
  const point = (data_point: string, label: string, threePhase = false) => ({
    data_point,
    label,
    category: "Energy",
    unit: "kWh",
    chart_kind: "bar" as const,
    aggregation: "sum" as const,
    phases: { system: true, three_phase: threePhase },
    available_from: "2026-01-01T00:00:00Z",
    available_to: null,
    assignment_periods: [{ assigned_from: null as string | null, assigned_to: null as string | null }],
  });
  const asset = (id: string, points: ReturnType<typeof point>[]) => ({
    asset_id: id,
    asset_name: `Asset ${id}`,
    asset_type_id: null,
    asset_type_name: null,
    building_name: null,
    floor_name: null,
    space_id: null,
    space_name: null,
    location_path: null,
    data_points: points,
  });
  const assets = Array.from({ length: 12 }, (_, i) => {
    const id = `a${i + 1}`;
    const threePhase = id === "a1" || id === "a2";
    return asset(id, [point("ENERGY_IMPORT", "Energy", threePhase), point("ENERGY_EXPORT", "Energy Export")]);
  });
  assets.push(asset("x1", [point("ENERGY_EXPORT", "Energy Export")]));
  return {
    site_id: "site-1",
    site_name: "Coimbatore",
    site_timezone: "Asia/Kolkata",
    limits: { max_data_points: 5, max_assets: 10, max_series: 25 },
    resolutions: [
      { resolution: "1m", max_window_seconds: 259200, default_window_seconds: 129600, available_from: null },
      { resolution: "15m", max_window_seconds: 2592000, default_window_seconds: 1296000, available_from: null },
      { resolution: "30m", max_window_seconds: 5184000, default_window_seconds: 2592000, available_from: null },
      { resolution: "1h", max_window_seconds: 15552000, default_window_seconds: 7776000, available_from: null },
      { resolution: "1d", max_window_seconds: 94608000, default_window_seconds: 47304000, available_from: null },
    ],
    assets,
    ...overrides,
  };
}

export function seriesResponseFixture(overrides: Partial<AnalyticsSeriesResponse> = {}): AnalyticsSeriesResponse {
  return {
    site_id: "site-1",
    site_timezone: "Asia/Kolkata",
    as_of: "2026-06-15T12:00:00Z",
    from: "2026-06-14T18:30:00.000Z",
    to: "2026-06-15T18:30:00.000Z",
    requested_resolution: "auto",
    resolution: "15m",
    phase: "system",
    series: [],
    ...overrides,
  };
}

/** 05 Oct 2026, 00:00 IST. */
export const SERIES_FROM = "2026-10-04T18:30:00.000Z";
export const SERIES_TO = "2026-10-05T18:30:00.000Z";
const QUARTER_HOUR = 15 * 60_000;

/** A fully measured 15-minute Energy point at bucket `i` from SERIES_FROM
 *  (60 s capture: 15 expected intervals); override any field. */
export function pointFixture(i: number, value: number | null, overrides: Partial<AnalyticsSeriesPoint> = {}): AnalyticsSeriesPoint {
  const start = Date.parse(SERIES_FROM) + i * QUARTER_HOUR;
  return {
    bucket_start: new Date(start).toISOString(),
    bucket_end: new Date(start + QUARTER_HOUR).toISOString(),
    value,
    min: null,
    max: null,
    bucket_state: "COMPLETE",
    data_state: value == null ? "GAP" : "MEASURED",
    expected_intervals: 15,
    assigned_expected_intervals: 15,
    valid_intervals: value == null ? 0 : 15,
    invalid_intervals: 0,
    reconstructed_intervals: 0,
    evidence_flags: [],
    evidence_status: value == null ? null : "GOOD",
    quality: null,
    is_partial: false,
    ...overrides,
  };
}

/** An OK Energy series for asset `assetId` with the given values. */
export function seriesFixture(
  assetId: string,
  values: (number | null)[],
  overrides: Partial<AnalyticsSeries> = {},
): AnalyticsSeries {
  return {
    asset_id: assetId,
    asset_name: `Asset ${assetId}`,
    data_point: "ENERGY_IMPORT",
    label: "Energy",
    qualifier: "TOTAL",
    unit: "kWh",
    chart_kind: "bar",
    aggregation: "sum",
    status: "OK",
    status_reasons: [],
    resolution_available_from: null,
    first_data_at: SERIES_FROM,
    last_data_at: null,
    stale: false,
    points: values.map((v, i) => pointFixture(i, v)),
    summary: { total: null, average: null, min: null, min_at: null, max: null, max_at: null },
    ...overrides,
  };
}

/** A series the chart does not draw, with no points. */
export function notShownFixture(
  assetId: string,
  status: AnalyticsSeries["status"],
  reasons: AnalyticsSeries["status_reasons"] = [],
  overrides: Partial<AnalyticsSeries> = {},
): AnalyticsSeries {
  return seriesFixture(assetId, [], { status, status_reasons: reasons, first_data_at: null, ...overrides });
}
