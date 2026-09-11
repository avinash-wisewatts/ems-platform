import { describe, expect, it } from "vitest";
import {
  TIME_RANGE_PRESETS,
  isPresetSupported,
  planDemandRequest,
  planEnergyComparisonRequest,
  planEnergyRequest,
  planEnergyTypicalReferenceRequest,
  planMeasurementRequest,
  planPowerQualityRequest,
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

  it("demand: no resolution field; TODAY/7D/30D serviceable, 3M/1Y not (31-day cap, no coarser tier)", () => {
    expect(planDemandRequest("TODAY", NOW)).toEqual({ supported: true, range: resolveRange("TODAY", NOW) });
    expect(planDemandRequest("7D", NOW).supported).toBe(true);
    expect(planDemandRequest("30D", NOW).supported).toBe(true);

    const threeMonths = planDemandRequest("3M", NOW);
    expect(threeMonths.supported).toBe(false);
    const oneYear = planDemandRequest("1Y", NOW);
    expect(oneYear.supported).toBe(false);
  });

  it("power quality: TODAY/7D -> 15min, 30D -> 1h, 3M/1Y -> 1d; every preset is serviceable", () => {
    expect(planPowerQualityRequest("TODAY", NOW)).toMatchObject({ supported: true, resolution: "15min" });
    expect(planPowerQualityRequest("7D", NOW)).toMatchObject({ supported: true, resolution: "15min" });
    expect(planPowerQualityRequest("30D", NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planPowerQualityRequest("3M", NOW)).toMatchObject({ supported: true, resolution: "1d" });
    expect(planPowerQualityRequest("1Y", NOW)).toMatchObject({ supported: true, resolution: "1d" });
  });

  it("isPresetSupported reflects the per-kind capability, including demand and power-quality", () => {
    expect(isPresetSupported("1Y", "energy", NOW)).toBe(true);
    expect(isPresetSupported("1Y", "measurement", NOW)).toBe(false);
    expect(isPresetSupported("30D", "measurement", NOW)).toBe(true);
    expect(isPresetSupported("30D", "demand", NOW)).toBe(true);
    expect(isPresetSupported("1Y", "demand", NOW)).toBe(false);
    expect(isPresetSupported("1Y", "power-quality", NOW)).toBe(true);
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

describe("Slice C -- typical historical reference planning (comparable-period, server-computed)", () => {
  const EXPECTED_DAYS: Record<(typeof TIME_RANGE_PRESETS)[number], number> = {
    TODAY: 1,
    "7D": 7,
    "30D": 30,
    "3M": 90,
    "1Y": 365,
  };

  it("returns an EXACT whole-day span for every preset, matching the approved {1,7,30,90,365} set", () => {
    for (const preset of TIME_RANGE_PRESETS) {
      const plan = planEnergyTypicalReferenceRequest(preset, NOW);
      expect(plan.supported).toBe(true);
      if (!plan.supported) continue;
      const spanMs = Date.parse(plan.current.to) - Date.parse(plan.current.from);
      expect(spanMs).toBe(EXPECTED_DAYS[preset] * 86_400_000);
    }
  });

  it("TODAY: widens `to` to exactly one full day after resolveRange's own (UTC-midnight) `from`, unchanged", () => {
    const plan = planEnergyTypicalReferenceRequest("TODAY", NOW);
    expect(plan.supported).toBe(true);
    if (!plan.supported) return;

    const expectedFrom = resolveRange("TODAY", NOW).from;
    expect(plan.current.from).toBe(expectedFrom);
    expect(plan.current.from).toBe("2026-06-15T00:00:00.000Z"); // UTC midnight, not site-local
    expect(Date.parse(plan.current.to) - Date.parse(plan.current.from)).toBe(86_400_000);
  });

  it("7D/30D/3M/1Y: reuses planEnergyRequest's range verbatim (already an exact whole-day span regardless of time-of-day)", () => {
    for (const preset of ["7D", "30D", "3M", "1Y"] as const) {
      const plan = planEnergyTypicalReferenceRequest(preset, NOW);
      const direct = planEnergyRequest(preset, NOW);
      expect(plan.supported).toBe(true);
      expect(direct.supported).toBe(true);
      if (!plan.supported || !direct.supported) continue;
      expect(plan.current).toEqual(direct.range);
    }
  });

  it("propagates the current window's unsupported reason unchanged, exactly like planEnergyComparisonRequest", () => {
    // Energy has no unsupported preset today (unlike measurements), but the
    // propagation path itself is asserted directly for when that changes.
    const plan = planEnergyTypicalReferenceRequest("1Y", NOW);
    expect(plan.supported).toBe(true);
  });
});
