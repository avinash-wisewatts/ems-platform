import { describe, expect, it, vi } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { EnergyOverview } from "./EnergyOverview";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type { EnergyTypicalReferenceResponse } from "../../api/types";

// Q75 Increment 1 -- mocks the DOM-side-effect download trigger only
// (mirrors SitePerformanceReportView.test.tsx's mocking of jsPDF's
// `.save()` for the same reason: keep component tests free of a real
// browser download side effect under jsdom, while buildEnergyConsumption
// ExportCsv itself is exercised for real in energyExportCsv.test.ts).
const mockDownloadCsv = vi.fn();
vi.mock("../../export/downloadCsv", () => ({
  downloadCsv: (...args: unknown[]) => mockDownloadCsv(...args),
}));

const SITE_ID = SITES_ONE.sites[0]!.site_id;

/** Minimal RFC4180-aware line splitter for wiring-test assertions --
 *  mirrors energyExportCsv.test.ts's own helper (quoted fields, e.g.
 *  comparison_basis_label, may contain commas that a naive split would
 *  break on). This file only needs it to check that the real component
 *  state (current series/points, selected basis) lands in the correct
 *  column, in the right number of rows -- the CSV's full schema/escaping
 *  is energyExportCsv.test.ts's responsibility, not this one's. */
function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let value = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"' && line[i + 1] === '"') {
        value += '"';
        i++;
      } else if (ch === '"') {
        inQuotes = false;
      } else {
        value += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === ",") {
      cells.push(value);
      value = "";
    } else {
      value += ch;
    }
  }
  cells.push(value);
  return cells;
}

function csvDataRows(csv: string): string[][] {
  const lines = csv.trim().split("\r\n");
  return lines.slice(1).map(splitCsvLine);
}

function csvCell(csv: string, column: string, rowIndex = 0): string {
  const lines = csv.trim().split("\r\n");
  const header = splitCsvLine(lines[0] ?? "");
  const rows = csvDataRows(csv);
  const idx = header.indexOf(column);
  expect(idx).toBeGreaterThanOrEqual(0);
  return rows[rowIndex]?.[idx] ?? "";
}

function energyResponse(importKwh: number, noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [
          { bucket_start: "2026-06-01T00:00:00Z", import_kwh: importKwh, export_kwh: null, source_interval_count: 4 },
        ],
  };
}

/** Multi-point consumption fixture for Q75 chart-data export tests --
 *  distinct per-point values so row order/values are unambiguously
 *  checkable, unlike energyResponse's single-point fixture used by the
 *  rest of this file's pre-existing tests. */
function energySeriesResponse(points: Array<{ bucket_start: string; import_kwh: number | null }>) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: false,
    series: points.map((p) => ({ ...p, export_kwh: null, source_interval_count: 4 })),
  };
}

const THREE_DISTINCT_POINTS = [
  { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 10 },
  { bucket_start: "2026-06-01T01:00:00Z", import_kwh: 20 },
  { bucket_start: "2026-06-01T02:00:00Z", import_kwh: 30 },
];

function evidenceResponse(
  overrides: Partial<{
    valid_import_intervals: number;
    invalid_import_intervals: number;
    gap_interval_count: number;
    reset_interval_count: number;
    rollover_interval_count: number;
  }> = {},
  noData = false,
) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [
          {
            bucket_start: "2026-06-01T00:00:00Z",
            source_interval_count: 4,
            valid_import_intervals: 4,
            invalid_import_intervals: 0,
            valid_export_intervals: 4,
            invalid_export_intervals: 0,
            gap_interval_count: 0,
            reset_interval_count: 0,
            rollover_interval_count: 0,
            invalid_interval_count: 0,
            first_source_bucket: "2026-06-01T00:00:00Z",
            last_source_bucket: "2026-06-01T00:45:00Z",
            ...overrides,
          },
        ],
  };
}

function typicalReferenceWindow(
  index: number,
  overrides: Partial<EnergyTypicalReferenceResponse["windows"][number]> = {},
): EnergyTypicalReferenceResponse["windows"][number] {
  return {
    window_index: index,
    from: "2026-05-01T00:00:00Z",
    to: "2026-05-08T00:00:00Z",
    has_data: true,
    total_kwh: 100,
    source_interval_count: 7,
    valid_import_intervals: 7,
    coverage_percent: 100,
    eligible: true,
    gap_interval_count: 0,
    reset_interval_count: 0,
    rollover_interval_count: 0,
    invalid_interval_count: 0,
    ...overrides,
  };
}

function typicalReferenceResponse(
  overrides: Partial<EnergyTypicalReferenceResponse> = {},
): EnergyTypicalReferenceResponse {
  return {
    site_id: SITE_ID,
    period_length_days: 7,
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    typical_kwh: 100,
    requested_period_count: 8,
    windows_with_data_count: 8,
    eligible_period_count: 8,
    sufficient: true,
    windows: Array.from({ length: 8 }, (_, i) => typicalReferenceWindow(i + 1)),
    ...overrides,
  };
}

