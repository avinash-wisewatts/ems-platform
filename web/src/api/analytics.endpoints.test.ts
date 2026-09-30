import { describe, expect, expectTypeOf, it } from "vitest";
import { formatAnalyticsSelection, getAnalyticsCatalog, getAnalyticsSeries } from "./endpoints";
import { ContractError, NotAccessibleError } from "./errors";
import type { AnalyticsCatalogResponse, AnalyticsSeriesResponse, AnalyticsSeriesStatus } from "./types";
import { stubFetch } from "../test-utils";

const CATALOG: AnalyticsCatalogResponse = {
  site_id: "site-1",
  site_name: "Coimbatore",
  site_timezone: "Asia/Kolkata",
  limits: { max_data_points: 5, max_assets: 10, max_series: 25 },
  resolutions: [
    { resolution: "1m", max_window_seconds: 259200, default_window_seconds: 129600, available_from: "2026-06-01T00:00:00Z" },
    { resolution: "1d", max_window_seconds: 94608000, default_window_seconds: 47304000, available_from: null },
  ],
  assets: [
    {
      asset_id: "a1",
      asset_name: "Chiller 1",
      asset_type_id: null,
      asset_type_name: null,
      building_name: null,
      floor_name: null,
      space_id: null,
      space_name: null,
      location_path: null,
      data_points: [
        {
          data_point: "ENERGY_IMPORT",
          label: "Energy",
          category: "Energy",
          unit: "kWh",
          chart_kind: "bar",
          aggregation: "sum",
          phases: { system: true, three_phase: false },
          available_from: "2026-01-01T00:00:00Z",
          available_to: null,
        },
      ],
    },
  ],
};

const EMPTY_SUMMARY = { total: null, average: null, min: null, min_at: null, max: null, max_at: null };

const SERIES: AnalyticsSeriesResponse = {
  site_id: "site-1",
  site_timezone: "Asia/Kolkata",
  as_of: "2026-06-15T12:00:00Z",
  from: "2026-06-14T18:30:00Z",
  to: "2026-06-15T18:30:00Z",
  requested_resolution: "auto",
  resolution: "15m",
  phase: "system",
  series: [
    {
      asset_id: "a1",
      asset_name: "Chiller 1",
      data_point: "ENERGY_IMPORT",
      label: "Energy",
      qualifier: "TOTAL",
      unit: "kWh",
      chart_kind: "bar",
      aggregation: "sum",
      status: "OK",
      status_reasons: [],
      resolution_available_from: null,
      first_data_at: "2026-01-01T00:00:00Z",
      last_data_at: "2026-06-15T11:59:00Z",
      stale: false,
      points: [
        {
          bucket_start: "2026-06-14T18:30:00Z",
          bucket_end: "2026-06-14T18:45:00Z",
          value: 12.4,
          min: null,
          max: null,
          bucket_state: "COMPLETE",
          data_state: "MEASURED",
          expected_intervals: 15,
          assigned_expected_intervals: 15,
          valid_intervals: 14,
          invalid_intervals: 1,
          reconstructed_intervals: 0,
          evidence_flags: ["INVALID_INTERVALS"],
          evidence_status: "INVALID_INTERVALS",
          quality: null,
          is_partial: false,
        },
      ],
      summary: {
        total: 12.4,
        average: 12.4,
        min: 12.4,
        min_at: "2026-06-14T18:30:00Z",
        max: 12.4,
        max_at: "2026-06-14T18:30:00Z",
      },
    },
    {
      asset_id: "a2",
      asset_name: null,
      data_point: "ENERGY_EXPORT",
      label: null,
      qualifier: "TOTAL",
      unit: null,
      chart_kind: "bar",
      aggregation: "sum",
      status: "NOT_AVAILABLE",
      status_reasons: [],
      resolution_available_from: null,
      first_data_at: null,
      last_data_at: null,
      stale: null,
      points: [],
      summary: EMPTY_SUMMARY,
    },
  ],
};

const RANGE = { from: "2026-06-14T18:30:00Z", to: "2026-06-15T18:30:00Z" };

