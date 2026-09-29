import { describe, expect, it } from "vitest";
import { buildComparisonResult, buildTypicalReferenceResult } from "./comparison";
import type { EnergyConsumptionResponse, EnergyTypicalReferenceResponse } from "../api/types";
import { evaluateEnergyAttention } from "../attention/energyAttention";
import { MVP3_MATERIALITY_POLICY } from "../attention/materiality-policy";

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

describe("Elapsed portion only (PO decision 2026-09-29) -- previous period / same period last year", () => {
  // 7 Days in IST at 00:40 on the 7th day: 6 complete days + 30 elapsed minutes
  // (the last completed UTC hour ends at 19:00Z), 100 kWh per hour recorded.
  const hourly = (from: string, hours: number, kwh = 100) =>
    Array.from({ length: hours }, (_, i) => ({
      bucket_start: new Date(Date.parse(from) + i * 3_600_000).toISOString(),
      import_kwh: kwh,
      export_kwh: null,
      source_interval_count: 60,
    }));

  it('"This period" is everything recorded; the delta uses only buckets before comparedUntil', () => {
    const current = response({ resolution: "1h", series: hourly("2026-06-09T19:00:00Z", 145) });
    const comparison = response({ resolution: "1h", series: hourly("2026-06-02T19:00:00Z", 144) });
    const result = buildComparisonResult("PREVIOUS_PERIOD", current, comparison, "2026-06-15T19:00:00Z");
    expect(result.currentTotalKwh).toBe(14_500); // headline unchanged
    expect(result.basisCurrentKwh).toBe(14_400); // the in-progress hour is excluded
    expect(result.comparisonTotalKwh).toBe(14_400);
    expect(result.deltaPercent).toBeCloseTo(0);
    expect(result.comparedUntil).toBe("2026-06-15T19:00:00Z");
  });

  it("nothing elapsed yet: no comparison, no delta, but the current total is still shown", () => {
    const current = response({ resolution: "1h", series: hourly("2026-06-14T18:00:00Z", 1) });
    const result = buildComparisonResult("PREVIOUS_PERIOD", current, null, "2026-06-14T18:30:00Z");
    expect(result.currentTotalKwh).toBe(100);
    expect(result.comparisonHasData).toBe(false);
    expect(result.deltaPercent).toBeNull();
  });
});

describe("Elapsed portion only (PO decisions 2026-09-29) -- Typical: complete elapsed days, per calendar day", () => {
  const daily = (days: number, kwhPerDay: number) =>
    response({
      resolution: "1d",
      series: Array.from({ length: days }, (_, i) => ({
        bucket_start: new Date(Date.parse("2026-06-08T18:30:00Z") + i * 86_400_000).toISOString(),
        import_kwh: kwhPerDay,
        export_kwh: null,
        source_interval_count: 1440,
      })),
    });

  it("7 Days: 6 complete days compared with typical per day x 6; today's partial day is excluded", () => {
    // Headline: 6 days + 40 minutes so far. Typical 7-day window: 7000 kWh (1000/day).
    const result = buildTypicalReferenceResult(withImport(6030), typicalReference({ typical_kwh: 7000 }), {
      basisResponse: daily(6, 1000),
      basisUntil: "2026-06-14T18:30:00Z",
      basisDays: 6,
      referenceDays: 7,
    });
    expect(result.currentTotalKwh).toBe(6030);
    expect(result.basisCurrentKwh).toBe(6000);
    expect(result.comparisonTotalKwh).toBeCloseTo(6000);
    expect(result.deltaPercent).toBeCloseTo(0);
    expect(result.normalizedPerCalendarDay).toBe(true);
  });

  it("3 Months: 92 complete days against the 90-day reference, per calendar day", () => {
    const result = buildTypicalReferenceResult(withImport(92_500), typicalReference({ typical_kwh: 90_000 }), {
      basisResponse: daily(92, 1000),
      basisUntil: "2026-06-14T18:30:00Z",
      basisDays: 92,
      referenceDays: 90,
    });
    expect(result.comparisonTotalKwh).toBeCloseTo(92_000);
    expect(result.deltaPercent).toBeCloseTo(0);
  });

  it("the percentage equals the per-day comparison, not the raw-total comparison", () => {
    // Per day: 3650 / 365 = 10 vs 3285 / 365 = 9 (1 Year, 365 complete days, reference 365).
    const result = buildTypicalReferenceResult(withImport(3660), typicalReference({ typical_kwh: 3285 }), {
      basisResponse: daily(365, 10),
      basisUntil: "2026-06-14T18:30:00Z",
      basisDays: 365,
      referenceDays: 365,
    });
    expect(result.normalizedPerCalendarDay).toBe(false);
    expect(result.deltaPercent).toBeCloseTo((10 / 9 - 1) * 100, 6);
  });

  it("Today: no complete day yet, so no Typical comparison (and no delta) until the day is complete", () => {
    const result = buildTypicalReferenceResult(withImport(40), typicalReference({ typical_kwh: 1000 }), {
      basisResponse: null,
      basisUntil: null,
      basisDays: 0,
      referenceDays: 1,
    });
    expect(result.currentTotalKwh).toBe(40);
    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.comparisonHasData).toBe(false);
    expect(result.deltaPercent).toBeNull();
  });

  it("insufficient history stays null", () => {
    const result = buildTypicalReferenceResult(
      withImport(930),
      typicalReference({ typical_kwh: null, sufficient: false }),
      { basisResponse: daily(92, 10), basisUntil: "2026-06-14T18:30:00Z", basisDays: 92, referenceDays: 90 },
    );
    expect(result.comparisonTotalKwh).toBeNull();
    expect(result.deltaPercent).toBeNull();
  });

  it("without a basis (the Site Performance Report's own ranges) nothing changes", () => {
    const result = buildTypicalReferenceResult(withImport(118), typicalReference({ typical_kwh: 100.5 }));
    expect(result.normalizedPerCalendarDay).toBe(false);
    expect(result.basisCurrentKwh).toBe(118);
    expect(result.comparisonTotalKwh).toBe(100.5);
  });
});