/** Routes a stubbed URL to the right endpoint -- both evidence and
 *  typical-reference are superstrings of the plain consumption path, so
 *  they must be checked first. */
function isEvidenceUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption/evidence`);
}
function isTypicalReferenceUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption/typical-reference`);
}
function isConsumptionUrl(url: string): boolean {
  return (
    !isEvidenceUrl(url) &&
    !isTypicalReferenceUrl(url) &&
    url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption`)
  );
}
function isFreshnessUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`);
}
function freshnessResponse(state = "FRESH") {
  return {
    site_id: SITE_ID,
    energy: { state, as_of: "2026-09-13T09:58:00Z" },
    demand: { state: "FRESH", as_of: "2026-09-13T09:58:00Z" },
    power_quality: { state: "FRESH", as_of: "2026-09-13T09:58:00Z" },
  };
}

describe("EnergyOverview (Slice A/C -- Energy Performance)", () => {
  it("composes Current Value -> Comparison -> Trend -> Status -> Evidence from the unmodified consumption endpoint plus the additive evidence endpoint", async () => {
    let consumptionCalls = 0;
    let evidenceCalls = 0;
    stubFetch((url) => {
      if (isEvidenceUrl(url)) {
        evidenceCalls += 1;
        return { jsonBody: evidenceResponse() };
      }
      if (isConsumptionUrl(url)) {
        consumptionCalls += 1;
        // First call = current period (higher usage); second = comparison (lower).
        return { jsonBody: consumptionCalls === 1 ? energyResponse(120) : energyResponse(100) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(consumptionCalls).toBe(2));
    await waitFor(() => expect(evidenceCalls).toBe(1));
    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("120.0 kWh"));

    expect(screen.getByTestId("energy-comparison")).toHaveTextContent("100.0 kWh");
    expect(screen.getByTestId("energy-delta")).toHaveTextContent("+20.0 kWh");
    expect(screen.getByTestId("energy-delta")).toHaveTextContent("+20.0%");
    expect(screen.getByTestId("status-badge")).toHaveTextContent("Higher than comparison");
    expect(screen.getByTestId("chart-frame")).toBeTruthy();

    // Evidence section -- real coverage counters, not "not yet available".
    const evidence = screen.getByTestId("energy-evidence-section");
    expect(evidence).toHaveTextContent("Evidence");
    expect(screen.getByTestId("energy-evidence-coverage")).toHaveTextContent("100.0%");
    expect(screen.queryByTestId("energy-evidence-gaps")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-resets")).toBeNull();
    expect(screen.queryByTestId("energy-evidence-rollovers")).toBeNull();
  });

  it("renders NoDataYet for the current period, never an error, when the range genuinely has no data", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse({}, true) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(0, true) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getAllByTestId("state-no-data").length).toBeGreaterThan(0));
    expect(screen.getByTestId("energy-evidence-no-data")).toBeTruthy();
  });

  it("switching to SAME_PERIOD_PREVIOUSLY re-fetches: 2 consumption calls + 1 evidence call", async () => {
    let consumptionCalls: string[] = [];
    let evidenceCalls: string[] = [];
    stubFetch((url) => {
      if (isEvidenceUrl(url)) {
        evidenceCalls.push(url);
        return { jsonBody: evidenceResponse() };
      }
      if (isConsumptionUrl(url)) {
        consumptionCalls.push(url);
        return { jsonBody: energyResponse(100) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(consumptionCalls.length).toBe(2));
    await waitFor(() => expect(evidenceCalls.length).toBe(1));

    consumptionCalls = [];
    evidenceCalls = [];
    screen.getByTestId("comparison-basis-SAME_PERIOD_PREVIOUSLY").click();
    await waitFor(() => expect(consumptionCalls.length).toBe(2));
    await waitFor(() => expect(evidenceCalls.length).toBe(1));
  });

  it("TYPICAL_HISTORICAL_REFERENCE: one bounded reference call (no frontend N+1); sufficient history reports the server-computed median, and an eligible period with a reset/rollover stays included and is communicated explicitly", async () => {
    let referenceCalls = 0;
    let typicalMode = false;
    stubFetch((url) => {
      if (isTypicalReferenceUrl(url)) {
        referenceCalls += 1;
        return {
          jsonBody: typicalReferenceResponse({
            typical_kwh: 100.5,
            windows: [
              typicalReferenceWindow(1, { reset_interval_count: 2 }),
              typicalReferenceWindow(2, { rollover_interval_count: 1 }),
              ...Array.from({ length: 6 }, (_, i) => typicalReferenceWindow(i + 3)),
            ],
          }),
        };
      }
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isConsumptionUrl(url)) return { jsonBody: typicalMode ? energyResponse(118) : energyResponse(999) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("999.0 kWh"));

    typicalMode = true;
    screen.getByTestId("comparison-basis-TYPICAL_HISTORICAL_REFERENCE").click();

    await waitFor(() => expect(referenceCalls).toBe(1)); // one bounded call, never N+1
    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("118.0 kWh"));

    expect(screen.getByTestId("energy-comparison")).toHaveTextContent("100.5 kWh");
    expect(screen.getByTestId("energy-typical-reference-evidence")).toHaveTextContent(
      "based on 8 of 8 comparable historical periods",
    );
    expect(screen.getByTestId("energy-delta")).toHaveTextContent("+17.5 kWh");
    expect(screen.getByTestId("status-badge")).toHaveTextContent("Higher than comparison");

    // Reset/rollover on an included period never excludes it, and the UI
    // says so explicitly rather than hiding it.
    expect(screen.getByTestId("energy-typical-reference-note-reset")).toHaveTextContent(
      "1 of 8 included periods had a meter reset -- still included.",
    );
    expect(screen.getByTestId("energy-typical-reference-note-rollover")).toHaveTextContent(
      "1 of 8 included periods had a meter rollover -- still included.",
    );
    expect(screen.queryByTestId("energy-typical-reference-note-gap")).toBeNull();
    expect(screen.queryByTestId("energy-typical-reference-note-invalid")).toBeNull();
  });

  it("TYPICAL_HISTORICAL_REFERENCE: insufficient history is reported honestly, never a manufactured value", async () => {
    let typicalMode = false;
    stubFetch((url) => {
      if (isTypicalReferenceUrl(url)) {
        return {
          jsonBody: typicalReferenceResponse({
            typical_kwh: null,
            sufficient: false,
            eligible_period_count: 4,
            windows_with_data_count: 5,
            windows: [
              ...Array.from({ length: 4 }, (_, i) => typicalReferenceWindow(i + 1)),
              typicalReferenceWindow(5, { eligible: false, coverage_percent: 40, has_data: true }),
              ...Array.from({ length: 3 }, (_, i) =>
                typicalReferenceWindow(i + 6, { eligible: false, has_data: false, total_kwh: null, coverage_percent: null }),
              ),
            ],
          }),
        };
      }
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isConsumptionUrl(url)) return { jsonBody: typicalMode ? energyResponse(118) : energyResponse(999) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("999.0 kWh"));

    typicalMode = true;
    screen.getByTestId("comparison-basis-TYPICAL_HISTORICAL_REFERENCE").click();

    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("118.0 kWh"));

    expect(screen.getByTestId("energy-comparison")).toHaveTextContent("Not enough historical data");
    expect(screen.getByTestId("energy-comparison")).toHaveTextContent("4 of 8");
    expect(screen.queryByTestId("energy-delta")).toBeNull();
    expect(screen.queryByTestId("energy-typical-reference-notes")).toBeNull();
  });

  it("Evidence panel surfaces gaps, resets, and rollovers by their own names when present", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) {
        return {
          jsonBody: evidenceResponse({
            valid_import_intervals: 2,
            invalid_import_intervals: 2,
            gap_interval_count: 1,
            reset_interval_count: 1,
            rollover_interval_count: 1,
          }),
        };
      }
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(100) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("energy-evidence-panel")).toBeTruthy());
    expect(screen.getByTestId("energy-evidence-coverage")).toHaveTextContent("50.0%");
    expect(screen.getByTestId("energy-evidence-gaps")).toHaveTextContent("1 interval");
    expect(screen.getByTestId("energy-evidence-resets")).toHaveTextContent("1 interval");
    expect(screen.getByTestId("energy-evidence-rollovers")).toHaveTextContent("1 interval");
    // Never renders through the unrelated five-value QualityIndicator lattice.
    expect(screen.queryByTestId("quality-indicator")).toBeNull();
  });

  it("MVP-4: shows device freshness in the Evidence section, additive to the existing evidence content", async () => {
    stubFetch((url) => {
      if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse("STALE") };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(120) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("120.0 kWh"));
    await waitFor(() => expect(screen.getByTestId("energy-freshness")).toHaveTextContent("Outdated"));
    // Additive, not a replacement -- the existing evidence content is unchanged.
    expect(screen.getByTestId("energy-evidence-coverage")).toHaveTextContent("100.0%");
  });

  it("MVP-4: a freshness fetch failure is non-blocking -- Current/Comparison/Trend/Evidence still render", async () => {
    stubFetch((url) => {
      if (isFreshnessUrl(url)) return { status: 500, jsonBody: { error: "server_error" } };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(120) };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("120.0 kWh"));
    expect(screen.getByTestId("energy-evidence-coverage")).toHaveTextContent("100.0%");
    expect(screen.queryByTestId("freshness-indicator")).toBeNull();
  });

  describe("Q75 -- contextual Energy chart-data CSV export (corrected 2026-09-15)", () => {
    it("the Export action is not present while loading (before status === \"ready\")", async () => {
      // All fetches (consumption/evidence/freshness) hang forever -- status
      // stays at its initial "loading" value indefinitely -- while the site
      // loader (a separate, non-fetch prop) still resolves, so the page
      // shell mounts. This deterministically isolates the "loading" state,
      // unlike racing a real fetch resolution against a waitFor poll.
      vi.stubGlobal(
        "fetch",
        vi.fn(() => new Promise(() => {})),
      );
      renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
      await waitFor(() => expect(screen.getByTestId("page-energy-overview")).toBeTruthy());
      expect(screen.getByTestId("state-loading")).toBeTruthy();
      expect(screen.queryByTestId("energy-export-csv")).toBeNull();
    });

    it("exports one CSV row per chart point (>=3 distinct series values), in chart order, with the currently selected comparison basis repeated on every row", async () => {
      mockDownloadCsv.mockClear();
      let consumptionCalls = 0;
      stubFetch((url) => {
        if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse() };
        if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
        if (isConsumptionUrl(url)) {
          consumptionCalls += 1;
          // First call = current period (3 distinct chart points);
          // second = comparison (single point, never exported point-by-
          // point -- only its total should appear, as context).
          return { jsonBody: consumptionCalls === 1 ? energySeriesResponse(THREE_DISTINCT_POINTS) : energyResponse(100) };
        }
        return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
      });

      renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
      await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("60.0 kWh"));

      const user = userEvent.setup();
      await user.click(screen.getByTestId("energy-export-csv"));

      expect(mockDownloadCsv).toHaveBeenCalledTimes(1);
      const [filename, csv] = mockDownloadCsv.mock.calls[0] as [string, string];
      expect(filename).toMatch(/^energy-consumption-.*\.csv$/);

      const rows = csvDataRows(csv);
      expect(rows).toHaveLength(THREE_DISTINCT_POINTS.length);
      THREE_DISTINCT_POINTS.forEach((point, i) => {
        expect(csvCell(csv, "chart_timestamp", i)).toBe(point.bucket_start);
        expect(csvCell(csv, "energy_consumption_kwh", i)).toBe(point.import_kwh.toFixed(1));
        expect(csvCell(csv, "comparison_basis", i)).toBe("PREVIOUS_PERIOD");
        expect(csvCell(csv, "comparison_value_kwh", i)).toBe("100.0");
      });
    });

    it("preserves the currently selected comparison basis across every exported row after switching basis", async () => {
      mockDownloadCsv.mockClear();
      stubFetch((url) => {
        if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse() };
        if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
        if (isConsumptionUrl(url)) return { jsonBody: energySeriesResponse(THREE_DISTINCT_POINTS) };
        return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
      });

      renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
      await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("60.0 kWh"));

      const user = userEvent.setup();
      await user.click(screen.getByTestId("comparison-basis-SAME_PERIOD_PREVIOUSLY"));
      await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("60.0 kWh"));

      await user.click(screen.getByTestId("energy-export-csv"));

      expect(mockDownloadCsv).toHaveBeenCalledTimes(1);
      const [, csv] = mockDownloadCsv.mock.calls[0] as [string, string];
      const rows = csvDataRows(csv);
      expect(rows).toHaveLength(THREE_DISTINCT_POINTS.length);
      for (let i = 0; i < rows.length; i++) {
        expect(csvCell(csv, "comparison_basis", i)).toBe("SAME_PERIOD_PREVIOUSLY");
      }
    });

    it("current.no_data emits the header plus exactly one explicit no-data row -- never an empty file, never a fabricated value", async () => {
      mockDownloadCsv.mockClear();
      stubFetch((url) => {
        if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse() };
        if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse({}, true) };
        if (isConsumptionUrl(url)) return { jsonBody: energyResponse(0, true) };
        return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
      });

      renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
      await waitFor(() => expect(screen.getByTestId("energy-export-csv")).toBeTruthy());

      const user = userEvent.setup();
      await user.click(screen.getByTestId("energy-export-csv"));

      expect(mockDownloadCsv).toHaveBeenCalledTimes(1);
      const [, csv] = mockDownloadCsv.mock.calls[0] as [string, string];
      const rows = csvDataRows(csv);
      expect(rows).toHaveLength(1); // header + exactly one explicit no-data row
      expect(csvCell(csv, "chart_timestamp")).toBe("");
      expect(csvCell(csv, "energy_consumption_kwh")).toBe("");
      expect(csvCell(csv, "period_has_data")).toBe("false");
    });
  });
});