describe("Analytics v1 endpoint bindings (ADR-022)", () => {
  it("getAnalyticsCatalog hits GET /api/v1/sites/{site_id}/analytics/catalog with no query", async () => {
    const mock = stubFetch(() => ({ jsonBody: CATALOG }));
    const catalog = await getAnalyticsCatalog("site 1");
    expect(mock.mock.calls[0]![0]).toBe("/api/v1/sites/site%201/analytics/catalog");
    expect(mock.mock.calls[0]![1]?.method).toBe("GET");
    expect(catalog).toEqual(CATALOG);
    expectTypeOf(catalog).toEqualTypeOf<AnalyticsCatalogResponse>();
  });

  it("getAnalyticsSeries sends from/to/resolution/phase and one repeated selection per pair, in order", async () => {
    const mock = stubFetch(() => ({ jsonBody: SERIES }));
    const response = await getAnalyticsSeries("site-1", {
      from: "2026-06-14T18:30:00.000Z",
      to: "2026-06-15T18:30:00.000Z",
      resolution: "15m",
      phase: "three_phase",
      selections: [
        { assetId: "a2", dataPoint: "ENERGY_EXPORT" },
        { assetId: "a1", dataPoint: "ENERGY_IMPORT" },
        { assetId: "a1", dataPoint: "ENERGY_EXPORT" },
      ],
    });
    const url = new URL(mock.mock.calls[0]![0] as string, "http://localhost");
    expect(url.pathname).toBe("/api/v1/sites/site-1/analytics/series");
    expect(url.searchParams.get("from")).toBe("2026-06-14T18:30:00.000Z");
    expect(url.searchParams.get("to")).toBe("2026-06-15T18:30:00.000Z");
    expect(url.searchParams.get("resolution")).toBe("15m");
    expect(url.searchParams.get("phase")).toBe("three_phase");
    expect(url.searchParams.getAll("selection")).toEqual(["a2:ENERGY_EXPORT", "a1:ENERGY_IMPORT", "a1:ENERGY_EXPORT"]);
    expect([...url.searchParams.keys()].sort()).toEqual([
      "from",
      "phase",
      "resolution",
      "selection",
      "selection",
      "selection",
      "to",
    ]);
    expect(response).toEqual(SERIES);
    expectTypeOf(response.series[0]!.status).toEqualTypeOf<AnalyticsSeriesStatus>();
  });

  it("the exact URL encodes each selection's colon", async () => {
    const mock = stubFetch(() => ({ jsonBody: SERIES }));
    await getAnalyticsSeries("site-1", { ...RANGE, selections: [{ assetId: "a1", dataPoint: "ENERGY_IMPORT" }] });
    expect(mock.mock.calls[0]![0]).toBe(
      "/api/v1/sites/site-1/analytics/series?from=2026-06-14T18%3A30%3A00Z&to=2026-06-15T18%3A30%3A00Z&selection=a1%3AENERGY_IMPORT",
    );
  });

  it("omits resolution and phase when not given (the server defaults are auto and system)", async () => {
    const mock = stubFetch(() => ({ jsonBody: SERIES }));
    await getAnalyticsSeries("site-1", { ...RANGE, selections: [{ assetId: "a1", dataPoint: "ENERGY_IMPORT" }] });
    const url = new URL(mock.mock.calls[0]![0] as string, "http://localhost");
    expect(url.searchParams.has("resolution")).toBe(false);
    expect(url.searchParams.has("phase")).toBe(false);
  });

  it("sends resolution=auto explicitly when asked", async () => {
    const mock = stubFetch(() => ({ jsonBody: SERIES }));
    await getAnalyticsSeries("site-1", {
      ...RANGE,
      resolution: "auto",
      selections: [{ assetId: "a1", dataPoint: "ENERGY_IMPORT" }],
    });
    expect(new URL(mock.mock.calls[0]![0] as string, "http://localhost").searchParams.get("resolution")).toBe("auto");
  });

  it("formats a selection as <asset_id>:<DATA_POINT>", () => {
    expect(formatAnalyticsSelection({ assetId: "4f1c", dataPoint: "ENERGY_EXPORT" })).toBe("4f1c:ENERGY_EXPORT");
  });

  it("a server-side validation failure surfaces as a ContractError carrying the 422 code", async () => {
    stubFetch(() => ({ status: 422, jsonBody: { error: "too_many_series", detail: "at most 25 series per request" } }));
    const request = getAnalyticsSeries("site-1", { ...RANGE, selections: [{ assetId: "a1", dataPoint: "ENERGY_IMPORT" }] });
    await expect(request).rejects.toBeInstanceOf(ContractError);
    await expect(request).rejects.toMatchObject({ code: "too_many_series", status: 422 });
  });

  it("an inaccessible or unknown site surfaces as NotAccessibleError (404)", async () => {
    stubFetch(() => ({ status: 404, jsonBody: { error: "not_found", detail: "Site not found or not accessible." } }));
    await expect(getAnalyticsCatalog("other-site")).rejects.toBeInstanceOf(NotAccessibleError);
  });

  it("series come back one per selection, in request order, including unavailable ones without points", async () => {
    stubFetch(() => ({ jsonBody: SERIES }));
    const response = await getAnalyticsSeries("site-1", {
      ...RANGE,
      selections: [
        { assetId: "a1", dataPoint: "ENERGY_IMPORT" },
        { assetId: "a2", dataPoint: "ENERGY_EXPORT" },
      ],
    });
    expect(response.series.map((s) => [s.asset_id, s.data_point, s.status])).toEqual([
      ["a1", "ENERGY_IMPORT", "OK"],
      ["a2", "ENERGY_EXPORT", "NOT_AVAILABLE"],
    ]);
    expect(response.series[1]!.points).toEqual([]);
  });
});
