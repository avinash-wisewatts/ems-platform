import { describe, expect, it } from "vitest";
import {
  dateKeyInTimeZone,
  formatInTimeZone,
  formatTime12hInTimeZone,
  formatTimeAndDateInTimeZone,
  siteLocalDateToUtcInstant,
  startOfDayInTimeZone,
} from "./format";

describe("formatInTimeZone", () => {
  it("renders an ISO instant in the given IANA timezone, not the runtime's local zone", () => {
    // 2026-01-15T18:30:00Z is 00:00 the next day in Asia/Kolkata (UTC+5:30).
    const result = formatInTimeZone("2026-01-15T18:30:00Z", "Asia/Kolkata", {
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
      day: "2-digit",
      month: "short",
    });
    expect(result).toContain("00:00");
    expect(result).toContain("16");
  });

  it("falls back to the runtime's own timezone when none is given", () => {
    const withNull = formatInTimeZone("2026-01-15T12:00:00Z", null, { hour: "2-digit", timeZone: "UTC" });
    expect(withNull).toBeTruthy();
  });

  it("UTC and a positive-offset timezone render different wall-clock hours for the same instant", () => {
    const utc = formatInTimeZone("2026-06-01T10:00:00Z", "UTC", { hour: "2-digit", hour12: false });
    const kolkata = formatInTimeZone("2026-06-01T10:00:00Z", "Asia/Kolkata", { hour: "2-digit", hour12: false });
    expect(utc).not.toBe(kolkata);
  });
});

describe("formatTimeAndDateInTimeZone", () => {
  it("renders 'HH:MM, DD MMM' regardless of locale field ordering", () => {
    const result = formatTimeAndDateInTimeZone("2026-09-17T14:30:00Z", "UTC");
    expect(result).toBe("14:30, 17 Sep");
  });

  it("uses the site timezone to compute both the time and the date", () => {
    // 2026-09-17T19:45:00Z is 01:15 on the 18th in Asia/Kolkata.
    const result = formatTimeAndDateInTimeZone("2026-09-17T19:45:00Z", "Asia/Kolkata");
    expect(result).toBe("01:15, 18 Sep");
  });
});

describe("formatTime12hInTimeZone", () => {
  it("renders 'HH:MMPM' with a zero-padded hour and no space before the day period", () => {
    // 2026-09-18T12:30:00Z is 18:00 the same day in Asia/Kolkata.
    expect(formatTime12hInTimeZone("2026-09-18T12:30:00Z", "Asia/Kolkata")).toBe("06:00PM");
  });

  it("renders 'HH:MMAM' for a morning time", () => {
    // 2026-09-18T02:00:00Z is 07:30 the same day in Asia/Kolkata.
    expect(formatTime12hInTimeZone("2026-09-18T02:00:00Z", "Asia/Kolkata")).toBe("07:30AM");
  });

  it("zero-pads midnight/noon as 12:00AM/12:00PM", () => {
    expect(formatTime12hInTimeZone("2026-09-18T00:00:00Z", "UTC")).toBe("12:00AM");
    expect(formatTime12hInTimeZone("2026-09-18T12:00:00Z", "UTC")).toBe("12:00PM");
  });
});

describe("startOfDayInTimeZone", () => {
  it("returns the UTC instant of local midnight in the given timezone", () => {
    // 2026-09-18T10:00:00Z is 15:30 on the 18th in Asia/Kolkata (UTC+5:30);
    // local midnight for that calendar day is 2026-09-17T18:30:00Z.
    const result = startOfDayInTimeZone(new Date("2026-09-18T10:00:00Z"), "Asia/Kolkata");
    expect(result.toISOString()).toBe("2026-09-17T18:30:00.000Z");
  });

  it("is a no-op shift for UTC itself", () => {
    const result = startOfDayInTimeZone(new Date("2026-09-18T10:00:00Z"), "UTC");
    expect(result.toISOString()).toBe("2026-09-18T00:00:00.000Z");
  });

  it("falls back to the runtime's own timezone when none is given", () => {
    const result = startOfDayInTimeZone(new Date("2026-09-18T10:00:00Z"), null);
    expect(result.getTime()).not.toBeNaN();
    expect(result.getTime()).toBeLessThanOrEqual(new Date("2026-09-18T10:00:00Z").getTime());
  });

  it("rolls back to the previous UTC calendar day near a site's local midnight", () => {
    // 2026-09-18T00:00:01Z is 05:30:01 on the 18th in Kolkata -- still the
    // 18th locally, so local midnight is still 2026-09-17T18:30:00Z, one
    // UTC calendar day earlier than the instant given.
    const result = startOfDayInTimeZone(new Date("2026-09-18T00:00:01Z"), "Asia/Kolkata");
    expect(result.toISOString()).toBe("2026-09-17T18:30:00.000Z");
  });
});

describe("dateKeyInTimeZone", () => {
  it("renders YYYY-MM-DD for the calendar date in the given timezone", () => {
    // 2026-09-18T20:00:00Z is 2026-09-19T01:30 in Asia/Kolkata -- a
    // different calendar date than UTC's.
    expect(dateKeyInTimeZone(new Date("2026-09-18T20:00:00Z"), "UTC")).toBe("2026-09-18");
    expect(dateKeyInTimeZone(new Date("2026-09-18T20:00:00Z"), "Asia/Kolkata")).toBe("2026-09-19");
  });
});

describe("siteLocalDateToUtcInstant", () => {
  it("is the exact inverse of dateKeyInTimeZone / startOfDayInTimeZone", () => {
    const key = "2026-09-19";
    const instant = siteLocalDateToUtcInstant(key, "Asia/Kolkata");
    expect(instant.toISOString()).toBe("2026-09-18T18:30:00.000Z");
    expect(dateKeyInTimeZone(instant, "Asia/Kolkata")).toBe(key);
  });

  it("matches plain UTC midnight when the timezone is UTC", () => {
    expect(siteLocalDateToUtcInstant("2026-09-19", "UTC").toISOString()).toBe("2026-09-19T00:00:00.000Z");
  });
});
