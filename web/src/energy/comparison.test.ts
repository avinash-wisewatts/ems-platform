import { describe, expect, it } from "vitest";
import { buildComparisonResult } from "./comparison";
import type { EnergyConsumptionResponse } from "../api/types";

function response(overrides: Partial<EnergyConsumptionResponse> = {}): EnergyConsumptionResponse {
  return {
    site_id: "site-1",
    resolution: "1d",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: false,
    series: [],
    ...overrides,
  };
}

describe("buildComparisonResult -- Q54/Q56 historical comparison only", () => {
  it("computes total, delta, and delta% from import_kwh across both series", () => {
    const current = response({
      series: [
        { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 100, export_kwh: null, source_interval_count: 24 },
        { bucket_start: "2026-06-02T00:00:00Z", import_kwh: 120, export_kwh: null, source_interval_count: 24 },
      ],
    });
    const comparison = response({
      series: [
        { bucket_start: "2026-05-25T00:00:00Z", import_kwh: 200, export_kwh: null, source_interval_count: 24 },
      ],
    });

    const result = buildComparisonResult("PREVIOUS_PERIOD", current, comparison);

    expect(result.currentTotalKwh).toBe(220);
    expect(result.comparisonTotalKwh).toBe(200);
    expect(result.deltaKwh).toBeCloseTo(20);
    expect(result.deltaPercent).toBeCloseTo(10);
    expect(result.currentHasData).toBe(true);
    expect(result.comparisonHasData).toBe(true);
  });

  it("no_data on either side produces null totals/delta, never a fabricated 0", () => {
    const current = response({ no_data: true, series: [] });
    const comparison = response({
      series: [
        { bucket_start: "2026-05-25T00:00:00Z", import_kwh: 200, export_kwh: null, source_interval_count: 24 },
      ],
    });

    const result = buildComparisonResult("SAME_PERIOD_PREVIOUSLY", current, comparison);

    expect(result.currentTotalKwh).toBeNull();
    expect(result.deltaKwh).toBeNull();
    expect(result.deltaPercent).toBeNull();
    expect(result.currentHasData).toBe(false);
    expect(result.comparisonHasData).toBe(true);
  });

  it("a zero comparison total avoids a divide-by-zero -- delta% is null, not Infinity", () => {
    const current = response({
      series: [
        { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 50, export_kwh: null, source_interval_count: 24 },
      ],
    });
    const comparison = response({
      series: [
        { bucket_start: "2026-05-25T00:00:00Z", import_kwh: 0, export_kwh: null, source_interval_count: 24 },
      ],
    });

    const result = buildComparisonResult("PREVIOUS_PERIOD", current, comparison);

    expect(result.comparisonTotalKwh).toBe(0);
    expect(result.deltaKwh).toBe(50);
    expect(result.deltaPercent).toBeNull();
  });

  it("null points within a series are excluded from the total, not treated as zero", () => {
    const current = response({
      series: [
        { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 50, export_kwh: null, source_interval_count: 24 },
        { bucket_start: "2026-06-02T00:00:00Z", import_kwh: null, export_kwh: null, source_interval_count: 0 },
      ],
    });
    const comparison = response({ series: [] });

    const result = buildComparisonResult("PREVIOUS_PERIOD", current, comparison);

    expect(result.currentTotalKwh).toBe(50);
    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.deltaKwh).toBeNull();
  });
});
