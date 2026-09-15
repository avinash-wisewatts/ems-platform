import { describe, expect, it } from "vitest";
import { buildEnergyConsumptionExportCsv, csvField, energyConsumptionExportFilename, CSV_COLUMNS } from "./energyExportCsv";
import type { ComparisonResult, TypicalReferenceResult } from "./comparison";
import type { EnergyEvidenceSummary } from "./evidence";
import type { EnergyConsumptionResponse, SiteSummary, SiteTelemetryFreshnessResponse } from "../api/types";

function site(overrides: Partial<SiteSummary> = {}): SiteSummary {
  return {
    site_id: "site-1",
    organization_id: "org-1",
    site_code: "UNIT2",
    site_name: "Unit 2",
    timezone: "Asia/Kolkata",
    ...overrides,
  };
}

const THREE_POINT_SERIES = [
  { bucket_start: "2026-09-01T00:00:00Z", import_kwh: 100.111, export_kwh: null, source_interval_count: 24 },
  { bucket_start: "2026-09-02T00:00:00Z", import_kwh: 200.222, export_kwh: null, source_interval_count: 24 },
  { bucket_start: "2026-09-03T00:00:00Z", import_kwh: 300.333, export_kwh: null, source_interval_count: 24 },
];

function current(overrides: Partial<EnergyConsumptionResponse> = {}): EnergyConsumptionResponse {
  return {
    site_id: "site-1",
    resolution: "1d",
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-08T00:00:00Z",
    no_data: false,
    series: THREE_POINT_SERIES,
    ...overrides,
  };
}

function comparisonResult(overrides: Partial<ComparisonResult> = {}): ComparisonResult {
  return {
    basis: "PREVIOUS_PERIOD",
    currentTotalKwh: 1234.567,
    comparisonTotalKwh: 1000.0,
    deltaKwh: 234.567,
    deltaPercent: 23.4567,
    currentHasData: true,
    comparisonHasData: true,
    ...overrides,
  };
}

function typicalReferenceResult(overrides: Partial<TypicalReferenceResult> = {}): TypicalReferenceResult {
  return {
    ...comparisonResult({ basis: "TYPICAL_HISTORICAL_REFERENCE" }),
    requestedPeriodCount: 8,
    windowsWithDataCount: 6,
    eligiblePeriodCount: 6,
    sufficient: true,
    windows: [],
    ...overrides,
  };
}

function evidence(overrides: Partial<EnergyEvidenceSummary> = {}): EnergyEvidenceSummary {
  return {
    hasData: true,
    totalIntervals: 168,
    validImportIntervals: 160,
    invalidImportIntervals: 8,
    validExportIntervals: 168,
    invalidExportIntervals: 0,
    gapIntervalCount: 2,
    resetIntervalCount: 0,
    rolloverIntervalCount: 0,
    invalidIntervalCount: 1,
    firstSourceBucket: "2026-09-01T00:00:00Z",
    lastSourceBucket: "2026-09-07T23:00:00Z",
    coveragePercent: 95.238,
    ...overrides,
  };
}

function freshness(overrides: Partial<SiteTelemetryFreshnessResponse> = {}): SiteTelemetryFreshnessResponse {
  return {
    site_id: "site-1",
    energy: { state: "FRESH", as_of: "2026-09-08T00:05:00Z" },
    demand: { state: "FRESH", as_of: "2026-09-08T00:05:00Z" },
    power_quality: { state: "FRESH", as_of: "2026-09-08T00:05:00Z" },
    ...overrides,
  };
}

/** Minimal RFC4180-aware line splitter for test assertions -- unlike a
 *  naive `line.split(",")`, this respects quoted fields (which may
 *  themselves contain commas, e.g. comparison_basis_label). */
function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"' && line[i + 1] === '"') {
        current += '"';
        i++;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        current += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      cells.push(current);
      current = "";
    } else {
      current += ch;
    }
  }
  cells.push(current);
  return cells;
}

/** Parses every row (header + all data rows), for asserting row counts,
 *  order, and per-row column values across a multi-row export. */
