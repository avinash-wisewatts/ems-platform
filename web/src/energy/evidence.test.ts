import { describe, expect, it } from "vitest";
import { summarizeEnergyEvidence } from "./evidence";
import type { EnergyConsumptionEvidenceResponse } from "../api/types";

function response(
  overrides: Partial<EnergyConsumptionEvidenceResponse> = {},
): EnergyConsumptionEvidenceResponse {
  return {
    site_id: "site-1",
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: false,
    series: [],
    ...overrides,
  };
}

function point(
  overrides: Partial<EnergyConsumptionEvidenceResponse["series"][number]> = {},
): EnergyConsumptionEvidenceResponse["series"][number] {
  return {
    bucket_start: "2026-06-01T00:00:00Z",
    source_interval_count: 4,
    valid_import_intervals: 4,
    invalid_import_intervals: 0,
    valid_export_intervals: 4,
    invalid_export_intervals: 0,
    gap_interval_count: 0,
    reset_interval_count: 0,
    rollover_interval_count: 0,
    invalid_interval_count: 0,
    first_source_bucket: "2026-06-01T00:00:00Z",
    last_source_bucket: "2026-06-01T00:45:00Z",
    ...overrides,
  };
}

describe("summarizeEnergyEvidence -- sums the source counters exactly, invents nothing", () => {
  it("no_data produces the empty summary, not a fabricated zero-coverage claim", () => {
    const summary = summarizeEnergyEvidence(response({ no_data: true, series: [] }));
    expect(summary.hasData).toBe(false);
    expect(summary.coveragePercent).toBeNull();
    expect(summary.totalIntervals).toBe(0);
  });

  it("sums counters across multiple buckets and computes coverage as valid/total", () => {
    const summary = summarizeEnergyEvidence(
      response({
        series: [
          point({ source_interval_count: 4, valid_import_intervals: 4 }),
          point({
            bucket_start: "2026-06-02T00:00:00Z",
            source_interval_count: 4,
            valid_import_intervals: 2,
            invalid_import_intervals: 2,
            gap_interval_count: 2,
            first_source_bucket: "2026-06-02T00:00:00Z",
            last_source_bucket: "2026-06-02T00:45:00Z",
          }),
        ],
      }),
    );

    expect(summary.hasData).toBe(true);
    expect(summary.totalIntervals).toBe(8);
    expect(summary.validImportIntervals).toBe(6);
    expect(summary.gapIntervalCount).toBe(2);
    expect(summary.coveragePercent).toBeCloseTo(75);
  });

  it("tracks the earliest first_source_bucket and latest last_source_bucket across buckets", () => {
    const summary = summarizeEnergyEvidence(
      response({
        series: [
          point({ first_source_bucket: "2026-06-03T00:00:00Z", last_source_bucket: "2026-06-03T00:45:00Z" }),
          point({ first_source_bucket: "2026-06-01T00:00:00Z", last_source_bucket: "2026-06-01T00:45:00Z" }),
          point({ first_source_bucket: "2026-06-02T00:00:00Z", last_source_bucket: "2026-06-05T00:45:00Z" }),
        ],
      }),
    );

    expect(summary.firstSourceBucket).toBe("2026-06-01T00:00:00Z");
    expect(summary.lastSourceBucket).toBe("2026-06-05T00:45:00Z");
  });

  it("zero total intervals produces a null coverage percent, never a 0% or divide-by-zero", () => {
    const summary = summarizeEnergyEvidence(
      response({ series: [point({ source_interval_count: 0, valid_import_intervals: 0 })] }),
    );
    expect(summary.coveragePercent).toBeNull();
  });

  it("gap/reset/rollover counters are tracked independently -- never merged into one lattice value", () => {
    const summary = summarizeEnergyEvidence(
      response({
        series: [
          point({ gap_interval_count: 1, reset_interval_count: 2, rollover_interval_count: 3 }),
        ],
      }),
    );
    expect(summary.gapIntervalCount).toBe(1);
    expect(summary.resetIntervalCount).toBe(2);
    expect(summary.rolloverIntervalCount).toBe(3);
  });

  it("evidence counters are NOT mutually exclusive -- a single interval can trigger more than one flag at once, so their sum can exceed the interval count for that bucket", () => {
    // A single-interval bucket (source_interval_count: 1) where that ONE
    // interval is counted as BOTH a gap AND a reset AND a rollover AND
    // invalid, exactly as the traced source view can produce (each of the
    // four is an independent boolean condition, not a branch of one
    // priority-resolved case). If these were a partition of the interval,
    // this fixture would be invalid; summarizeEnergyEvidence makes no such
    // assumption and must sum each independently without clamping,
    // deduplicating, or deriving a single winning status.
    const summary = summarizeEnergyEvidence(
      response({
        series: [
          point({
            source_interval_count: 1,
            gap_interval_count: 1,
            reset_interval_count: 1,
            rollover_interval_count: 1,
            invalid_interval_count: 1,
          }),
        ],
      }),
    );

    expect(summary.totalIntervals).toBe(1);
    expect(summary.gapIntervalCount).toBe(1);
    expect(summary.resetIntervalCount).toBe(1);
    expect(summary.rolloverIntervalCount).toBe(1);
    expect(summary.invalidIntervalCount).toBe(1);
    // The sum of the four independent indicators (4) exceeds the single
    // interval they describe (1) -- proof this module treats them as
    // overlapping evidence, not a partition summing to totalIntervals.
    const indicatorSum =
      summary.gapIntervalCount +
      summary.resetIntervalCount +
      summary.rolloverIntervalCount +
      summary.invalidIntervalCount;
    expect(indicatorSum).toBeGreaterThan(summary.totalIntervals);
  });
});
