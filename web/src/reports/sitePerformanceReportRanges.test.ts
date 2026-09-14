import { describe, expect, it } from "vitest";
import {
  planReportDemandRequest,
  planReportEnergyRequest,
  planReportEnergyTypicalReferenceRequest,
  planReportPowerQualityRequest,
  resolveCalendarPeriod,
  REPORT_PERIODS,
  REPORT_PERIOD_LABELS,
} from "./sitePerformanceReportRanges";

// A Wednesday, well inside a month/quarter/year, for deterministic period math.
const NOW = new Date("2026-09-16T10:00:00.000Z");

describe("resolveCalendarPeriod -- current-calendar to-date windows (ADR-015 gap resolution 3)", () => {
  it("WEEKLY starts on Monday of the current ISO week", () => {
    const range = resolveCalendarPeriod("WEEKLY", NOW);
    // 2026-09-16 is a Wednesday; Monday is 2026-09-14.
    expect(range.from).toBe("2026-09-14T00:00:00.000Z");
    expect(range.to).toBe(NOW.toISOString());
  });

  it("MONTHLY starts on the 1st of the current month", () => {
    const range = resolveCalendarPeriod("MONTHLY", NOW);
    expect(range.from).toBe("2026-09-01T00:00:00.000Z");
  });

  it("QUARTERLY starts on the 1st of the current quarter", () => {
    // September is in Q3 (Jul-Sep) -> quarter start July 1.
    const range = resolveCalendarPeriod("QUARTERLY", NOW);
    expect(range.from).toBe("2026-07-01T00:00:00.000Z");
  });

  it("YEARLY starts on January 1st of the current year", () => {
    const range = resolveCalendarPeriod("YEARLY", NOW);
    expect(range.from).toBe("2026-01-01T00:00:00.000Z");
  });

  it("every predefined period has a label, and CUSTOM is the fifth, non-calendar-computed period", () => {
    expect(REPORT_PERIODS).toEqual(["WEEKLY", "MONTHLY", "QUARTERLY", "YEARLY", "CUSTOM"]);
    for (const p of REPORT_PERIODS) {
      expect(REPORT_PERIOD_LABELS[p]).toBeTruthy();
    }
  });
});

describe("planReportEnergyRequest -- reuses ../time/ranges.ts's own ENERGY_MAX_WINDOW_S, no new threshold", () => {
  it("supports a typical monthly-to-date window at 1h resolution when within the 31-day cap", () => {
    const plan = planReportEnergyRequest({ from: "2026-09-01T00:00:00.000Z", to: "2026-09-05T00:00:00.000Z" });
    expect(plan.supported).toBe(true);
  });

  it("falls back to 1d resolution, still supported, for a full year (within the 366-day cap)", () => {
    const plan = planReportEnergyRequest({ from: "2026-01-01T00:00:00.000Z", to: "2026-12-31T00:00:00.000Z" });
    expect(plan.supported).toBe(true);
    if (plan.supported) expect(plan.resolution).toBe("1d");
  });
});

describe("planReportDemandRequest -- the existing 31-day demand cap makes Quarterly/Yearly unsupported", () => {
  it("supports a window at or under 31 days", () => {
    const plan = planReportDemandRequest({ from: "2026-09-01T00:00:00.000Z", to: "2026-09-20T00:00:00.000Z" });
    expect(plan.supported).toBe(true);
  });

  it("reports unsupported, with a reason, for a full quarter", () => {
    const plan = planReportDemandRequest({ from: "2026-07-01T00:00:00.000Z", to: "2026-09-16T10:00:00.000Z" });
    expect(plan.supported).toBe(false);
    if (!plan.supported) expect(plan.reason).toMatch(/31 days/);
  });
});

describe("planReportPowerQualityRequest -- reuses the existing tiered caps", () => {
  it("supports a full year at 1d resolution", () => {
    const plan = planReportPowerQualityRequest({ from: "2026-01-01T00:00:00.000Z", to: "2026-12-31T00:00:00.000Z" });
    expect(plan.supported).toBe(true);
    if (plan.supported) expect(plan.resolution).toBe("1d");
  });
});

describe("planReportEnergyTypicalReferenceRequest -- ADR-015 gap resolution 6: exact whole-day windows only", () => {
  it("supports an exact 7-day window", () => {
    const plan = planReportEnergyTypicalReferenceRequest({
      from: "2026-09-01T00:00:00.000Z",
      to: "2026-09-08T00:00:00.000Z",
    });
    expect(plan.supported).toBe(true);
  });

  it("reports unsupported, honestly, for a calendar-to-date window that isn't a whole number of days", () => {
    // "This month to date" on the 16th at 10:00 -- a 15.4-day window, not whole.
    const plan = planReportEnergyTypicalReferenceRequest({
      from: "2026-09-01T00:00:00.000Z",
      to: "2026-09-16T10:00:00.000Z",
    });
    expect(plan.supported).toBe(false);
    if (!plan.supported) expect(plan.reason).toMatch(/whole-day/);
  });
});
