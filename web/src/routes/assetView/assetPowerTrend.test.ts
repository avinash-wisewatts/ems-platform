import { describe, expect, it } from "vitest";
import { hasEstimatedSamples, toPowerTrendChartPoints } from "./assetPowerTrend";
import type { AssetPowerTrendPoint } from "../../api/types";

function point(overrides: Partial<AssetPowerTrendPoint> = {}): AssetPowerTrendPoint {
  return {
    sample_time: "2026-09-17T12:00:00Z",
    active_power_kw: 42,
    is_estimated: false,
    ...overrides,
  };
}

describe("toPowerTrendChartPoints", () => {
  it("maps sample_time/active_power_kw to ChartFrame's t/value shape", () => {
    const series = [
      point({ sample_time: "2026-09-17T12:00:00Z", active_power_kw: 42 }),
      point({ sample_time: "2026-09-17T12:01:00Z", active_power_kw: null }),
    ];
    expect(toPowerTrendChartPoints(series)).toEqual([
      { t: Date.parse("2026-09-17T12:00:00Z"), value: 42 },
      { t: Date.parse("2026-09-17T12:01:00Z"), value: null },
    ]);
  });
});

describe("hasEstimatedSamples", () => {
  it("is false for an empty series or one with no estimated samples", () => {
    expect(hasEstimatedSamples([])).toBe(false);
    expect(hasEstimatedSamples([point({ is_estimated: false })])).toBe(false);
  });

  it("is true when any sample is estimated", () => {
    expect(hasEstimatedSamples([point({ is_estimated: false }), point({ is_estimated: true })])).toBe(true);
  });
});
