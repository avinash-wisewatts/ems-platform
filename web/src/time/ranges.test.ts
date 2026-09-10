import { describe, expect, it } from "vitest";
import {
  isPresetSupported,
  planEnergyRequest,
  planMeasurementRequest,
  resolveRange,
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
