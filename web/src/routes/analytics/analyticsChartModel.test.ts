import { describe, expect, it } from "vitest";
import type { AnalyticsSeries, AnalyticsSeriesPoint } from "../../api/types";
import { appliedRangeLabel, buildChartModel, chartTitle } from "./analyticsChartModel";
import { INITIAL_DRAFT, type AnalyticsDraft } from "./analyticsQuery";
import { catalogFixture, seriesResponseFixture } from "./analyticsTestFixtures";

const Q = 15 * 60_000;
const FROM = "2026-10-04T18:30:00.000Z"; // 05 Oct 2026 00:00 IST
const TO = "2026-10-05T18:30:00.000Z";
const T0 = Date.parse(FROM);
const RANGE = { from: FROM, to: TO };

function point(i: number, value: number | null, bucket_state: AnalyticsSeriesPoint["bucket_state"] = "COMPLETE"): AnalyticsSeriesPoint {
  return {
    bucket_start: new Date(T0 + i * Q).toISOString(),
    bucket_end: new Date(T0 + (i + 1) * Q).toISOString(),
    value,
    min: null,
    max: null,
    bucket_state,
    data_state: bucket_state === "FUTURE" ? "FUTURE" : value == null ? "GAP" : "MEASURED",
    expected_intervals: 15,
    assigned_expected_intervals: bucket_state === "FUTURE" ? 0 : 15,
    valid_intervals: value == null ? 0 : 15,
    invalid_intervals: 0,
    reconstructed_intervals: 0,
    evidence_flags: [],
    evidence_status: value == null ? null : "GOOD",
    quality: null,
    is_partial: bucket_state !== "COMPLETE",
  };
}

function series(overrides: Partial<AnalyticsSeries> = {}): AnalyticsSeries {
  return {
    asset_id: "a1",
    asset_name: "Asset a1",
    data_point: "ENERGY_IMPORT",
    label: "Energy",
    qualifier: "TOTAL",
    unit: "kWh",
    chart_kind: "bar",
    aggregation: "sum",
    status: "OK",
    status_reasons: [],
    resolution_available_from: null,
    first_data_at: null,
    last_data_at: null,
    stale: false,
    // complete, gap, in progress, future
    points: [point(0, 1.5), point(1, null), point(2, 0.4, "IN_PROGRESS"), point(3, null, "FUTURE")],
    summary: { total: 1.9, average: 0.95, min: 0.4, min_at: null, max: 1.5, max_at: null },
    ...overrides,
  };
}

