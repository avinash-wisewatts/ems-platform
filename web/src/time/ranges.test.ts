import { describe, expect, it } from "vitest";
import {
  TIME_RANGE_PRESETS,
  TYPICAL_REFERENCE_WINDOW_DAYS,
  comparisonCutoff,
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

// 2026-06-15 17:30 IST (a site in Asia/Kolkata, UTC+05:30).
const NOW = new Date("2026-06-15T12:00:00.000Z");
const IST = "Asia/Kolkata";
const DAY_MS = 86_400_000;

describe("time-range presets -> calendar ranges in the site timezone (D61/D62)", () => {
  it("resolveRange: local midnight of the first day to the exclusive next local midnight", () => {
    expect(resolveRange("TODAY", IST, NOW)).toEqual({
      from: "2026-06-14T18:30:00.000Z", // 15 Jun 00:00 IST
      to: "2026-06-15T18:30:00.000Z", // 16 Jun 00:00 IST -- the whole day, not "now"
    });
    expect(resolveRange("7D", IST, NOW).from).toBe("2026-06-08T18:30:00.000Z"); // 9 Jun: today + 6 days
    expect(resolveRange("30D", IST, NOW).from).toBe("2026-05-16T18:30:00.000Z"); // 17 May: today + 29 days
    expect(resolveRange("3M", IST, NOW).from).toBe("2026-03-14T18:30:00.000Z"); // 15 Mar
    expect(resolveRange("1Y", IST, NOW).from).toBe("2025-06-14T18:30:00.000Z"); // 15 Jun 2025
    for (const preset of TIME_RANGE_PRESETS) {
      expect(resolveRange(preset, IST, NOW).to).toBe("2026-06-15T18:30:00.000Z");
    }
  });

  it("a site without a timezone falls back to UTC calendar days", () => {
    expect(resolveRange("TODAY", null, NOW)).toEqual({
      from: "2026-06-15T00:00:00.000Z",
      to: "2026-06-16T00:00:00.000Z",
    });
  });

  it("measurements: Today -> raw; 7D/30D -> 1h; 3M/1Y -> unsupported (Phase 7 first-slice cap)", () => {
    expect(planMeasurementRequest("TODAY", IST, NOW)).toMatchObject({ supported: true, resolution: "raw" });
    expect(planMeasurementRequest("7D", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planMeasurementRequest("30D", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });

    const threeMonths = planMeasurementRequest("3M", IST, NOW);
    expect(threeMonths.supported).toBe(false);
    if (!threeMonths.supported) expect(threeMonths.reason).toMatch(/30 days/);
    expect(planMeasurementRequest("1Y", IST, NOW).supported).toBe(false);
  });

  it("energy: every preset is serviceable; 3M/1Y route to 1d", () => {
    expect(planEnergyRequest("TODAY", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("7D", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("30D", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planEnergyRequest("3M", IST, NOW)).toMatchObject({ supported: true, resolution: "1d" });
    expect(planEnergyRequest("1Y", IST, NOW)).toMatchObject({ supported: true, resolution: "1d" });
  });

  it("energy: a 1 Year range is 366 calendar days (same date a year back through today) and fits the 366-day 1d cap", () => {
    const plan = planEnergyRequest("1Y", IST, NOW);
    expect(plan).toMatchObject({ supported: true, resolution: "1d" });
    if (plan.supported) {
      expect((Date.parse(plan.range.to) - Date.parse(plan.range.from)) / DAY_MS).toBe(366);
    }
  });

  it("energy / power quality: a 1 Year spanning 29 Feb is 367 days, over the 366-day 1d cap, and is reported unsupported until the backend limit is extended (follow-up)", () => {
    const leapNow = new Date("2028-03-10T06:00:00.000Z");
    expect(planEnergyRequest("1Y", IST, leapNow).supported).toBe(false);
    expect(planPowerQualityRequest("1Y", IST, leapNow).supported).toBe(false);
  });

  it("demand: no resolution field; TODAY/7D/30D serviceable, 3M/1Y not (31-day cap, no coarser tier)", () => {
    expect(planDemandRequest("TODAY", IST, NOW)).toEqual({ supported: true, range: resolveRange("TODAY", IST, NOW) });
    expect(planDemandRequest("7D", IST, NOW).supported).toBe(true);
    expect(planDemandRequest("30D", IST, NOW).supported).toBe(true);
    expect(planDemandRequest("3M", IST, NOW).supported).toBe(false);
    expect(planDemandRequest("1Y", IST, NOW).supported).toBe(false);
  });

  it("power quality: TODAY/7D -> 15min, 30D -> 1h, 3M/1Y -> 1d; every preset is serviceable", () => {
    expect(planPowerQualityRequest("TODAY", IST, NOW)).toMatchObject({ supported: true, resolution: "15min" });
    expect(planPowerQualityRequest("7D", IST, NOW)).toMatchObject({ supported: true, resolution: "15min" });
    expect(planPowerQualityRequest("30D", IST, NOW)).toMatchObject({ supported: true, resolution: "1h" });
    expect(planPowerQualityRequest("3M", IST, NOW)).toMatchObject({ supported: true, resolution: "1d" });
    expect(planPowerQualityRequest("1Y", IST, NOW)).toMatchObject({ supported: true, resolution: "1d" });
  });

  it("power quality: a London 7 Days containing the October DST change (7 d + 1 h) moves from 15min to 1h", () => {
    const afterFallBack = new Date("2026-10-27T12:00:00.000Z"); // 7D = 21 Oct .. 27 Oct, 25 Oct is 25 h
    const plan = planPowerQualityRequest("7D", "Europe/London", afterFallBack);
    expect(plan).toMatchObject({ supported: true, resolution: "1h" });
  });

  it("isPresetSupported reflects the per-kind capability, including demand and power-quality", () => {
    expect(isPresetSupported("1Y", "energy", NOW, IST)).toBe(true);
    expect(isPresetSupported("1Y", "measurement", NOW, IST)).toBe(false);
    expect(isPresetSupported("30D", "measurement", NOW, IST)).toBe(true);
    expect(isPresetSupported("30D", "demand", NOW, IST)).toBe(true);
    expect(isPresetSupported("1Y", "demand", NOW, IST)).toBe(false);
    expect(isPresetSupported("1Y", "power-quality", NOW, IST)).toBe(true);
    // Without a timezone it evaluates in UTC, with the same capabilities.
    expect(isPresetSupported("30D", "demand", NOW)).toBe(true);
    expect(isPresetSupported("3M", "demand", NOW)).toBe(false);
  });
});

describe("Slice A -- energy comparison ranges (Q54/Q56: historical only)", () => {
  const range7D = resolveRange("7D", IST, NOW);

  it("PREVIOUS_PERIOD shifts back by exactly the window length", () => {
    const shifted = shiftRangeForComparison(range7D, "PREVIOUS_PERIOD");
    const spanMs = Date.parse(range7D.to) - Date.parse(range7D.from);
    expect(Date.parse(shifted.to)).toBe(Date.parse(range7D.from));
    expect(Date.parse(range7D.from) - Date.parse(shifted.from)).toBe(spanMs);
  });

  it("SAME_PERIOD_PREVIOUSLY shifts back exactly one UTC calendar year (still local midnights for IST)", () => {
    const shifted = shiftRangeForComparison(range7D, "SAME_PERIOD_PREVIOUSLY");
    expect(shifted.from).toBe("2025-06-08T18:30:00.000Z");
    expect(shifted.to).toBe("2025-06-15T18:30:00.000Z");
  });

  it("a 1Y comparison window stays within the 366-day-per-call cap", () => {
    const plan = planEnergyComparisonRequest("1Y", "PREVIOUS_PERIOD", IST, NOW);
    expect(plan.supported).toBe(true);
    if (!plan.supported || !plan.comparison) throw new Error("expected a comparison window");
    expect((Date.parse(plan.comparison.to) - Date.parse(plan.comparison.from)) / DAY_MS).toBeLessThanOrEqual(366);
  });
});

describe("Elapsed portion only (PO decision 2026-09-29): comparisons never include unelapsed time", () => {
  // 00:40 IST on 16 Jun 2026 -- 40 minutes after local midnight, the worst case
  // for a range ending at the next local midnight.
  const NEAR_MIDNIGHT = new Date("2026-06-15T19:10:00.000Z");
  const elapsedMs = (from: string, to: string) => Date.parse(to) - Date.parse(from);

  it("1h ranges are cut at the last completed UTC hour; 1d ranges at today's local midnight", () => {
    const range = resolveRange("7D", IST, NEAR_MIDNIGHT);
    expect(comparisonCutoff(range, "1h", IST, NEAR_MIDNIGHT)).toBe("2026-06-15T19:00:00.000Z");
    expect(comparisonCutoff(range, "1d", IST, NEAR_MIDNIGHT)).toBe("2026-06-15T18:30:00.000Z");
    // Never before the range start, never after its end.
    const today = resolveRange("TODAY", IST, new Date("2026-06-15T18:40:00.000Z")); // 00:10 IST
    expect(comparisonCutoff(today, "1h", IST, new Date("2026-06-15T18:40:00.000Z"))).toBe(today.from);
    expect(comparisonCutoff(range, "1h", IST, new Date("2026-06-20T00:00:00.000Z"))).toBe(range.to);
  });

  for (const preset of ["7D", "30D"] as const) {
    it(`${preset} near local midnight: the displayed range is unchanged; both comparison windows cover the same elapsed hours`, () => {
      for (const basis of ["PREVIOUS_PERIOD", "SAME_PERIOD_PREVIOUSLY"] as const) {
        const plan = planEnergyComparisonRequest(preset, basis, IST, NEAR_MIDNIGHT);
        if (!plan.supported || !plan.comparison) throw new Error("expected a comparison window");
        expect(plan.resolution).toBe("1h");
        expect(plan.current).toEqual(resolveRange(preset, IST, NEAR_MIDNIGHT)); // D61/D62 display range
        expect(plan.comparedUntil).toBe("2026-06-15T19:00:00.000Z");
        const elapsed = elapsedMs(plan.current.from, plan.comparedUntil);
        expect(elapsed).toBeLessThan(elapsedMs(plan.current.from, plan.current.to)); // unelapsed time excluded
        expect(elapsedMs(plan.comparison.from, plan.comparison.to)).toBe(elapsed);
        if (basis === "PREVIOUS_PERIOD") {
          const span = elapsedMs(plan.current.from, plan.current.to);
          expect(Date.parse(plan.comparison.from)).toBe(Date.parse(plan.current.from) - span);
        } else {
          expect(plan.comparison.from).toBe(shiftRangeForComparison(plan.current, basis).from);
        }
      }
    });
  }

  for (const preset of ["3M", "1Y"] as const) {
    it(`${preset} near local midnight: 1d data, so both sides are cut at today's local midnight (complete days)`, () => {
      for (const basis of ["PREVIOUS_PERIOD", "SAME_PERIOD_PREVIOUSLY"] as const) {
        const plan = planEnergyComparisonRequest(preset, basis, IST, NEAR_MIDNIGHT);
        if (!plan.supported || !plan.comparison) throw new Error("expected a comparison window");
        expect(plan.resolution).toBe("1d");
        expect(plan.comparedUntil).toBe("2026-06-15T18:30:00.000Z");
        const elapsed = elapsedMs(plan.current.from, plan.comparedUntil);
        expect(elapsed % DAY_MS).toBe(0);
        if (basis === "PREVIOUS_PERIOD") expect(elapsedMs(plan.comparison.from, plan.comparison.to)).toBe(elapsed);
        expect(Date.parse(plan.comparison.to)).toBeLessThanOrEqual(Date.parse(plan.current.from) + elapsed);
      }
    });
  }

  it("Today in its first hour has nothing elapsed to compare yet (no comparison window is requested)", () => {
    const plan = planEnergyComparisonRequest("TODAY", "PREVIOUS_PERIOD", IST, new Date("2026-06-15T18:40:00.000Z"));
    if (!plan.supported) throw new Error("unsupported");
    expect(plan.comparison).toBeNull();
    expect(plan.comparedUntil).toBe(plan.current.from);
  });

  it("London across the DST change: the comparison covers exactly the same elapsed duration", () => {
    const now = new Date("2026-10-27T00:20:00.000Z"); // 00:20 GMT, 27 Oct; 25 Oct was 25 h
    const plan = planEnergyComparisonRequest("7D", "PREVIOUS_PERIOD", "Europe/London", now);
    if (!plan.supported || !plan.comparison) throw new Error("expected a comparison window");
    expect(elapsedMs(plan.comparison.from, plan.comparison.to)).toBe(elapsedMs(plan.current.from, plan.comparedUntil));
  });
});

describe("Slice C -- typical reference: fixed window ending at the range end; complete elapsed days compared", () => {
  it("maps each preset to the endpoint's supported whole-day lengths {1,7,30,90,365}", () => {
    expect(TYPICAL_REFERENCE_WINDOW_DAYS).toEqual({ TODAY: 1, "7D": 7, "30D": 30, "3M": 90, "1Y": 365 });
  });

  it("sends an EXACT whole-day span ending at the calendar range's end, for every preset", () => {
    for (const preset of TIME_RANGE_PRESETS) {
      const plan = planEnergyTypicalReferenceRequest(preset, IST, NOW);
      expect(plan.supported).toBe(true);
      if (!plan.supported) continue;
      expect(plan.current.to).toBe(resolveRange(preset, IST, NOW).to);
      expect(Date.parse(plan.current.to) - Date.parse(plan.current.from)).toBe(
        TYPICAL_REFERENCE_WINDOW_DAYS[preset] * DAY_MS,
      );
      expect(plan.referenceDays).toBe(TYPICAL_REFERENCE_WINDOW_DAYS[preset]);
    }
  });

  it("the compared actual consumption is the complete elapsed local days: range start to today's local midnight", () => {
    const expected = { TODAY: 0, "7D": 6, "30D": 29, "3M": 92, "1Y": 365 } as const; // 15 Jun 2026, IST
    for (const preset of TIME_RANGE_PRESETS) {
      const plan = planEnergyTypicalReferenceRequest(preset, IST, NOW);
      if (!plan.supported) throw new Error("unsupported");
      expect(plan.basisDays).toBe(expected[preset]);
      if (preset === "TODAY") {
        expect(plan.basisRange).toBeNull(); // no complete day yet: no Typical comparison until the day is complete
      } else {
        expect(plan.basisRange).toEqual({ from: resolveRange(preset, IST, NOW).from, to: "2026-06-14T18:30:00.000Z" });
      }
    }
  });

  it("a London 7 Days across the DST change keeps an exact 7 x 24 h reference window", () => {
    const afterFallBack = new Date("2026-10-27T12:00:00.000Z");
    const plan = planEnergyTypicalReferenceRequest("7D", "Europe/London", afterFallBack);
    if (!plan.supported) throw new Error("unsupported");
    expect(Date.parse(plan.current.to) - Date.parse(plan.current.from)).toBe(7 * DAY_MS);
    expect(plan.current.to).toBe("2026-10-28T00:00:00.000Z");
    expect(plan.basisDays).toBe(6);
  });

  it("propagates the consumption range's unsupported reason (a leap-span 1 Year)", () => {
    expect(planEnergyTypicalReferenceRequest("1Y", IST, new Date("2028-03-10T06:00:00.000Z")).supported).toBe(false);
  });
});
