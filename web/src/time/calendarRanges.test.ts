import { describe, expect, it } from "vitest";
import {
  CALENDAR_PRESETS,
  WEEK_START_DAY,
  addDays,
  addMonthsClamped,
  calendarDayCount,
  calendarRange,
  localDateKey,
  localMidnightUtc,
  presetStartKey,
} from "./calendarRanges";

const HOUR_MS = 3_600_000;
const span = (r: { from: string; to: string }) => (Date.parse(r.to) - Date.parse(r.from)) / HOUR_MS;

describe("calendar date arithmetic", () => {
  it("addDays crosses month and year ends", () => {
    expect(addDays("2026-01-01", -1)).toBe("2025-12-31");
    expect(addDays("2026-03-01", -1)).toBe("2026-02-28");
    expect(addDays("2028-03-01", -1)).toBe("2028-02-29");
  });

  it("D62: 3 Months / 1 Year use the target month's last valid day", () => {
    expect(addMonthsClamped("2026-05-31", -3)).toBe("2026-02-28"); // documented example
    expect(addMonthsClamped("2028-02-29", -12)).toBe("2027-02-28"); // documented example
    expect(addMonthsClamped("2028-05-31", -3)).toBe("2028-02-29"); // leap February
    expect(addMonthsClamped("2026-07-31", -3)).toBe("2026-04-30");
    expect(addMonthsClamped("2026-03-15", -3)).toBe("2025-12-15"); // across the year end
    expect(addMonthsClamped("2026-06-15", -12)).toBe("2025-06-15");
  });

  it("preset start dates: today, today-6, today-29, 3 months back, 1 year back", () => {
    expect(presetStartKey("TODAY", "2026-09-29")).toBe("2026-09-29");
    expect(presetStartKey("7D", "2026-09-29")).toBe("2026-09-23");
    expect(presetStartKey("30D", "2026-09-29")).toBe("2026-08-31");
    expect(presetStartKey("3M", "2026-09-29")).toBe("2026-06-29");
    expect(presetStartKey("1Y", "2026-09-29")).toBe("2025-09-29");
  });

  it("the shared week start is Sunday", () => {
    expect(WEEK_START_DAY).toBe(0);
    expect(new Date(Date.UTC(2026, 8, 27)).getUTCDay()).toBe(WEEK_START_DAY); // 27 Sep 2026 is a Sunday
  });
});

describe("local midnight in the site timezone", () => {
  it("IST (UTC+05:30) and Kathmandu (UTC+05:45)", () => {
    expect(localMidnightUtc("2026-09-29", "Asia/Kolkata").toISOString()).toBe("2026-09-28T18:30:00.000Z");
    expect(localMidnightUtc("2026-09-29", "Asia/Kathmandu").toISOString()).toBe("2026-09-28T18:15:00.000Z");
  });

  it("London: midnight uses the offset in force at midnight on both DST change days", () => {
    // Spring forward 29 Mar 2026 at 01:00 GMT: that midnight is still GMT.
    expect(localMidnightUtc("2026-03-29", "Europe/London").toISOString()).toBe("2026-03-29T00:00:00.000Z");
    expect(localMidnightUtc("2026-03-30", "Europe/London").toISOString()).toBe("2026-03-29T23:00:00.000Z");
    // Fall back 25 Oct 2026 at 02:00 BST: that midnight is still BST.
    expect(localMidnightUtc("2026-10-25", "Europe/London").toISOString()).toBe("2026-10-24T23:00:00.000Z");
    expect(localMidnightUtc("2026-10-26", "Europe/London").toISOString()).toBe("2026-10-26T00:00:00.000Z");
  });

  it("the site's local date of an instant, around local midnight", () => {
    expect(localDateKey(new Date("2026-09-28T18:29:59.000Z"), "Asia/Kolkata")).toBe("2026-09-28");
    expect(localDateKey(new Date("2026-09-28T18:30:00.000Z"), "Asia/Kolkata")).toBe("2026-09-29");
    expect(localDateKey(new Date("2026-09-28T18:30:00.000Z"), null)).toBe("2026-09-28"); // UTC fallback
  });
});

