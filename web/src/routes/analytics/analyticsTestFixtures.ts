import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse } from "../../api/types";

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
