import { describe, expect, it } from "vitest";
import {
  availableEnergyUsageResolutions,
  bucketEnergyUsage,
  clampDateKey,
  deriveEnergyUsageAvailability,
  planEnergyUsageFetch,
  resolveDefaultEnergyUsageSelection,
  resolveEnergyUsageRequestRange,
  resolveValidResolution,
  sourceResolutionFor,
} from "./energyUsage";
import type { EnergyConsumptionPoint, SiteEnergyAvailabilityResponse } from "../../api/types";

function point(bucketStart: string, importKwh: number | null): EnergyConsumptionPoint {
  return { bucket_start: bucketStart, import_kwh: importKwh, export_kwh: null, source_interval_count: 96 };
}

function availability(overrides: Partial<SiteEnergyAvailabilityResponse> = {}): SiteEnergyAvailabilityResponse {
  return { site_id: "site-1", has_data: true, earliest: "2025-01-01T00:00:00Z", latest: "2026-09-19T10:00:00Z", ...overrides };
}

describe("sourceResolutionFor", () => {
  it("maps each display resolution to its own distinct API resolution", () => {
    expect(sourceResolutionFor("HOURLY")).toBe("1h");
    expect(sourceResolutionFor("DAILY")).toBe("1d");
    expect(sourceResolutionFor("WEEKLY")).toBe("1w");
    expect(sourceResolutionFor("MONTHLY")).toBe("1mo");
    expect(sourceResolutionFor("YEARLY")).toBe("1y");
  });
});

describe("availableEnergyUsageResolutions", () => {
  it("offers all five resolutions for a range of exactly 31 days", () => {
    expect(availableEnergyUsageResolutions("2026-08-20", "2026-09-19")).toEqual([
      "HOURLY",
      "DAILY",
      "WEEKLY",
      "MONTHLY",
      "YEARLY",
    ]);
  });

  it("excludes Hourly once the range exceeds 31 days", () => {
    expect(availableEnergyUsageResolutions("2026-08-19", "2026-09-19")).toEqual([
      "DAILY",
      "WEEKLY",
      "MONTHLY",
      "YEARLY",
    ]);
  });

  it("a single-day range (the Today default) always includes Hourly", () => {
    expect(availableEnergyUsageResolutions("2026-09-19", "2026-09-19")).toEqual([
      "HOURLY",
      "DAILY",
      "WEEKLY",
      "MONTHLY",
      "YEARLY",
    ]);
  });

  it("Daily/Weekly/Monthly/Yearly remain available for a multi-year range -- no additional threshold is invented", () => {
    expect(availableEnergyUsageResolutions("2020-01-01", "2026-09-19")).toEqual([
      "DAILY",
      "WEEKLY",
      "MONTHLY",
      "YEARLY",
    ]);
  });
});

