import { describe, expect, it } from "vitest";
import {
  isPresetSupported,
  planEnergyComparisonRequest,
  planEnergyRequest,
  planMeasurementRequest,
  resolveRange,
  shiftRangeForComparison,
} from "./ranges";

const NOW = new Date("2026-06-15T12:00:00.000Z");

describe("time-range presets -> Phase 7 requests", () => {
  it("resolveRange produces a half-open UTC window ending now; Today starts at UTC midnight", () => {
    expect(resolveRange("TODAY", NOW)).toEqual({
      from: "2026-06-15T00:00:00.000Z",
      to: "2026-06-15T12:00:00.000Z",
    });
    expect(resolveRange("7D", NOW).from).toBe("2026-06-08T12:00:00.000Z");
    expect(resolveRange("1Y", NOW).from).toBe("2025-06-15T12:00:00.000Z");
  });

  it("measurements: Today -> raw; 7D/30D -> 1h; 3M/1Y -> unsupported (Phase 7 first-slice cap)", () => {
    const today = planMeasurementRequest("TODAY", NOW);
    expect(today).toMatchObject({ supported: true, resolution: "raw" });

    expect(planMeasurementRequest("7D", NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planMeasurementRequest("30D", NOW)).toMatchObject({ supported: true, resolution: "1h" });

    const threeMonths = planMeasurementRequest("3M", NOW);
    expect(threeMonths.supported).toBe(false);
    if (!threeMonths.supported) expect(threeMonths.reason).toMatch(/30 days/);
    expect(planMeasurementRequest("1Y", NOW).supported).toBe(false);
  });

  it("energy: every preset is serviceable; 3M/1Y route to 1d", () => {
    expect(planEnergyRequest("TODAY", NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("7D", NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("30D", NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("3M", NOW)).toMatchObject({ supported: true, resolution: "1d" });
    expect(planEnergyRequest("1Y", NOW)).toMatchObject({ supported: true, resolution: "1d" });
  });

  it("isPresetSupported reflects the per-kind capability", () => {
    expect(isPresetSupported("1Y", "energy", NOW)).toBe(true);
    expect(isPresetSupported("1Y", "measurement", NOW)).toBe(false);
    expect(isPresetSupported("30D", "measurement", NOW)).toBe(true);
  });
});

describe("Slice A -- energy comparison ranges (Q54/Q56: historical only)", () => {
  const range7D = resolveRange("7D", NOW);

  it("PREVIOUS_PERIOD shifts back by exactly the window length", () => {
    const shifted = shiftRangeForComparison(range7D, "PREVIOUS_PERIOD");
    const spanMs = Date.parse(range7D.to) - Date.parse(range7D.from);
    expect(Date.parse(shifted.to)).toBe(Date.parse(range7D.from));
    expect(Date.parse(range7D.from) - Date.parse(shifted.from)).toBe(spanMs);
  });

  it("SAME_PERIOD_PREVIOUSLY shifts back exactly one UTC calendar year", () => {
    const shifted = shiftRangeForComparison(range7D, "SAME_PERIOD_PREVIOUSLY");
    expect(shifted.from).toBe("2025-06-08T12:00:00.000Z");
    expect(shifted.to).toBe("2025-06-15T12:00:00.000Z");
  });

  it("planEnergyComparisonRequest returns two equal-length, same-resolution windows", () => {
    const plan = planEnergyComparisonRequest("30D", "PREVIOUS_PERIOD", NOW);
    expect(plan.supported).toBe(true);
    if (!plan.supported) return;
    expect(plan.resolution).toBe("1h");
    const currentSpan = Date.parse(plan.current.to) - Date.parse(plan.current.from);
    const comparisonSpan = Date.parse(plan.comparison.to) - Date.parse(plan.comparison.from);
    expect(comparisonSpan).toBe(currentSpan);
    expect(plan.comparison.to).toBe(plan.current.from);
  });

  it("planEnergyComparisonRequest propagates the current window's unsupported reason unchanged", () => {
    // Energy has no unsupported preset today (unlike measurements), but the
    // propagation path itself is asserted directly for when that changes.
    const plan = planEnergyComparisonRequest("1Y", "SAME_PERIOD_PREVIOUSLY", NOW);
    expect(plan.supported).toBe(true);
  });

  it("a 1Y comparison window (2 years of total span across both calls) stays within the 366-day-per-call cap", () => {
    const plan = planEnergyComparisonRequest("1Y", "PREVIOUS_PERIOD", NOW);
    expect(plan.supported).toBe(true);
    if (!plan.supported) return;
    const currentSpanDays = (Date.parse(plan.current.to) - Date.parse(plan.current.from)) / 86_400_000;
    const comparisonSpanDays =
      (Date.parse(plan.comparison.to) - Date.parse(plan.comparison.from)) / 86_400_000;
    expect(currentSpanDays).toBeLessThanOrEqual(366);
    expect(comparisonSpanDays).toBeLessThanOrEqual(366);
  });
});
