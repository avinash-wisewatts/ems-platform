import { describe, expect, it } from "vitest";
import { localMidnightUtc } from "./calendarRanges";
import { formatSiteLocalDateTime, siteLocalTicks } from "./siteLocalTicks";

const H = 3_600_000;
const D = 24 * H;

describe("siteLocalTicks -- ticks on the site's own wall clock (D24, D25)", () => {
  it("an IST day: local 3-hour ticks, local midnights labelled with the date, never UTC :30 labels", () => {
    const from = Date.parse("2026-10-04T18:30:00Z"); // 05 Oct 00:00 IST
    const ticks = siteLocalTicks(from, from + D, "Asia/Kolkata");
    expect(ticks.map((t) => t.label)).toEqual(["05 Oct", "03:00", "06:00", "09:00", "12:00", "15:00", "18:00", "21:00", "06 Oct"]);
    expect(ticks[1]!.t).toBe(from + 3 * H);
  });

  it("Kathmandu (+05:45): hourly ticks fall on local hours", () => {
    const from = localMidnightUtc("2026-10-05", "Asia/Kathmandu").getTime();
    const ticks = siteLocalTicks(from, from + 6 * H, "Asia/Kathmandu");
    expect(ticks[0]).toEqual({ t: from, label: "05 Oct" });
    expect(ticks[1]).toEqual({ t: from + H, label: "01:00" });
    expect(new Date(ticks[1]!.t).toISOString()).toBe("2026-10-04T19:15:00.000Z");
  });

  it("a DST day (London, 29 Mar 2026, 23 hours): wall-clock ticks, none duplicated", () => {
    const from = localMidnightUtc("2026-03-29", "Europe/London").getTime();
    const to = localMidnightUtc("2026-03-30", "Europe/London").getTime();
    expect(to - from).toBe(23 * H);
    const ticks = siteLocalTicks(from, to, "Europe/London");
    const labels = ticks.map((t) => t.label);
    expect(labels).toContain("06:00");
    expect(new Set(ticks.map((t) => t.t)).size).toBe(ticks.length);
    expect(ticks.find((t) => t.label === "06:00")!.t).toBe(Date.parse("2026-03-29T05:00:00Z")); // BST
  });

  it("30 days: weekly ticks at local midnight", () => {
    const from = localMidnightUtc("2026-09-06", "Asia/Kolkata").getTime();
    const ticks = siteLocalTicks(from, from + 30 * D, "Asia/Kolkata");
    expect(ticks.map((t) => t.label)).toEqual(["06 Sep", "13 Sep", "20 Sep", "27 Sep", "04 Oct"]);
    expect(ticks.every((t) => t.t === localMidnightUtc(new Date(t.t + 6 * H).toISOString().slice(0, 10), "Asia/Kolkata").getTime())).toBe(true);
  });

  it("a year: month starts, labelled month and year", () => {
    const from = localMidnightUtc("2025-10-05", "Asia/Kolkata").getTime();
    const to = localMidnightUtc("2026-10-06", "Asia/Kolkata").getTime();
    expect(siteLocalTicks(from, to, "Asia/Kolkata").map((t) => t.label)).toEqual(["Jan 2026", "Apr 2026", "Jul 2026", "Oct 2026"]);
  });

  it("an empty or inverted range has no ticks", () => {
    expect(siteLocalTicks(1000, 1000, "UTC")).toEqual([]);
    expect(siteLocalTicks(2000, 1000, "UTC")).toEqual([]);
  });

  it("respects maxTicks", () => {
    const from = Date.parse("2026-10-04T18:30:00Z");
    expect(siteLocalTicks(from, from + D, "Asia/Kolkata", 4).map((t) => t.label)).toEqual(["05 Oct", "06:00", "12:00", "18:00", "06 Oct"]);
  });
});

describe("formatSiteLocalDateTime", () => {
  it("HH:MM · DD Mon YYYY in the site timezone, UTC when unknown", () => {
    expect(formatSiteLocalDateTime(Date.parse("2026-10-05T00:15:00Z"), "Asia/Kolkata")).toBe("05:45 · 05 Oct 2026");
    expect(formatSiteLocalDateTime(Date.parse("2026-10-05T00:15:00Z"), null)).toBe("00:15 · 05 Oct 2026");
  });
});