describe("resolveValidResolution", () => {
  it("keeps the current resolution when it is still available", () => {
    expect(resolveValidResolution("WEEKLY", ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])).toBe("WEEKLY");
  });

  it("steps Hourly forward to Daily once Hourly is no longer available", () => {
    expect(resolveValidResolution("HOURLY", ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"])).toBe("DAILY");
  });

  it("falls back to the first available resolution if nothing later in the order matches", () => {
    expect(resolveValidResolution("YEARLY", ["HOURLY", "DAILY"])).toBe("HOURLY");
  });
});

describe("deriveEnergyUsageAvailability", () => {
  const now = new Date("2026-09-19T10:00:00Z"); // 2026-09-19 in both UTC and Asia/Kolkata

  it("uses the real earliest date, in the site's own timezone", () => {
    const result = deriveEnergyUsageAvailability(
      availability({ earliest: "2025-03-17T00:00:00Z", latest: "2026-09-19T10:00:00Z" }),
      "UTC",
      now,
    );
    expect(result).toEqual({ hasData: true, minDateKey: "2025-03-17", maxDateKey: "2026-09-19" });
  });

  it("never restricts the upper bound before today, even if the latest read lags", () => {
    const result = deriveEnergyUsageAvailability(
      availability({ earliest: "2025-01-01T00:00:00Z", latest: "2026-09-17T00:00:00Z" }), // 2 days stale
      "UTC",
      now,
    );
    expect(result.maxDateKey).toBe("2026-09-19"); // today, not the stale latest
  });

  it("a no-data site's bounds collapse to today only -- never a fabricated range", () => {
    const result = deriveEnergyUsageAvailability(availability({ has_data: false, earliest: null, latest: null }), "UTC", now);
    expect(result).toEqual({ hasData: false, minDateKey: "2026-09-19", maxDateKey: "2026-09-19" });
  });

  it("computes 'today' in the SITE's timezone, not UTC", () => {
    const nearMidnightUtc = new Date("2026-09-19T20:00:00Z"); // 2026-09-20 01:30 in Kolkata
    const result = deriveEnergyUsageAvailability(
      availability({ earliest: "2025-01-01T00:00:00Z", latest: "2026-09-17T00:00:00Z" }),
      "Asia/Kolkata",
      nearMidnightUtc,
    );
    expect(result.maxDateKey).toBe("2026-09-20");
  });
});

describe("clampDateKey", () => {
  const bounds = { hasData: true, minDateKey: "2025-01-01", maxDateKey: "2026-09-19" };

  it("passes through a value already inside the bounds", () => {
    expect(clampDateKey("2026-01-15", bounds)).toBe("2026-01-15");
  });

  it("clamps below the minimum", () => {
    expect(clampDateKey("2020-01-01", bounds)).toBe("2025-01-01");
  });

  it("clamps above the maximum", () => {
    expect(clampDateKey("2027-01-01", bounds)).toBe("2026-09-19");
  });
});

describe("resolveDefaultEnergyUsageSelection", () => {
  it("defaults to Today (site-local) at Hourly resolution -- never a rolling preset", () => {
    const now = new Date("2026-09-19T20:00:00Z"); // 2026-09-20 01:30 in Kolkata
    expect(resolveDefaultEnergyUsageSelection("Asia/Kolkata", now)).toEqual({
      from: "2026-09-20",
      to: "2026-09-20",
      resolution: "HOURLY",
    });
    expect(resolveDefaultEnergyUsageSelection("UTC", now)).toEqual({
      from: "2026-09-19",
      to: "2026-09-19",
      resolution: "HOURLY",
    });
  });
});

describe("resolveEnergyUsageRequestRange", () => {
  const now = new Date("2026-09-19T14:32:00Z");

  it("a single 'Today' day requests [site-local midnight, now)", () => {
    expect(resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", "UTC", now)).toEqual({
      from: "2026-09-19T00:00:00.000Z",
      to: "2026-09-19T14:32:00.000Z",
    });
  });

  it("a past, completed day requests [that day's midnight, next day's midnight)", () => {
    expect(resolveEnergyUsageRequestRange("2026-09-10", "2026-09-10", "UTC", now)).toEqual({
      from: "2026-09-10T00:00:00.000Z",
      to: "2026-09-11T00:00:00.000Z",
    });
  });

  it("an arbitrary multi-day range spans from the first day's midnight to the day AFTER the last day's midnight", () => {
    expect(resolveEnergyUsageRequestRange("2026-09-01", "2026-09-05", "UTC", now)).toEqual({
      from: "2026-09-01T00:00:00.000Z",
      to: "2026-09-06T00:00:00.000Z",
    });
  });

  it("uses the SITE's own timezone for the boundary, not UTC", () => {
    expect(resolveEnergyUsageRequestRange("2026-09-10", "2026-09-10", "Asia/Kolkata", now)).toEqual({
      from: "2026-09-09T18:30:00.000Z",
      to: "2026-09-10T18:30:00.000Z",
    });
  });

  it("a range ending 'today' still ends at now, even in a non-UTC timezone", () => {
    const kolkataNow = new Date("2026-09-19T10:00:00Z"); // 2026-09-19T15:30 Kolkata, still the 19th
    expect(resolveEnergyUsageRequestRange("2026-09-15", "2026-09-19", "Asia/Kolkata", kolkataNow)).toEqual({
      from: "2026-09-14T18:30:00.000Z",
      to: "2026-09-19T10:00:00.000Z",
    });
  });
});

