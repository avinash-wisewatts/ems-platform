import { describe, expect, it } from "vitest";
import { buildComparisonResult, buildTypicalReferenceResult } from "./comparison";
import type { EnergyConsumptionResponse, EnergyTypicalReferenceResponse } from "../api/types";

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

function withImport(kwh: number | null, noData = false): EnergyConsumptionResponse {
  return response({
    no_data: noData,
    series: noData || kwh === null ? [] : [
      { bucket_start: "2026-05-01T00:00:00Z", import_kwh: kwh, export_kwh: null, source_interval_count: 24 },
    ],
  });
}

function window(
  index: number,
  overrides: Partial<EnergyTypicalReferenceResponse["windows"][number]> = {},
): EnergyTypicalReferenceResponse["windows"][number] {
  return {
    window_index: index,
    from: "2026-04-01T00:00:00Z",
    to: "2026-04-08T00:00:00Z",
    has_data: true,
    total_kwh: 100,
    source_interval_count: 10,
    valid_import_intervals: 10,
    coverage_percent: 100,
    eligible: true,
    gap_interval_count: 0,
    reset_interval_count: 0,
    rollover_interval_count: 0,
    invalid_interval_count: 0,
    ...overrides,
  };
}

function typicalReference(
  overrides: Partial<EnergyTypicalReferenceResponse> = {},
): EnergyTypicalReferenceResponse {
  return {
    site_id: "site-1",
    period_length_days: 7,
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    typical_kwh: 100,
    requested_period_count: 8,
    windows_with_data_count: 8,
    eligible_period_count: 8,
    sufficient: true,
    windows: Array.from({ length: 8 }, (_, i) => window(i + 1)),
    ...overrides,
  };
}

describe("buildTypicalReferenceResult -- Slice C, comparable-period reference, server-computed, never predictive", () => {
  it("adapts a sufficient reference into the shared ComparisonResult shape unchanged", () => {
    const current = withImport(118);
    const reference = typicalReference({ typical_kwh: 100.5, eligible_period_count: 8 });

    const result = buildTypicalReferenceResult(current, reference);

    expect(result.basis).toBe("TYPICAL_HISTORICAL_REFERENCE");
    expect(result.currentTotalKwh).toBe(118);
    expect(result.comparisonTotalKwh).toBe(100.5);
    expect(result.deltaKwh).toBeCloseTo(17.5);
    expect(result.deltaPercent).toBeCloseTo(17.41, 1);
    expect(result.comparisonHasData).toBe(true);
    expect(result.sufficient).toBe(true);
    expect(result.requestedPeriodCount).toBe(8);
    expect(result.eligiblePeriodCount).toBe(8);
    expect(result.windows).toHaveLength(8);
  });

  it("never fabricates a value when the server reports insufficient history", () => {
    const current = withImport(118);
    const reference = typicalReference({
      typical_kwh: null,
      sufficient: false,
      eligible_period_count: 4,
      windows_with_data_count: 5,
    });

    const result = buildTypicalReferenceResult(current, reference);

    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.comparisonHasData).toBe(false);
    expect(result.deltaKwh).toBeNull();
    expect(result.deltaPercent).toBeNull();
    expect(result.eligiblePeriodCount).toBe(4);
    expect(result.windowsWithDataCount).toBe(5);
    // Defensive: even if a server bug somehow set typical_kwh while
    // sufficient=false, this adapter must not trust it -- comparisonTotalKwh
    // is gated on `sufficient`, not merely on `typical_kwh` being non-null.
  });

  it("ignores a non-null typical_kwh when sufficient is false (defensive, does not trust it)", () => {
    const current = withImport(118);
    const reference = typicalReference({ typical_kwh: 999, sufficient: false });

    const result = buildTypicalReferenceResult(current, reference);

    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.comparisonHasData).toBe(false);
  });

  it("a zero typical value avoids a divide-by-zero -- delta% is null, not Infinity", () => {
    const current = withImport(50);
    const reference = typicalReference({ typical_kwh: 0 });

    const result = buildTypicalReferenceResult(current, reference);

    expect(result.comparisonTotalKwh).toBe(0);
    expect(result.deltaKwh).toBe(50);
    expect(result.deltaPercent).toBeNull();
  });

  it("current period with no data produces a null current total, never a fabricated zero", () => {
    const current = withImport(null, true);
    const reference = typicalReference();

    const result = buildTypicalReferenceResult(current, reference);

    expect(result.currentTotalKwh).toBeNull();
    expect(result.currentHasData).toBe(false);
    expect(result.deltaKwh).toBeNull();
  });

  it("passes through per-window evidence unchanged, including overlapping flags", () => {
    const current = withImport(100);
    const reference = typicalReference({
      windows: [
        window(1, { gap_interval_count: 1, reset_interval_count: 1, rollover_interval_count: 1, invalid_interval_count: 1 }),
        ...Array.from({ length: 7 }, (_, i) => window(i + 2)),
      ],
    });

    const result = buildTypicalReferenceResult(current, reference);

    const w1 = result.windows[0]!;
    expect(w1.gap_interval_count).toBe(1);
    expect(w1.reset_interval_count).toBe(1);
    expect(w1.rollover_interval_count).toBe(1);
    expect(w1.invalid_interval_count).toBe(1);
    expect(w1.eligible).toBe(true); // still eligible -- flags never forced exclusion
  });
});
