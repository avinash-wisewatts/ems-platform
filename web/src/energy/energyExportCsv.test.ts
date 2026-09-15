import { describe, expect, it } from "vitest";
import { buildEnergyConsumptionExportCsv, csvField, energyConsumptionExportFilename } from "./energyExportCsv";
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

function current(overrides: Partial<EnergyConsumptionResponse> = {}): EnergyConsumptionResponse {
  return {
    site_id: "site-1",
    resolution: "1d",
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-08T00:00:00Z",
    no_data: false,
    series: [],
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

function parseCsv(csv: string): { header: string[]; row: string[] } {
  const lines = csv.trim().split("\r\n");
  const headerLine = lines[0] ?? "";
  const dataLine = lines[1] ?? "";
  return { header: splitCsvLine(headerLine), row: splitCsvLine(dataLine) };
}

function cell(csv: string, column: string): string {
  const { header, row } = parseCsv(csv);
  const idx = header.indexOf(column);
  expect(idx).toBeGreaterThanOrEqual(0);
  return row[idx] ?? "";
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

describe("buildEnergyConsumptionExportCsv -- normal export", () => {
  it("produces a header row and exactly one data row, CRLF-terminated", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const lines = csv.split("\r\n");
    expect(lines).toHaveLength(3); // header, data row, trailing empty from final \r\n
    expect(lines[2]).toBe("");
  });

  it("serializes context, current value, and comparison fields at 1-decimal precision (matches on-screen .toFixed(1))", () => {
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
    expect(cell(csv, "current_value_kwh")).toBe("1234.6");
    expect(cell(csv, "current_has_data")).toBe("true");
    expect(cell(csv, "comparison_basis")).toBe("PREVIOUS_PERIOD");
    expect(cell(csv, "comparison_basis_label")).toBe("Previous period");
    expect(cell(csv, "comparison_value_kwh")).toBe("1000.0");
    expect(cell(csv, "comparison_has_data")).toBe("true");
    expect(cell(csv, "delta_kwh")).toBe("234.6");
    expect(cell(csv, "delta_percent")).toBe("23.5");
  });

  it("serializes evidence and freshness fields verbatim from the already-summarized objects", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    expect(cell(csv, "evidence_has_data")).toBe("true");
    expect(cell(csv, "evidence_total_intervals")).toBe("168");
    expect(cell(csv, "evidence_valid_import_intervals")).toBe("160");
    expect(cell(csv, "evidence_invalid_import_intervals")).toBe("8");
    expect(cell(csv, "evidence_gap_interval_count")).toBe("2");
    expect(cell(csv, "evidence_invalid_interval_count")).toBe("1");
    expect(cell(csv, "evidence_coverage_percent")).toBe("95.2");
    expect(cell(csv, "evidence_first_source_bucket")).toBe("2026-09-01T00:00:00Z");
    expect(cell(csv, "evidence_last_source_bucket")).toBe("2026-09-07T23:00:00Z");
    expect(cell(csv, "freshness_state")).toBe("FRESH");
    expect(cell(csv, "freshness_as_of")).toBe("2026-09-08T00:05:00Z");
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

describe("buildEnergyConsumptionExportCsv -- current.no_data", () => {
  it("current_value_kwh is empty and current_has_data is false, row still emitted", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site(),
      current: current({ no_data: true }),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult({ currentTotalKwh: null, currentHasData: false }),
      referenceResult: null,
      evidence: null,
      freshness: null,
    });
    const { row } = parseCsv(csv);
    expect(row.length).toBeGreaterThan(0); // row is still emitted, never omitted
    expect(cell(csv, "current_value_kwh")).toBe("");
    expect(cell(csv, "current_has_data")).toBe("false");
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
  it("escapes a site name containing a comma and a quote", () => {
    const csv = buildEnergyConsumptionExportCsv({
      site: site({ site_name: 'Unit 2, "Main Block"' }),
      current: current(),
      basis: "PREVIOUS_PERIOD",
      result: comparisonResult(),
      referenceResult: null,
      evidence: evidence(),
      freshness: freshness(),
    });
    const dataLine = csv.split("\r\n")[1];
    expect(dataLine).toContain('"Unit 2, ""Main Block"""');
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