function parseCsvRows(csv: string): { header: string[]; rows: string[][] } {
  const lines = csv.trim().split("\r\n");
  const [headerLine, ...dataLines] = lines;
  return {
    header: splitCsvLine(headerLine ?? ""),
    rows: dataLines.map(splitCsvLine),
  };
}

/** Cell from a specific data row (default: the first/only data row) --
 *  most tests below have exactly one row and use the default. */
function cell(csv: string, column: string, rowIndex = 0): string {
  const { header, rows } = parseCsvRows(csv);
  const idx = header.indexOf(column);
  expect(idx).toBeGreaterThanOrEqual(0);
  return rows[rowIndex]?.[idx] ?? "";
}

describe("csvField -- RFC4180 escaping", () => {
  it("passes through a plain value unchanged", () => {
    expect(csvField("Unit 2")).toBe("Unit 2");
  });
  it("returns an empty string for null/undefined -- never a fabricated value", () => {
    expect(csvField(null)).toBe("");
    expect(csvField(undefined)).toBe("");
  });
  it("quotes a value containing a comma", () => {
    expect(csvField("Site, Building A")).toBe('"Site, Building A"');
  });
  it("quotes and doubles internal quotes", () => {
    expect(csvField('Site "Main"')).toBe('"Site ""Main"""');
  });
  it("quotes a value containing a newline", () => {
    expect(csvField("line1\nline2")).toBe('"line1\nline2"');
  });
  it("quotes a value containing a carriage return", () => {
    expect(csvField("line1\rline2")).toBe('"line1\rline2"');
  });
  it("serializes numbers and booleans via String()", () => {
    expect(csvField(42)).toBe("42");
    expect(csvField(true)).toBe("true");
    expect(csvField(false)).toBe("false");
  });
});

describe("buildEnergyConsumptionExportCsv -- one row per chart point", () => {
  it("produces a header row plus exactly one data row per current.series point", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { rows } = parseCsvRows(csv);
    expect(rows).toHaveLength(THREE_POINT_SERIES.length);
  });

  it("emits rows in the same order as current.series, with correct timestamp/value per row", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    THREE_POINT_SERIES.forEach((point, i) => {
      expect(cell(csv, "chart_timestamp", i)).toBe(point.bucket_start);
      expect(cell(csv, "energy_consumption_kwh", i)).toBe(point.import_kwh!.toFixed(1));
    });
  });

  it("serializes context fields at 1-decimal precision (matches on-screen .toFixed(1))", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "site_id")).toBe("site-1");
    expect(cell(csv, "site_name")).toBe("Unit 2");
    expect(cell(csv, "site_code")).toBe("UNIT2");
    expect(cell(csv, "metric")).toBe("Energy Consumption");
    expect(cell(csv, "unit")).toBe("kWh");
    expect(cell(csv, "resolution")).toBe("1d");
    expect(cell(csv, "period_from")).toBe("2026-09-01T00:00:00Z");
    expect(cell(csv, "period_to")).toBe("2026-09-08T00:00:00Z");
    expect(cell(csv, "period_has_data")).toBe("true");
    expect(cell(csv, "comparison_basis")).toBe("PREVIOUS_PERIOD");
    expect(cell(csv, "comparison_basis_label")).toBe("Previous period");
    expect(cell(csv, "comparison_value_kwh")).toBe("1000.0");
    expect(cell(csv, "comparison_has_data")).toBe("true");
    expect(cell(csv, "delta_kwh")).toBe("234.6");
    expect(cell(csv, "delta_percent")).toBe("23.5");
  });

  it("repeats every context column identically on every data row", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    for (const col of [
      "site_id",
      "site_name",
      "metric",
      "unit",
      "resolution",
      "period_from",
      "period_to",
      "period_has_data",
      "comparison_basis",
      "comparison_basis_label",
      "comparison_value_kwh",
      "delta_kwh",
      "evidence_coverage_percent",
      "freshness_state",
    ]) {
      const values = new Set(THREE_POINT_SERIES.map((_, i) => cell(csv, col, i)));
      expect(values.size).toBe(1); // identical on every row
    }
  });

  it("serializes evidence and freshness fields verbatim from the already-summarized objects, on every row", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    for (let i = 0; i < THREE_POINT_SERIES.length; i++) {
      expect(cell(csv, "evidence_has_data", i)).toBe("true");
      expect(cell(csv, "evidence_total_intervals", i)).toBe("168");
      expect(cell(csv, "evidence_valid_import_intervals", i)).toBe("160");
      expect(cell(csv, "evidence_invalid_import_intervals", i)).toBe("8");
      expect(cell(csv, "evidence_gap_interval_count", i)).toBe("2");
      expect(cell(csv, "evidence_invalid_interval_count", i)).toBe("1");
      expect(cell(csv, "evidence_coverage_percent", i)).toBe("95.2");
      expect(cell(csv, "evidence_first_source_bucket", i)).toBe("2026-09-01T00:00:00Z");
      expect(cell(csv, "evidence_last_source_bucket", i)).toBe("2026-09-07T23:00:00Z");
      expect(cell(csv, "freshness_state", i)).toBe("FRESH");
      expect(cell(csv, "freshness_as_of", i)).toBe("2026-09-08T00:05:00Z");
    }
  });

  it("leaves typical-reference columns empty when basis is not TYPICAL_HISTORICAL_REFERENCE", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "typical_reference_eligible_periods")).toBe("");
    expect(cell(csv, "typical_reference_requested_periods")).toBe("");
    expect(cell(csv, "typical_reference_sufficient")).toBe("");
  });
});

