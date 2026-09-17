import { describe, expect, it } from "vitest";
import { mtdRange, previousMonthRange, ytdRange } from "./dateWindows";

describe("ytdRange", () => {
  it("spans January 1st UTC through now", () => {
    const now = new Date("2026-09-16T14:32:00Z");
    expect(ytdRange(now)).toEqual({
      from: "2026-01-01T00:00:00.000Z",
      to: "2026-09-16T14:32:00.000Z",
    });
  });
});

describe("mtdRange", () => {
  it("spans the 1st of the current month UTC through now", () => {
    const now = new Date("2026-09-16T14:32:00Z");
    expect(mtdRange(now)).toEqual({
      from: "2026-09-01T00:00:00.000Z",
      to: "2026-09-16T14:32:00.000Z",
    });
  });
});

describe("previousMonthRange", () => {
  it("shifts both endpoints back exactly one calendar month", () => {
    const range = { from: "2026-09-01T00:00:00.000Z", to: "2026-09-16T14:32:00.000Z" };
    expect(previousMonthRange(range)).toEqual({
      from: "2026-08-01T00:00:00.000Z",
      to: "2026-08-16T14:32:00.000Z",
    });
  });

  it("clamps a day-of-month that doesn't exist in the shorter previous month", () => {
    // March 31 has no equivalent in February.
    const range = { from: "2026-03-01T00:00:00.000Z", to: "2026-03-31T10:00:00.000Z" };
    expect(previousMonthRange(range)).toEqual({
      from: "2026-02-01T00:00:00.000Z",
      to: "2026-02-28T10:00:00.000Z",
    });
  });

  it("rolls January back to December of the previous year", () => {
    const range = { from: "2026-01-01T00:00:00.000Z", to: "2026-01-10T00:00:00.000Z" };
    expect(previousMonthRange(range)).toEqual({
      from: "2025-12-01T00:00:00.000Z",
      to: "2025-12-10T00:00:00.000Z",
    });
  });
});
