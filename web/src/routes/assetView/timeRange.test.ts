import { describe, expect, it } from "vitest";
import { ASSET_TIME_RANGE_PRESETS, resolveAssetTimeRange, shiftRangeByOneDay } from "./timeRange";

describe("resolveAssetTimeRange", () => {
  // 2026-09-18T10:00:00Z is 15:30 the same day in Asia/Kolkata (UTC+5:30);
  // local midnight for that calendar day is 2026-09-17T18:30:00Z.
  const now = new Date("2026-09-18T10:00:00.000Z");

  it("Today spans site-local midnight through now", () => {
    expect(resolveAssetTimeRange("TODAY", "Asia/Kolkata", now)).toEqual({
      from: "2026-09-17T18:30:00.000Z",
      to: "2026-09-18T10:00:00.000Z",
    });
  });

  it("Yesterday spans the complete previous site-local calendar day", () => {
    expect(resolveAssetTimeRange("YESTERDAY", "Asia/Kolkata", now)).toEqual({
      from: "2026-09-16T18:30:00.000Z",
      to: "2026-09-17T18:30:00.000Z",
    });
  });

  it("1 Week spans site-local midnight 6 days ago through now", () => {
    expect(resolveAssetTimeRange("1W", "Asia/Kolkata", now)).toEqual({
      from: "2026-09-11T18:30:00.000Z",
      to: "2026-09-18T10:00:00.000Z",
    });
  });

  it("1 Month spans site-local midnight 29 days ago through now", () => {
    expect(resolveAssetTimeRange("1M", "Asia/Kolkata", now)).toEqual({
      from: "2026-08-19T18:30:00.000Z",
      to: "2026-09-18T10:00:00.000Z",
    });
  });

  it("uses UTC boundaries for a UTC site (no shift)", () => {
    expect(resolveAssetTimeRange("TODAY", "UTC", now)).toEqual({
      from: "2026-09-18T00:00:00.000Z",
      to: "2026-09-18T10:00:00.000Z",
    });
  });

  it("falls back to the runtime's own timezone when the site has none configured", () => {
    const result = resolveAssetTimeRange("TODAY", null, now);
    expect(Date.parse(result.from)).not.toBeNaN();
    expect(result.to).toBe(now.toISOString());
  });

  it("two different site timezones resolve Today to different UTC boundaries for the same instant", () => {
    const kolkata = resolveAssetTimeRange("TODAY", "Asia/Kolkata", now);
    const utc = resolveAssetTimeRange("TODAY", "UTC", now);
    expect(kolkata.from).not.toBe(utc.from);
  });

  it("exposes exactly Today, Yesterday, 1 Week, 1 Month -- no 1H/1D/1Y", () => {
    expect(ASSET_TIME_RANGE_PRESETS).toEqual(["TODAY", "YESTERDAY", "1W", "1M"]);
  });
});

describe("shiftRangeByOneDay", () => {
  it("shifts a partial 'Today' window to the SAME clock-time window yesterday, not a duration-equal shift", () => {
    // "Today" so far: site-local midnight through 10:00 (a 10-hour window).
    const today = { from: "2026-09-17T18:30:00.000Z", to: "2026-09-18T10:00:00.000Z" };
    // A naive "shift by this window's own duration" would land on
    // [yesterday 14:00, today 00:00) -- NOT yesterday's midnight-to-10:00.
    // shiftRangeByOneDay must give exactly the same clock-time window one
    // calendar day earlier instead.
    expect(shiftRangeByOneDay(today)).toEqual({
      from: "2026-09-16T18:30:00.000Z",
      to: "2026-09-17T10:00:00.000Z",
    });
  });

  it("shifts a complete day window back by exactly 24 hours", () => {
    const range = { from: "2026-09-17T00:00:00.000Z", to: "2026-09-18T00:00:00.000Z" };
    expect(shiftRangeByOneDay(range)).toEqual({
      from: "2026-09-16T00:00:00.000Z",
      to: "2026-09-17T00:00:00.000Z",
    });
  });
});