describe("buildEnergyConsumptionExportCsv -- forbidden fields never appear (regression guard)", () => {
  // Code-review finding (fe01d747 review): no prior test asserted the
  // header's exact column set, so a future accidental addition of an
  // out-of-scope field would pass every existing test silently. This
  // pins the header to CSV_COLUMNS exactly -- the single source of
  // truth -- so ANY unauthorized column (named here or not) fails this
  // test, not just the three named below.
  it("the header contains exactly CSV_COLUMNS, in order -- no more, no fewer", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { header } = parseCsvRows(csv);
    expect(header).toEqual([...CSV_COLUMNS]);
  });

  it("does not include export_kwh, source_interval_count, or any per-point evidence/quality column", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { header } = parseCsvRows(csv);
    // Named explicitly for readability -- the exact-match test above is
    // the actual backstop against anything not listed here, including a
    // per-point evidence/quality column under any other name: every
    // evidence_* column that exists is an aggregate, repeated identically
    // on every row (see the "repeats identically" test above), and no
    // column name in CSV_COLUMNS contains "point" other than the point's
    // own chart_timestamp/energy_consumption_kwh pair.
    expect(header).not.toContain("export_kwh");
    expect(header).not.toContain("source_interval_count");
    expect(header.filter((col) => /point/i.test(col))).toEqual([]);
  });
});

describe("buildEnergyConsumptionExportCsv -- null chart point within a populated series", () => {
  it("retains the null point as its own row with a blank Energy value -- never converted to zero", () => {
    const seriesWithGap = [
      THREE_POINT_SERIES[0]!,
      { bucket_start: "2026-09-02T00:00:00Z", import_kwh: null, export_kwh: null, source_interval_count: 0 },
      THREE_POINT_SERIES[2]!,
    ];
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current({ series: seriesWithGap }),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { rows } = parseCsvRows(csv);
    expect(rows).toHaveLength(3); // the gap is a row, not an omission
    expect(cell(csv, "chart_timestamp", 1)).toBe("2026-09-02T00:00:00Z");
    expect(cell(csv, "energy_consumption_kwh", 1)).toBe(""); // blank, never "0" or "0.0"
    // the period itself still has data (points 0 and 2 are real) --
    // period_has_data is a whole-period flag, distinct from this one
    // point's own gap.
    expect(cell(csv, "period_has_data", 1)).toBe("true");
  });
});

