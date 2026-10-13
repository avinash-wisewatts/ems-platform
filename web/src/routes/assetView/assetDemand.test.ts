import { describe, expect, it } from "vitest";
import { buildDemandChartPoints, findMaxDemand } from "./assetDemand";
import type { DemandIntervalPoint } from "../../api/types";

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

describe("findMaxDemand (T1.3a: reliable demand only)", () => {
  it("ignores INCOMPLETE and unavailable intervals, even when their calculated value is higher", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 40 }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 95, quality_status: "INCOMPLETE" }),
      demandInterval({ interval_start: "2026-09-18T09:30:00Z", demand_kw: 99, quality_status: "SOURCE_BOUNDARY" }),
    ];
    expect(findMaxDemand(series)).toEqual({ kw: 40, at: "2026-09-18T09:00:00Z" });
  });

  it("returns null when no interval is VALID", () => {
    expect(findMaxDemand([demandInterval({ quality_status: "INCOMPLETE" })])).toBeNull();
  });
});

describe("buildDemandChartPoints", () => {
  it("charts completed intervals only, with no provisional point for the interval in progress", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 50 }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 52.5 }),
    ];
    expect(buildDemandChartPoints(series)).toEqual([
      { t: Date.parse("2026-09-18T09:00:00Z"), value: 50 },
      { t: Date.parse("2026-09-18T09:15:00Z"), value: 52.5 },
    ]);
  });

  it("charts a non-VALID interval as a gap, never as its calculated value", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-18T09:00:00Z", demand_kw: 50 }),
      demandInterval({ interval_start: "2026-09-18T09:15:00Z", demand_kw: 31.7, quality_status: "INCOMPLETE" }),
      demandInterval({ interval_start: "2026-09-18T09:30:00Z", demand_kw: null, quality_status: "NO_DATA" }),
    ];
    expect(buildDemandChartPoints(series)).toEqual([
      { t: Date.parse("2026-09-18T09:00:00Z"), value: 50 },
      { t: Date.parse("2026-09-18T09:15:00Z"), value: null },
      { t: Date.parse("2026-09-18T09:30:00Z"), value: null },
    ]);
  });

  it("returns no points for an empty series", () => {
    expect(buildDemandChartPoints([])).toEqual([]);
  });
});