describe("planEnergyUsageFetch", () => {
  const now = new Date("2026-09-19T14:32:00Z");

  it("supports Hourly within the 31-day API cap", () => {
    const plan = planEnergyUsageFetch({ from: "2026-09-01", to: "2026-09-19", resolution: "HOURLY" }, "UTC", now);
    expect(plan).toEqual({
      supported: true,
      resolution: "1h",
      range: { from: "2026-09-01T00:00:00.000Z", to: "2026-09-19T14:32:00.000Z" },
    });
  });

  it("rejects Hourly beyond the 31-day API cap with a clear reason -- never silently truncated", () => {
    const plan = planEnergyUsageFetch({ from: "2026-01-01", to: "2026-09-19", resolution: "HOURLY" }, "UTC", now);
    expect(plan.supported).toBe(false);
    if (!plan.supported) {
      expect(plan.reason).toContain("Hourly");
      expect(plan.reason).toContain("31 days");
    }
  });

  it("Weekly/Monthly/Yearly tolerate a range well beyond the 31-day Hourly cap (their own much larger backend cap)", () => {
    const plan = planEnergyUsageFetch({ from: "2020-01-01", to: "2026-09-19", resolution: "YEARLY" }, "UTC", now);
    expect(plan.supported).toBe(true);
    if (plan.supported) expect(plan.resolution).toBe("1y");
  });

  it("Daily uses its own 366-day cap, unaffected by the periodic tiers' larger one", () => {
    const plan = planEnergyUsageFetch({ from: "2024-01-01", to: "2026-09-19", resolution: "DAILY" }, "UTC", now);
    expect(plan.supported).toBe(false);
  });
});

describe("bucketEnergyUsage -- HOURLY", () => {
  it("passes through real hourly buckets and gap-fills a missing hour with null (never a fabricated zero)", () => {
    const range = { from: "2026-09-19T00:00:00.000Z", to: "2026-09-19T03:00:00.000Z" };
    const points = [point("2026-09-19T00:00:00Z", 5), point("2026-09-19T02:00:00Z", 7)]; // 01:00 missing

    const bars = bucketEnergyUsage(points, "HOURLY", range);

    expect(bars).toEqual([
      { t: Date.parse("2026-09-19T00:00:00Z"), kwh: 5 },
      { t: Date.parse("2026-09-19T01:00:00Z"), kwh: null },
      { t: Date.parse("2026-09-19T02:00:00Z"), kwh: 7 },
    ]);
  });

  it("aligns to the whole-UTC-hour grid even when `from` is a half-hour-offset site-local midnight", () => {
    const range = { from: "2026-09-18T18:30:00.000Z", to: "2026-09-18T21:00:00.000Z" };
    const points = [point("2026-09-18T19:00:00Z", 3), point("2026-09-18T20:00:00Z", 4)];

    const bars = bucketEnergyUsage(points, "HOURLY", range);

    expect(bars.map((b) => b.t)).toEqual([Date.parse("2026-09-18T19:00:00Z"), Date.parse("2026-09-18T20:00:00Z")]);
    expect(bars.map((b) => b.kwh)).toEqual([3, 4]);
  });
});

describe("bucketEnergyUsage -- DAILY", () => {
  it("passes through real daily buckets and gap-fills a missing day with null", () => {
    const range = { from: "2026-09-01T00:00:00.000Z", to: "2026-09-04T00:00:00.000Z" };
    const points = [point("2026-09-01T00:00:00Z", 12), point("2026-09-03T00:00:00Z", 18)];

    const bars = bucketEnergyUsage(points, "DAILY", range);

    expect(bars).toEqual([
      { t: Date.parse("2026-09-01T00:00:00Z"), kwh: 12 },
      { t: Date.parse("2026-09-02T00:00:00Z"), kwh: null },
      { t: Date.parse("2026-09-03T00:00:00Z"), kwh: 18 },
    ]);
  });
});

describe("bucketEnergyUsage -- WEEKLY/MONTHLY/YEARLY (server-aggregated passthrough)", () => {
  it("passes through server-returned periods verbatim -- no client-side reconstruction, no gap-filling", () => {
    const range = { from: "2026-06-01T00:00:00.000Z", to: "2026-09-01T00:00:00.000Z" };
    const points = [point("2026-06-01T00:00:00Z", 100), point("2026-08-01T00:00:00Z", 90.5)]; // July has no row at all

    const weekly = bucketEnergyUsage(points, "WEEKLY", range);
    const monthly = bucketEnergyUsage(points, "MONTHLY", range);
    const yearly = bucketEnergyUsage(points, "YEARLY", range);

    for (const bars of [weekly, monthly, yearly]) {
      expect(bars).toEqual([
        { t: Date.parse("2026-06-01T00:00:00Z"), kwh: 100 },
        { t: Date.parse("2026-08-01T00:00:00Z"), kwh: 90.5 },
      ]);
    }
  });

  it("an empty server response yields no bars at all (the overall no-data state is handled by the caller)", () => {
    const range = { from: "2026-06-01T00:00:00.000Z", to: "2026-09-01T00:00:00.000Z" };
    expect(bucketEnergyUsage([], "MONTHLY", range)).toEqual([]);
  });
});