describe("buildEnergyConsumptionExportCsv -- whole-period no-data", () => {
  it("emits the header plus exactly one explicit no-data row when current.no_data is true", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current({ no_data: true, series: [] }),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult({ currentTotalKwh: null, currentHasData: false }),
      referenceResult: null,
      evidence: null,
      freshness: null,
    });
    const { rows } = parseCsvRows(csv);
    expect(rows).toHaveLength(1); // never an empty file, never more than one placeholder
    expect(cell(csv, "chart_timestamp")).toBe("");
    expect(cell(csv, "energy_consumption_kwh")).toBe(""); // never a fabricated number
    expect(cell(csv, "period_has_data")).toBe("false");
  });

  it("also produces the one explicit no-data row defensively when series is empty but no_data was not set", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current({ no_data: false, series: [] }),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { rows } = parseCsvRows(csv);
    expect(rows).toHaveLength(1);
    expect(cell(csv, "chart_timestamp")).toBe("");
    expect(cell(csv, "energy_consumption_kwh")).toBe("");
  });

  it("still carries full context on the no-data row", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current({ no_data: true, series: [] }),
      basis: "SAME_PERIOD_PREVIOUSLY",
      result: comparisonResult({ basis: "SAME_PERIOD_PREVIOUSLY", currentTotalKwh: null, currentHasData: false }),
      referenceResult: null,
      evidence: null,
      freshness: null,
    });
    expect(cell(csv, "site_id")).toBe("site-1");
    expect(cell(csv, "comparison_basis")).toBe("SAME_PERIOD_PREVIOUSLY");
    expect(cell(csv, "comparison_basis_label")).toBe("Same period, one year earlier");
  });
});

describe("buildEnergyConsumptionExportCsv -- comparison stays summary/contextual, never per-point", () => {
  it("comparison fields are identical on every row regardless of series length, and no comparison-series rows are produced", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(), // 3 points
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult({ comparisonTotalKwh: 999.9, deltaKwh: 111.1, deltaPercent: 12.3 }),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { rows } = parseCsvRows(csv);
    // Row count is driven by current.series, not by any comparison-period
    // series -- there is no separate comparison input the builder could
    // even read a series length from (comparisonResult never carries one).
    expect(rows).toHaveLength(THREE_POINT_SERIES.length);
    for (let i = 0; i < rows.length; i++) {
      expect(cell(csv, "comparison_value_kwh", i)).toBe("999.9");
      expect(cell(csv, "delta_kwh", i)).toBe("111.1");
      expect(cell(csv, "delta_percent", i)).toBe("12.3");
    }
  });
});

describe("buildEnergyConsumptionExportCsv -- each comparison basis", () => {
  it("SAME_PERIOD_PREVIOUSLY", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "SAME_PERIOD_PREVIOUSLY",
      result: comparisonResult({ basis: "SAME_PERIOD_PREVIOUSLY" }),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "comparison_basis")).toBe("SAME_PERIOD_PREVIOUSLY");
    expect(cell(csv, "comparison_basis_label")).toBe("Same period, one year earlier");
  });

  it("TYPICAL_HISTORICAL_REFERENCE (sufficient) includes the eligible/requested period counts", () => {
    const ref = typicalReferenceResult();
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "TYPICAL_HISTORICAL_REFERENCE",
      result: ref,
      referenceResult: ref,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "comparison_basis")).toBe("TYPICAL_HISTORICAL_REFERENCE");
    expect(cell(csv, "comparison_basis_label")).toBe("Typical historical consumption");
    expect(cell(csv, "typical_reference_eligible_periods")).toBe("6");
    expect(cell(csv, "typical_reference_requested_periods")).toBe("8");
    expect(cell(csv, "typical_reference_sufficient")).toBe("true");
  });
});

describe("buildEnergyConsumptionExportCsv -- typical-reference insufficient state", () => {
  it("comparison_value_kwh is empty and typical_reference_sufficient is false -- never a fabricated typical value", () => {
    const ref = typicalReferenceResult({
      sufficient: false,
      eligiblePeriodCount: 3,
      comparisonTotalKwh: null,
      deltaKwh: null,
      deltaPercent: null,
      comparisonHasData: false,
    });
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "TYPICAL_HISTORICAL_REFERENCE",
      result: ref,
      referenceResult: ref,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "comparison_value_kwh")).toBe("");
    expect(cell(csv, "comparison_has_data")).toBe("false");
    expect(cell(csv, "delta_kwh")).toBe("");
    expect(cell(csv, "delta_percent")).toBe("");
    expect(cell(csv, "typical_reference_sufficient")).toBe("false");
    expect(cell(csv, "typical_reference_eligible_periods")).toBe("3");
  });
});

