import { describe, expect, it } from "vitest";
import { buildDemandChartPoints, findMaxDemand } from "./assetDemand";
import type { AssetCurrentDemandResponse, DemandIntervalPoint } from "../../api/types";

function demandInterval(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return {
    interval_start: "2026-09-18T09:00:00Z",
    interval_end: "2026-09-18T09:15:00Z",
    demand_kw: 50,
    peak_power_kw: null,
    quality_status: "VALID",
    coverage_percent: 100,
    ...overrides,
  };
}

function currentDemand(overrides: Partial<AssetCurrentDemandResponse> = {}): AssetCurrentDemandResponse {
  return {
    asset_id: "a1",
    has_data: true,
    interval_start: "2026-09-18T09:45:00Z",
    interval_end: "2026-09-18T10:00:00Z",
    current_demand_kw: 42,
    current_demand_kva: null,
    quality_status: "PROVISIONAL",
    coverage_percent: 80,
    ...overrides,
  };
}

describe("findMaxDemand", () => {
  it("finds the interval with the highest demand_kw, not peak_power_kw", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 40, peak_power_kw: 200 }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 88.2, peak_power_kw: 90 }),
      demandInterval({ interval_start: "2026-09-18T09:30:00Z", demand_kw: 20, peak_power_kw: null }),
    ];
    // The highest peak_power_kw (200) is in the FIRST interval, but the
    // highest demand_kw (88.2) is in the SECOND -- findMaxDemand must
    // report the second interval, proving it uses demand_kw.
    expect(findMaxDemand(series)).toEqual({ kw: 88.2, at: "2026-09-18T09:15:00Z" });
  });

  it("finds the max demand_kw even when peak_power_kw is null throughout (METER_NATIVE source)", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 40, peak_power_kw: null }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 60, peak_power_kw: null }),
    ];
    expect(findMaxDemand(series)).toEqual({ kw: 60, at: "2026-09-18T09:15:00Z" });
  });

  it("skips intervals with a null demand_kw rather than treating them as zero", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: null }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 30 }),
    ];
    expect(findMaxDemand(series)).toEqual({ kw: 30, at: "2026-09-18T09:15:00Z" });
  });

  it("returns null for an empty series or when every demand_kw is null", () => {
    expect(findMaxDemand([])).toBeNull();
    expect(findMaxDemand([demandInterval({ demand_kw: null })])).toBeNull();
  });
});

describe("buildDemandChartPoints", () => {
  const range = { from: "2026-09-18T00:00:00Z", to: "2026-09-18T10:00:00Z" };

  it("appends the live current-interval point after the finalized series, closing the finalization-lag gap", () => {
    const series = [demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 50 })];
    const current = currentDemand({ interval_start: "2026-09-18T09:45:00Z", current_demand_kw: 42 });

    const points = buildDemandChartPoints(series, current, range);

    expect(points).toEqual([
      { t: Date.parse("2026-09-18T09:00:00Z"), value: 50 },
      { t: Date.parse("2026-09-18T09:45:00Z"), value: 42 },
    ]);
  });

  it("does not append the current point when it falls outside the requested window (e.g. a closed 'Yesterday' range)", () => {
    const yesterdayRange = { from: "2026-09-17T00:00:00Z", to: "2026-09-18T00:00:00Z" };
    const series = [demandInterval({ interval_start: "2026-09-17T09:00:00Z", demand_kw: 50 })];
    const current = currentDemand({ interval_start: "2026-09-18T09:45:00Z" });

    const points = buildDemandChartPoints(series, current, yesterdayRange);

    expect(points).toEqual([{ t: Date.parse("2026-09-17T09:00:00Z"), value: 50 }]);
  });

  it("does not duplicate the current interval when it has already been finalized into the series", () => {
    const series = [demandInterval({ interval_start: "2026-09-18T09:45:00Z", demand_kw: 41.5 })];
    const current = currentDemand({ interval_start: "2026-09-18T09:45:00Z", current_demand_kw: 42 });

    const points = buildDemandChartPoints(series, current, range);

    expect(points).toEqual([{ t: Date.parse("2026-09-18T09:45:00Z"), value: 41.5 }]);
  });

  it("does not append when the current demand has no data", () => {
    const series = [demandInterval()];
    const current = currentDemand({ has_data: false, current_demand_kw: null, interval_start: null });

    expect(buildDemandChartPoints(series, current, range)).toHaveLength(1);
  });

  it("returns just the current point when the series is empty but the current interval is in range", () => {
    const current = currentDemand({ interval_start: "2026-09-18T09:45:00Z", current_demand_kw: 42 });
    expect(buildDemandChartPoints([], current, range)).toEqual([
      { t: Date.parse("2026-09-18T09:45:00Z"), value: 42 },
    ]);
  });
});