describe("buildChartModel -- the applied response on the chart", () => {
  it("maps every grid bucket and keeps nulls (gap, future) as nulls, never 0; the in-progress bucket is drawn", () => {
    const model = buildChartModel(seriesResponseFixture({ series: [series()] }), RANGE);
    expect(model.buckets).toEqual([0, 1, 2, 3].map((i) => ({ start: T0 + i * Q, end: T0 + (i + 1) * Q })));
    expect(model.series).toHaveLength(1);
    expect(model.series[0]).toMatchObject({ name: "Asset a1-Energy", unit: "kWh", kind: "bar", values: [1.5, null, 0.4, null] });
  });

  it("only OK series are drawn; NO_DATA / NOT_AVAILABLE / RESOLUTION_UNAVAILABLE / DATA_UNAVAILABLE are omitted (D6)", () => {
    const model = buildChartModel(
      seriesResponseFixture({
        series: [
          series({ status: "NO_DATA", status_reasons: ["NO_DATA_IN_RANGE"], points: [point(0, null)] }),
          series({ asset_id: "a2", asset_name: "Asset a2" }),
          series({ asset_id: "a3", status: "NOT_AVAILABLE", asset_name: null, points: [] }),
          series({ asset_id: "a4", status: "RESOLUTION_UNAVAILABLE", status_reasons: ["BEFORE_RETENTION_FLOOR"], points: [] }),
          series({ asset_id: "a5", status: "DATA_UNAVAILABLE", status_reasons: ["CAPTURE_POLICY_GAP"], points: [] }),
        ],
      }),
      RANGE,
    );
    expect(model.series.map((s) => s.name)).toEqual(["Asset a2-Energy"]);
  });

  it("measurements are lines with their own unit beside Energy bars (one Y axis per unit)", () => {
    const power = series({
      asset_id: "a2",
      asset_name: "Asset a2",
      data_point: "ACTIVE_POWER",
      label: "Power",
      unit: "kW",
      chart_kind: "line",
      aggregation: "mean",
      points: [point(0, 12.5), point(1, 13)],
    });
    const model = buildChartModel(seriesResponseFixture({ series: [series(), power] }), RANGE);
    expect(model.series.map((s) => [s.name, s.unit, s.kind])).toEqual([
      ["Asset a1-Energy", "kWh", "bar"],
      ["Asset a2-P", "kW", "line"],
    ]);
    expect(model.series[1]!.values).toEqual([12.5, 13, null, null]);
  });

  it("aligns series on one grid; a bucket one series lacks is a gap for it", () => {
    const short = series({ asset_id: "a2", asset_name: "Asset a2", points: [point(1, 2)] });
    const model = buildChartModel(seriesResponseFixture({ series: [series(), short] }), RANGE);
    expect(model.buckets).toHaveLength(4);
    expect(model.series[1]!.values).toEqual([null, 2, null, null]);
  });

  it("units and kinds come from the series (bars and lines, one key per asset/data point/qualifier)", () => {
    const line = series({ asset_id: "a2", asset_name: "Asset a2", data_point: "ACTIVE_POWER", label: "Active Power", unit: "kW", chart_kind: "line" });
    const model = buildChartModel(seriesResponseFixture({ series: [series(), line] }), RANGE);
    expect(model.series.map((s) => [s.key, s.unit, s.kind])).toEqual([
      ["a1:ENERGY_IMPORT:TOTAL", "kWh", "bar"],
      ["a2:ACTIVE_POWER:TOTAL", "kW", "line"],
    ]);
  });

  it("no response (nothing could be requested): no series, the applied range kept", () => {
    const model = buildChartModel(null, RANGE);
    expect(model).toEqual({ buckets: [], series: [], range: { from: T0, to: Date.parse(TO) } });
  });

  it("the X range is exactly the applied range", () => {
    expect(buildChartModel(seriesResponseFixture({ series: [series()] }), RANGE).range).toEqual({ from: T0, to: Date.parse(TO) });
  });
});

describe("chart card title -- <N assets | asset name>, <range> – <resolution>, <phase>", () => {
  const catalog = catalogFixture();
  const applied = (draft: Partial<AnalyticsDraft>, response = seriesResponseFixture({ series: [series()] }), range = RANGE) => ({
    draft: { ...INITIAL_DRAFT, ...draft },
    range,
    response,
  });

  it("one asset: its name, the single local day, the served resolution, System", () => {
    expect(chartTitle(applied({ assetIds: ["a1"] }), catalog, "Asia/Kolkata")).toBe("Asset a1, 05 Oct 2026 – 15 minutes, System");
  });

  it("several assets: the count; a multi-day range as inclusive dates; 3 Phase", () => {
    const range = { from: "2026-08-31T18:30:00.000Z", to: "2026-09-30T18:30:00.000Z" };
    const response = seriesResponseFixture({ resolution: "1h", requested_resolution: "auto" });
    expect(chartTitle(applied({ assetIds: ["a1", "a2", "a3"], phase: "three_phase" }, response, range), catalog, "Asia/Kolkata")).toBe(
      "3 assets, 01 Sep 2026 – 30 Sep 2026 – 1 hour, 3 Phase",
    );
  });

  it("a refined (time-of-day) range shows local times", () => {
    const range = { from: "2026-10-05T04:30:00.000Z", to: "2026-10-05T12:30:00.000Z" };
    expect(chartTitle(applied({ assetIds: ["a1"] }, seriesResponseFixture(), range), catalog, "Asia/Kolkata")).toBe(
      "Asset a1, 10:00 · 05 Oct 2026 – 18:00 · 05 Oct 2026 – 15 minutes, System",
    );
  });

  it("nothing requested: the requested resolution", () => {
    expect(chartTitle(applied({ assetIds: ["a1"], resolution: "1d" }, null as never), catalog, "Asia/Kolkata")).toBe(
      "Asset a1, 05 Oct 2026 – 1 day, System",
    );
  });

  it("appliedRangeLabel: a DST day is still one local day", () => {
    expect(appliedRangeLabel({ from: "2026-03-29T00:00:00.000Z", to: "2026-03-29T23:00:00.000Z" }, "Europe/London")).toBe("29 Mar 2026");
  });
});
