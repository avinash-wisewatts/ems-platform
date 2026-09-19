import { describe, expect, it } from "vitest";
import { buildAssetEnergyComparison } from "./assetEnergy";
import type { AssetEnergyIntervalsResponse } from "../../api/types";

function response(overrides: Partial<AssetEnergyIntervalsResponse> = {}): AssetEnergyIntervalsResponse {
  return {
    asset_id: "a1",
    from: "2026-09-16T13:00:00Z",
    to: "2026-09-16T14:00:00Z",
    no_data: false,
    series: [],
    ...overrides,
  };
}

describe("buildAssetEnergyComparison", () => {
  it("sums import_consumption_kwh and computes delta/percent", () => {
    const current = response({
      series: [
        { interval_start: "t1", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 5, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: false, gap_detected: false },
        { interval_start: "t2", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 5, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: false, gap_detected: false },
      ],
    });
    const comparison = response({
      series: [
        { interval_start: "t0", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 8, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: false, gap_detected: false },
      ],
    });
    const result = buildAssetEnergyComparison(current, comparison);
    expect(result.currentTotalKwh).toBe(10);
    expect(result.comparisonTotalKwh).toBe(8);
    expect(result.deltaKwh).toBe(2);
    expect(result.deltaPercent).toBeCloseTo(25, 5);
    expect(result.currentHasData).toBe(true);
    expect(result.comparisonHasData).toBe(true);
  });

  it("returns null totals when a response has no_data", () => {
    const current = response({ no_data: true, series: [] });
    const comparison = response({ no_data: true, series: [] });
    const result = buildAssetEnergyComparison(current, comparison);
    expect(result.currentTotalKwh).toBeNull();
    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.deltaKwh).toBeNull();
    expect(result.deltaPercent).toBeNull();
    expect(result.currentHasData).toBe(false);
    expect(result.comparisonHasData).toBe(false);
  });

  it("counts reset_detected/gap_detected intervals in the current window only", () => {
    const current = response({
      series: [
        { interval_start: "t1", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 5, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: true, gap_detected: false },
        { interval_start: "t2", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 5, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: false, gap_detected: true },
      ],
    });
    const comparison = response({
      series: [
        { interval_start: "t0", device_id: "d", device_name: "d", elapsed_minutes: 15, import_consumption_kwh: 8, export_consumption_kwh: 0, import_quality_code: "GOOD", export_quality_code: "GOOD", reset_detected: true, gap_detected: true },
      ],
    });
    const result = buildAssetEnergyComparison(current, comparison);
    expect(result.resetIntervalCount).toBe(1);
    expect(result.gapIntervalCount).toBe(1);
  });

  it("reports zero reset/gap counts when the current window has no data", () => {
    const current = response({ no_data: true, series: [] });
    const comparison = response({ no_data: true, series: [] });
    const result = buildAssetEnergyComparison(current, comparison);
    expect(result.resetIntervalCount).toBe(0);
    expect(result.gapIntervalCount).toBe(0);
  });
});
