import { describe, expect, it } from "vitest";
import type { DemandIntervalPoint } from "../api/types";
import {
  completedIntervalStatusExplanation,
  completedIntervalStatusLabel,
  completedIntervalStatusText,
  demandIntervalLengthLabel,
  formatDemandInterval,
  reliableDemandKw,
} from "./demandInterval";

function interval(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return {
    interval_start: "2026-10-13T10:00:00Z",
    interval_end: "2026-10-13T10:15:00Z",
    demand_kw: 42.5,
    peak_power_kw: 50.1,
    quality_status: "VALID",
    coverage_percent: 100,
    ...overrides,
  };
}

describe("formatDemandInterval", () => {
  it("formats an interval in the site timezone with a fixed month abbreviation", () => {
    expect(formatDemandInterval("2026-09-08T11:15:00Z", "2026-09-08T11:30:00Z", "Asia/Kolkata")).toBe(
      "16:45–17:00, 08 Sep",
    );
  });

  it("dates an interval ending at site-local midnight by its start", () => {
    // [18:15, 18:30) UTC = [23:45, 00:00) IST.
    expect(formatDemandInterval("2026-10-12T18:15:00Z", "2026-10-12T18:30:00Z", "Asia/Kolkata")).toBe(
      "23:45–00:00, 12 Oct",
    );
  });

  it("dates the first interval of a site-local day by that day, not the UTC day", () => {
    // [18:30, 18:45) UTC on 12 Oct = [00:00, 00:15) IST on 13 Oct.
    expect(formatDemandInterval("2026-10-12T18:30:00Z", "2026-10-12T18:45:00Z", "Asia/Kolkata")).toBe(
      "00:00–00:15, 13 Oct",
    );
  });

  it("formats the same instants for a different site timezone", () => {
    expect(formatDemandInterval("2026-10-12T18:30:00Z", "2026-10-12T18:45:00Z", "UTC")).toBe("18:30–18:45, 12 Oct");
  });

  it("accepts offset timestamps as the API may return them", () => {
    expect(
      formatDemandInterval("2026-10-13T00:00:00+05:30", "2026-10-13T00:15:00+05:30", "Asia/Kolkata"),
    ).toBe("00:00–00:15, 13 Oct");
  });
});

describe("demandIntervalLengthLabel", () => {
  it("labels the interval length from its boundaries", () => {
    expect(demandIntervalLengthLabel("2026-10-13T10:00:00Z", "2026-10-13T10:15:00Z")).toBe("15-min");
    expect(demandIntervalLengthLabel("2026-10-13T10:00:00Z", "2026-10-13T10:30:00Z")).toBe("30-min");
  });
});

describe("reliableDemandKw", () => {
  it("returns the value of a VALID interval", () => {
    expect(reliableDemandKw(interval())).toBe(42.5);
  });

  it.each(["INCOMPLETE", "NO_DATA", "INVALID_SOURCE", "SOURCE_BOUNDARY", "INSUFFICIENT_SOURCE_RESOLUTION", "NEW"])(
    "never returns a value for a %s interval, even when one was calculated",
    (status) => {
      expect(reliableDemandKw(interval({ quality_status: status, demand_kw: 31.7 }))).toBeNull();
    },
  );

  it("returns null for a VALID interval without a value", () => {
    expect(reliableDemandKw(interval({ demand_kw: null }))).toBeNull();
  });
});

describe("completed-interval status wording", () => {
  it.each([
    ["VALID", "Complete data"],
    ["INCOMPLETE", "Incomplete data"],
    ["NO_DATA", "Data unavailable"],
    ["INVALID_SOURCE", "Data unavailable"],
    ["SOURCE_BOUNDARY", "Data unavailable"],
    ["INSUFFICIENT_SOURCE_RESOLUTION", "Data unavailable"],
    ["SOMETHING_NEW", "Data unavailable"],
  ])("labels %s as %s, never the raw value", (status, label) => {
    expect(completedIntervalStatusLabel(status)).toBe(label);
  });

  it("labels a missing status as unavailable", () => {
    expect(completedIntervalStatusLabel(null)).toBe("Data unavailable");
    expect(completedIntervalStatusLabel(undefined)).toBe("Data unavailable");
  });

  it("adds coverage to an INCOMPLETE interval only", () => {
    expect(completedIntervalStatusText(interval({ quality_status: "INCOMPLETE", coverage_percent: 72.4 }))).toBe(
      "Incomplete data (72% coverage)",
    );
    expect(completedIntervalStatusText(interval({ quality_status: "INCOMPLETE", coverage_percent: null }))).toBe(
      "Incomplete data",
    );
    expect(completedIntervalStatusText(interval())).toBe("Complete data");
    expect(completedIntervalStatusText(interval({ quality_status: "NO_DATA", coverage_percent: 0 }))).toBe(
      "Data unavailable",
    );
  });

  it("explains that an incomplete or unavailable value is not shown", () => {
    expect(completedIntervalStatusExplanation("INCOMPLETE")).toContain("not shown");
    expect(completedIntervalStatusExplanation("NO_DATA")).toContain("no value is shown");
    expect(completedIntervalStatusExplanation(null)).toContain("no value is shown");
    expect(completedIntervalStatusExplanation("VALID")).not.toContain("not");
  });
});
