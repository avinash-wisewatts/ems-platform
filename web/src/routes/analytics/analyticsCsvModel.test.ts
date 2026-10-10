import { describe, expect, it } from "vitest";
import type { AnalyticsSeries, AnalyticsSeriesPoint } from "../../api/types";
import {
  analyticsCsvFilename,
  buildAnalyticsCsv,
  csvColumnName,
  formatCsvLocalTimestamp,
  formatCsvUtcTimestamp,
  normalizeSiteName,
} from "./analyticsCsvModel";
import {
  SERIES_FROM,
  SERIES_TO,
  catalogFixture,
  notShownFixture,
  pointFixture,
  seriesFixture,
  seriesResponseFixture,
} from "./analyticsTestFixtures";

const IST = "Asia/Kolkata";

/** Parsed CSV: the header and the data rows as cell arrays (no quoted commas
 *  in these fixtures unless a test says so). */
function parse(csv: string): { header: string[]; rows: string[][] } {
  expect(csv.endsWith("\r\n")).toBe(true);
  const lines = csv.slice(0, -2).split("\r\n");
  return { header: lines[0]!.split(","), rows: lines.slice(1).map((l) => l.split(",")) };
}

/** A measurement (line) series: mean aggregation, no Total. */
function measurement(
  assetId: string,
  dataPoint: string,
  label: string,
  unit: string | null,
  values: (number | null)[],
  overrides: Partial<AnalyticsSeries> = {},
): AnalyticsSeries {
  const points: AnalyticsSeriesPoint[] = values.map((v, i) =>
    pointFixture(i, v, { min: v, max: v, quality: v == null ? "GAP" : "GOOD", evidence_status: null }),
  );
  return seriesFixture(assetId, [], {
    data_point: dataPoint,
    label,
    unit,
    chart_kind: "line",
    aggregation: "mean",
    points,
    ...overrides,
  });
}

describe("buildAnalyticsCsv -- columns (D29)", () => {
  it("timestamps first, then one column per series in request (chart) order, named with the unit", () => {
    const response = seriesResponseFixture({
      series: [
        seriesFixture("a2", [1, 2]),
        measurement("a1", "ACTIVE_POWER", "Power", "kW", [10, 11]),
        seriesFixture("a1", [3, 4], { data_point: "ENERGY_EXPORT", label: "Energy Export" }),
        measurement("a1", "POWER_FACTOR", "Power Factor", null, [0.9, 0.91]),
      ],
    });
    const { header } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(header).toEqual([
      "Timestamp local",
      "Timestamp UTC",
      "Energy-Asset a2 (kWh)",
      "Power-Asset a1 (kW)",
      "Energy Export-Asset a1 (kWh)",
      "Power Factor-Asset a1",
    ]);
  });

  it("per-phase series use the phase codes and never the qualifier (D55, D63, D83)", () => {
    const response = seriesResponseFixture({
      phase: "three_phase",
      series: [
        seriesFixture("a1", [1], { qualifier: "L1" }),
        seriesFixture("a1", [2], { qualifier: "L2" }),
        seriesFixture("a1", [3], { qualifier: "L3" }),
        measurement("a1", "ACTIVE_POWER", "Power", "kW", [4], { qualifier: "L1" }),
        measurement("a1", "VOLTAGE_LINE_LINE", "Line to Line Voltage", "V", [415], { qualifier: "L12" }),
        measurement("a1", "REACTIVE_POWER", "Reactive Power", "kvar", [5], { qualifier: "L3" }),
      ],
    });
    const csv = buildAnalyticsCsv(response, catalogFixture(), IST);
    const { header, rows } = parse(csv);
    expect(header.slice(2)).toEqual([
      "Energy-E1-Asset a1 (kWh)",
      "Energy-E2-Asset a1 (kWh)",
      "Energy-E3-Asset a1 (kWh)",
      "Power-P1-Asset a1 (kW)",
      "Line to Line Voltage-V12-Asset a1 (V)",
      "Reactive Power-Q3-Asset a1 (kvar)",
    ]);
    expect(rows[0]!.slice(2)).toEqual(["1", "2", "3", "4", "415", "5"]);
    expect(csv).not.toMatch(/\bL1\b|\bL12\b|TOTAL|ACTIVE_POWER|ENERGY_IMPORT/);
  });

  it("a name containing a comma or quote is quoted (RFC 4180)", () => {
    const response = seriesResponseFixture({ series: [seriesFixture("a1", [1], { asset_name: 'Chiller "A", North' })] });
    const csv = buildAnalyticsCsv(response, null, IST);
    expect(csv.split("\r\n")[0]).toBe('Timestamp local,Timestamp UTC,"Energy-Chiller ""A"", North (kWh)"');
  });
});