describe("buildEnergyConsumptionExportCsv -- null/unavailable evidence", () => {
  it("all evidence_* columns are empty, not zero or fabricated", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: null,
      freshness: freshness(),
    });
    for (const col of [
      "evidence_has_data",
      "evidence_total_intervals",
      "evidence_valid_import_intervals",
      "evidence_invalid_import_intervals",
      "evidence_valid_export_intervals",
      "evidence_invalid_export_intervals",
      "evidence_gap_interval_count",
      "evidence_reset_interval_count",
      "evidence_rollover_interval_count",
      "evidence_invalid_interval_count",
      "evidence_coverage_percent",
      "evidence_first_source_bucket",
      "evidence_last_source_bucket",
    ]) {
      expect(cell(csv, col)).toBe("");
    }
  });
});

describe("buildEnergyConsumptionExportCsv -- evidence present but hasData=false", () => {
  it("all evidence_* numeric/bucket columns are empty (never a literal 0), but evidence_has_data still reports false", () => {
    // Mirrors evidence.ts's EMPTY_SUMMARY -- a real, non-null summary
    // object returned when the evidence endpoint reports no_data for the
    // period. EnergyEvidencePanel.tsx fully suppresses these numbers on
    // screen in this state; the export must not surface them as zeros.
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence({
        hasData: false,
        totalIntervals: 0,
        validImportIntervals: 0,
        invalidImportIntervals: 0,
        validExportIntervals: 0,
        invalidExportIntervals: 0,
        gapIntervalCount: 0,
        resetIntervalCount: 0,
        rolloverIntervalCount: 0,
        invalidIntervalCount: 0,
        firstSourceBucket: null,
        lastSourceBucket: null,
        coveragePercent: null,
      }),
      freshness: freshness(),
    });
    expect(cell(csv, "evidence_has_data")).toBe("false");
    for (const col of [
      "evidence_total_intervals",
      "evidence_valid_import_intervals",
      "evidence_invalid_import_intervals",
      "evidence_valid_export_intervals",
      "evidence_invalid_export_intervals",
      "evidence_gap_interval_count",
      "evidence_reset_interval_count",
      "evidence_rollover_interval_count",
      "evidence_invalid_interval_count",
      "evidence_coverage_percent",
      "evidence_first_source_bucket",
      "evidence_last_source_bucket",
    ]) {
      expect(cell(csv, col)).toBe("");
    }
  });
});

describe("buildEnergyConsumptionExportCsv -- null/unavailable freshness", () => {
  it("freshness_state and freshness_as_of are empty, not a fabricated state", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: null,
    });
    expect(cell(csv, "freshness_state")).toBe("");
    expect(cell(csv, "freshness_as_of")).toBe("");
  });
});

describe("buildEnergyConsumptionExportCsv -- CSV escaping in real fields", () => {
  it("escapes a site name containing a comma and a quote, on every row", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site({ site_name: 'Unit 2, "Main Block"' }),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const { rows } = parseCsvRows(csv);
    expect(rows).toHaveLength(THREE_POINT_SERIES.length);
    for (const line of csv.trim().split("\r\n").slice(1)) {
      expect(line).toContain('"Unit 2, ""Main Block"""');
    }
  });
});

describe("energyConsumptionExportFilename", () => {
  it("slugifies the site name and includes the date-only period bounds", () => {
    const name = energyConsumptionExportFilename({
      site: site({ site_name: "Unit 2" }),
      current: current({ from: "2026-09-01T00:00:00Z", to: "2026-09-08T00:00:00Z" }),
    });
    expect(name).toBe("energy-consumption-unit-2-2026-09-01-to-2026-09-08.csv");
  });

  it("collapses multiple/leading/trailing whitespace in the site name", () => {
    const name = energyConsumptionExportFilename({
      site: site({ site_name: "  Coimbatore   Plant  " }),
      current: current(),
    });
    expect(name).toBe("energy-consumption-coimbatore-plant-2026-09-01-to-2026-09-08.csv");
  });
});