describe("Energy Attention +/-15% threshold near local midnight (PO decision 2026-09-29)", () => {
  const policy = MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION;
  const window7D = { from: "2026-06-08T18:30:00.000Z", to: "2026-06-15T18:30:00.000Z" };
  const attention = (result: ReturnType<typeof buildTypicalReferenceResult>) =>
    evaluateEnergyAttention({ result, evidence: null, policy, siteName: "Site", window: window7D, investigatePath: "/x" });
  const daily = (days: number, kwhPerDay: number) =>
    response({
      resolution: "1d",
      series: Array.from({ length: days }, (_, i) => ({
        bucket_start: new Date(Date.parse(window7D.from) + i * 86_400_000).toISOString(),
        import_kwh: kwhPerDay,
        export_kwh: null,
        source_interval_count: 1440,
      })),
    });

  it("steady consumption at 00:40 local: the old whole-range comparison was -14% (near the threshold); now 0% -> no Attention", () => {
    // 6 days + 40 min at 1000 kWh/day = 6027.8 kWh so far; typical 7 days = 7000 kWh.
    const soFar = 6000 + (1000 * 40) / 1440;
    const beforeFix = buildTypicalReferenceResult(withImport(soFar), typicalReference({ typical_kwh: 7000 }));
    expect(beforeFix.deltaPercent).toBeCloseTo(-13.9, 1);

    const result = buildTypicalReferenceResult(withImport(soFar), typicalReference({ typical_kwh: 7000 }), {
      basisResponse: daily(6, 1000),
      basisUntil: "2026-06-14T18:30:00.000Z",
      basisDays: 6,
      referenceDays: 7,
    });
    expect(result.deltaPercent).toBeCloseTo(0);
    expect(attention(result)).toBeNull();
  });

  it("a genuine 20% drop over the complete days still raises LOW Attention", () => {
    const result = buildTypicalReferenceResult(withImport(4830), typicalReference({ typical_kwh: 7000 }), {
      basisResponse: daily(6, 800),
      basisUntil: "2026-06-14T18:30:00.000Z",
      basisDays: 6,
      referenceDays: 7,
    });
    expect(result.deltaPercent).toBeCloseTo(-20);
    expect(attention(result)?.direction).toBe("LOW");
  });

  it("a genuine 20% rise over the complete days still raises HIGH Attention", () => {
    const result = buildTypicalReferenceResult(withImport(7230), typicalReference({ typical_kwh: 7000 }), {
      basisResponse: daily(6, 1200),
      basisUntil: "2026-06-14T18:30:00.000Z",
      basisDays: 6,
      referenceDays: 7,
    });
    expect(result.deltaPercent).toBeCloseTo(20);
    expect(attention(result)?.direction).toBe("HIGH");
  });
});