describe("buildAnalyticsCsv -- rows and values", () => {
  it("one row per bucket, ascending, with site-local and UTC timestamps", () => {
    const response = seriesResponseFixture({ series: [seriesFixture("a1", [1.25, 2.5, 3])] });
    const { rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(rows).toEqual([
      ["2026-10-05 00:00", "2026-10-04T18:30:00Z", "1.25"],
      ["2026-10-05 00:15", "2026-10-04T18:45:00Z", "2.5"],
      ["2026-10-05 00:30", "2026-10-04T19:00:00Z", "3"],
    ]);
  });

  it("missing values are blank, never 0; a real 0 stays 0 (D30)", () => {
    const response = seriesResponseFixture({ series: [seriesFixture("a1", [null, 0, 4])] });
    const { rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(rows.map((r) => r[2])).toEqual(["", "0", "4"]);
  });

  it("values are the API's own numbers, unrounded", () => {
    const response = seriesResponseFixture({ series: [seriesFixture("a1", [12.345678, 0.001])] });
    const { rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(rows.map((r) => r[2])).toEqual(["12.345678", "0.001"]);
  });

  it("Energy bars and measurement lines share the timestamp rows of one chart", () => {
    const response = seriesResponseFixture({
      series: [
        seriesFixture("a1", [5, null, 7]),
        measurement("a1", "ACTIVE_POWER", "Power", "kW", [20, 21, null]),
        measurement("a2", "CURRENT", "Current", "A", [null, 3.5, 4]),
      ],
    });
    const { header, rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(header.slice(2)).toEqual(["Energy-Asset a1 (kWh)", "Power-Asset a1 (kW)", "Current-Asset a2 (A)"]);
    expect(rows).toEqual([
      ["2026-10-05 00:00", "2026-10-04T18:30:00Z", "5", "20", ""],
      ["2026-10-05 00:15", "2026-10-04T18:45:00Z", "", "21", "3.5"],
      ["2026-10-05 00:30", "2026-10-04T19:00:00Z", "7", "", "4"],
    ]);
  });

  it("a selected series that is not charted stays as an all-blank column (D77)", () => {
    const noData = seriesFixture("a2", [null, null], { status: "NO_DATA", status_reasons: ["NO_DATA_IN_RANGE"] });
    const notAvailable = notShownFixture("a3", "NOT_AVAILABLE", [], { asset_name: null });
    const resolution = notShownFixture("a4", "RESOLUTION_UNAVAILABLE", ["BEFORE_RETENTION_FLOOR"]);
    const response = seriesResponseFixture({ series: [seriesFixture("a1", [1, 2]), noData, notAvailable, resolution] });
    const { header, rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    // NOT_AVAILABLE has no asset name in the response: the catalogue's is used.
    expect(header.slice(2)).toEqual([
      "Energy-Asset a1 (kWh)",
      "Energy-Asset a2 (kWh)",
      "Energy-Asset a3 (kWh)",
      "Energy-Asset a4 (kWh)",
    ]);
    expect(rows).toEqual([
      ["2026-10-05 00:00", "2026-10-04T18:30:00Z", "1", "", "", ""],
      ["2026-10-05 00:15", "2026-10-04T18:45:00Z", "2", "", "", ""],
    ]);
  });

  it("no charted series: the rows still cover the returned grid, every value blank", () => {
    const response = seriesResponseFixture({
      series: [seriesFixture("a1", [null, null], { status: "NO_DATA", status_reasons: ["NO_DATA_IN_RANGE"] })],
    });
    const { rows } = parse(buildAnalyticsCsv(response, catalogFixture(), IST));
    expect(rows).toEqual([
      ["2026-10-05 00:00", "2026-10-04T18:30:00Z", ""],
      ["2026-10-05 00:15", "2026-10-04T18:45:00Z", ""],
    ]);
  });

  it("nothing requested: the timestamp header alone", () => {
    expect(buildAnalyticsCsv(null, catalogFixture(), IST)).toBe("Timestamp local,Timestamp UTC\r\n");
  });

  it("no quality or coverage columns in v1", () => {
    const response = seriesResponseFixture({
      series: [seriesFixture("a1", [1], { points: [pointFixture(0, 1, { evidence_flags: ["GAPS_DETECTED"] })] })],
    });
    const csv = buildAnalyticsCsv(response, catalogFixture(), IST);
    expect(csv).not.toMatch(/quality|coverage|interval|evidence|GAPS_DETECTED|MEASURED/i);
  });
});

describe("CSV timestamps", () => {
  it("site-local wall clock, 24-hour", () => {
    expect(formatCsvLocalTimestamp(Date.parse("2026-10-05T07:45:00Z"), IST)).toBe("2026-10-05 13:15");
    expect(formatCsvLocalTimestamp(Date.parse("2026-10-04T18:30:00Z"), IST)).toBe("2026-10-05 00:00");
  });

  it("UTC when the site timezone is unknown", () => {
    expect(formatCsvLocalTimestamp(Date.parse("2026-10-04T18:30:00Z"), null)).toBe("2026-10-04 18:30");
  });

  it("the repeated local hour at a DST fall-back is told apart by the UTC column", () => {
    const first = Date.parse("2026-10-25T00:30:00Z"); // 01:30 BST
    const second = Date.parse("2026-10-25T01:30:00Z"); // 01:30 GMT
    expect(formatCsvLocalTimestamp(first, "Europe/London")).toBe("2026-10-25 01:30");
    expect(formatCsvLocalTimestamp(second, "Europe/London")).toBe("2026-10-25 01:30");
    expect(formatCsvUtcTimestamp(first)).toBe("2026-10-25T00:30:00Z");
    expect(formatCsvUtcTimestamp(second)).toBe("2026-10-25T01:30:00Z");
  });
});

describe("analyticsCsvFilename (D31)", () => {
  it("normalized site name and the inclusive local dates of a whole-day range", () => {
    const range = { from: "2026-09-26T18:30:00.000Z", to: "2026-09-30T18:30:00.000Z" };
    expect(analyticsCsvFilename("Radisson Blu", range, IST)).toBe("Radisson_Blu_analytics_27-Sep-2026_to_30-Sep-2026.csv");
  });

  it("one local day", () => {
    expect(analyticsCsvFilename("Coimbatore", { from: SERIES_FROM, to: SERIES_TO }, IST)).toBe(
      "Coimbatore_analytics_05-Oct-2026_to_05-Oct-2026.csv",
    );
  });

  it("a refined range uses the local dates its first and last instants fall on", () => {
    const range = { from: "2026-10-05T03:30:00.000Z", to: "2026-10-06T06:30:00.000Z" }; // 09:00 05 Oct -> 12:00 06 Oct IST
    expect(analyticsCsvFilename("Coimbatore", range, IST)).toBe("Coimbatore_analytics_05-Oct-2026_to_06-Oct-2026.csv");
  });

  it("site names: punctuation and spaces collapse to one underscore; empty falls back", () => {
    expect(normalizeSiteName("  Radisson Blu – Unit 2 / HVAC ")).toBe("Radisson_Blu_Unit_2_HVAC");
    expect(normalizeSiteName("Hôtel Paris")).toBe("Hôtel_Paris");
    expect(normalizeSiteName("")).toBe("Site");
    expect(normalizeSiteName(null)).toBe("Site");
  });
});

describe("csvColumnName", () => {
  it("falls back to the catalogue, then generic words, never a code", () => {
    const s = seriesFixture("a1", [], { asset_name: null, label: null });
    expect(csvColumnName(s, catalogFixture())).toBe("Energy-Asset a1 (kWh)");
    expect(csvColumnName(s, null)).toBe("Data point-Asset (kWh)");
  });
});