describe("calendarRange", () => {
  it("IST: Today is the whole local day even late in the evening", () => {
    const now = new Date("2026-09-29T17:00:00.000Z"); // 22:30 IST
    expect(calendarRange("TODAY", "Asia/Kolkata", now)).toEqual({
      from: "2026-09-28T18:30:00.000Z",
      to: "2026-09-29T18:30:00.000Z",
    });
  });

  it("IST: the local day starts at local midnight, not UTC midnight", () => {
    // 00:15 IST on 30 Sep is still 29 Sep in UTC.
    const now = new Date("2026-09-29T18:45:00.000Z");
    expect(calendarRange("TODAY", "Asia/Kolkata", now).from).toBe("2026-09-29T18:30:00.000Z");
  });

  it("Kathmandu: every preset starts and ends at local midnight", () => {
    const now = new Date("2026-09-29T06:00:00.000Z");
    const expectedTo = "2026-09-29T18:15:00.000Z";
    const expectedFrom = {
      TODAY: "2026-09-28T18:15:00.000Z",
      "7D": "2026-09-22T18:15:00.000Z",
      "30D": "2026-08-30T18:15:00.000Z",
      "3M": "2026-06-28T18:15:00.000Z",
      "1Y": "2025-09-28T18:15:00.000Z",
    } as const;
    for (const preset of CALENDAR_PRESETS) {
      expect(calendarRange(preset, "Asia/Kathmandu", now)).toEqual({ from: expectedFrom[preset], to: expectedTo });
    }
  });

  it("span in days: 1, 7, 30 whole days; 3 Months and 1 Year follow the calendar", () => {
    const now = new Date("2026-09-29T06:00:00.000Z");
    const days = (preset: (typeof CALENDAR_PRESETS)[number]) => calendarDayCount(calendarRange(preset, "Asia/Kolkata", now));
    expect(days("TODAY")).toBe(1);
    expect(days("7D")).toBe(7);
    expect(days("30D")).toBe(30);
    expect(days("3M")).toBe(93); // 29 Jun .. 29 Sep inclusive
    expect(days("1Y")).toBe(366); // 29 Sep 2025 .. 29 Sep 2026 inclusive
  });

  it("D62 month-end: 3 Months from 31 May starts 28 Feb; 1 Year from 29 Feb 2028 starts 28 Feb 2027", () => {
    expect(calendarRange("3M", "Asia/Kolkata", new Date("2026-05-31T06:00:00.000Z")).from).toBe(
      "2026-02-27T18:30:00.000Z", // 28 Feb 00:00 IST
    );
    expect(calendarRange("1Y", "Asia/Kolkata", new Date("2028-02-29T06:00:00.000Z")).from).toBe(
      "2027-02-27T18:30:00.000Z", // 28 Feb 2027 00:00 IST
    );
  });

  it("London DST: Today is 23 h on the spring change and 25 h on the autumn change", () => {
    const spring = calendarRange("TODAY", "Europe/London", new Date("2026-03-29T12:00:00.000Z"));
    expect(spring).toEqual({ from: "2026-03-29T00:00:00.000Z", to: "2026-03-29T23:00:00.000Z" });
    expect(span(spring)).toBe(23);
    expect(calendarDayCount(spring)).toBe(1);

    const autumn = calendarRange("TODAY", "Europe/London", new Date("2026-10-25T12:00:00.000Z"));
    expect(autumn).toEqual({ from: "2026-10-24T23:00:00.000Z", to: "2026-10-26T00:00:00.000Z" });
    expect(span(autumn)).toBe(25);
    expect(calendarDayCount(autumn)).toBe(1);
  });

  it("London DST: 7 Days across a change is 7 local days of 167 or 169 hours", () => {
    const acrossSpring = calendarRange("7D", "Europe/London", new Date("2026-03-31T12:00:00.000Z"));
    expect(acrossSpring).toEqual({ from: "2026-03-25T00:00:00.000Z", to: "2026-03-31T23:00:00.000Z" });
    expect(span(acrossSpring)).toBe(167);
    expect(calendarDayCount(acrossSpring)).toBe(7);

    const acrossAutumn = calendarRange("7D", "Europe/London", new Date("2026-10-27T12:00:00.000Z"));
    expect(span(acrossAutumn)).toBe(169);
    expect(calendarDayCount(acrossAutumn)).toBe(7);
  });

  it("London in summer: local midnight is 23:00 UTC the day before", () => {
    const range = calendarRange("30D", "Europe/London", new Date("2026-07-15T12:00:00.000Z"));
    expect(range).toEqual({ from: "2026-06-15T23:00:00.000Z", to: "2026-07-15T23:00:00.000Z" });
  });

  it("1 Year in a leap span is 366 days; otherwise 365", () => {
    expect(calendarDayCount(calendarRange("1Y", "Asia/Kolkata", new Date("2028-03-10T06:00:00.000Z")))).toBe(367);
    expect(calendarDayCount(calendarRange("1Y", "Asia/Kolkata", new Date("2027-03-10T06:00:00.000Z")))).toBe(366);
  });
});
