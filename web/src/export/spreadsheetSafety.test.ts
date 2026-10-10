import { describe, expect, it } from "vitest";
import { neutralizeSpreadsheetText, spreadsheetSafeCell } from "./spreadsheetSafety";

const DANGEROUS: readonly [string, string][] = [
  ["=", '=HYPERLINK("http://evil.example","x")'],
  ["+", "+1+cmd|' /C calc'!A0"],
  ["-", "-2+3"],
  ["@", "@SUM(1+1)"],
  ["tab", "\tTabbed"],
  ["carriage return", "\rReturned"],
  ["line feed", "\nFed"],
];

describe("neutralizeSpreadsheetText", () => {
  it.each(DANGEROUS)("prefixes text starting with %s", (_, text) => {
    expect(neutralizeSpreadsheetText(text)).toBe(`'${text}`);
  });

  it("leaves ordinary text unchanged, including formula characters after the start", () => {
    expect(neutralizeSpreadsheetText("Unit 2")).toBe("Unit 2");
    expect(neutralizeSpreadsheetText("Power-Chiller 1 (kW)")).toBe("Power-Chiller 1 (kW)");
    expect(neutralizeSpreadsheetText("A=B+C")).toBe("A=B+C");
    expect(neutralizeSpreadsheetText("")).toBe("");
  });
});

describe("spreadsheetSafeCell", () => {
  it.each(DANGEROUS)("prefixes a string cell starting with %s", (_, text) => {
    expect(spreadsheetSafeCell(text)).toBe(`'${text}`);
  });

  it("never prefixes numbers, numeric strings, booleans or empty values", () => {
    expect(spreadsheetSafeCell(-3.5)).toBe(-3.5);
    expect(spreadsheetSafeCell("-3.5")).toBe("-3.5");
    expect(spreadsheetSafeCell("-12")).toBe("-12");
    expect(spreadsheetSafeCell("0.0")).toBe("0.0");
    expect(spreadsheetSafeCell(false)).toBe(false);
    expect(spreadsheetSafeCell(null)).toBe(null);
    expect(spreadsheetSafeCell(undefined)).toBe(undefined);
  });

  it("a string that only looks numeric at the start is still text", () => {
    expect(spreadsheetSafeCell("-1+2")).toBe("'-1+2");
    expect(spreadsheetSafeCell("+5")).toBe("'+5");
    expect(spreadsheetSafeCell("-3.5e2")).toBe("'-3.5e2");
  });

  it("leaves ordinary text, timestamps and codes unchanged", () => {
    expect(spreadsheetSafeCell("Unit 2")).toBe("Unit 2");
    expect(spreadsheetSafeCell("2026-09-01T00:00:00Z")).toBe("2026-09-01T00:00:00Z");
    expect(spreadsheetSafeCell("PREVIOUS_PERIOD")).toBe("PREVIOUS_PERIOD");
  });
});
