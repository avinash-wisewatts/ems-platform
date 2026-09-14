import { describe, expect, it, vi } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SitePerformanceReportView } from "./SitePerformanceReportView";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type { ReportConfig } from "../../reports/sitePerformanceReport";
import type * as PdfModule from "../../reports/pdf";

// jsPDF's `save()` is an own instance method (not on .prototype, so it
// can't be spied on directly) that falls back to a real filesystem write
// outside a browser -- e.g. under Vitest/jsdom. Mocking the report's own
// pdf.ts module keeps these component tests free of that real side effect
// while still proving the click path and error handling are wired
// correctly; buildSitePerformanceReportPdf itself (including jsPDF) is
// exercised for real in pdf.test.ts.
const mockSave = vi.fn();
let pdfShouldFail = false;
vi.mock("../../reports/pdf", async () => {
  const actual = await vi.importActual<typeof PdfModule>("../../reports/pdf");
  return {
    ...actual,
    buildSitePerformanceReportPdf: vi.fn(() => {
      if (pdfShouldFail) throw new Error("simulated PDF failure");
      return { save: mockSave };
    }),
  };
});

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function siteConfig(overrides: Partial<ReportConfig> = {}): ReportConfig {
  return {
    siteId: SITE_ID,
    siteName: "Radisson Blu",
    hierarchyLevel: "SITE",
    contextName: "Radisson Blu",
    investigatePath: "/features/spaces",
    period: "WEEKLY",
    // Exactly 7 whole days -- satisfies the typical-reference endpoint's
    // whole-day constraint, so Site Health/Attention are assessable here.
    range: { from: "2026-09-01T00:00:00.000Z", to: "2026-09-08T00:00:00.000Z" },
    ...overrides,
  };
}

function energyResponse(kwh: number, noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-09-01T00:00:00.000Z",
    to: "2026-09-08T00:00:00.000Z",
    no_data: noData,
    series: noData
      ? []
      : [{ bucket_start: "2026-09-01T00:00:00.000Z", import_kwh: kwh, export_kwh: 0, source_interval_count: 4 }],
  };
}

function typicalReferenceWindow(index: number) {
  return {
    window_index: index,
    from: "2026-08-01T00:00:00.000Z",
    to: "2026-08-08T00:00:00.000Z",
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
  };
}

function typicalReferenceResponse(typicalKwh: number) {
  return {
    site_id: SITE_ID,
    period_length_days: 7,
    from: "2026-09-01T00:00:00.000Z",
    to: "2026-09-08T00:00:00.000Z",
    typical_kwh: typicalKwh,
    requested_period_count: 8,
    windows_with_data_count: 8,
    eligible_period_count: 8,
    sufficient: true,
    windows: Array.from({ length: 8 }, (_, i) => typicalReferenceWindow(i + 1)),
  };
}

function evidenceResponse() {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-09-01T00:00:00.000Z",
    to: "2026-09-08T00:00:00.000Z",
    no_data: false,
    series: [
      {
        bucket_start: "2026-09-01T00:00:00.000Z",
        source_interval_count: 4,
        valid_import_intervals: 4,
        invalid_import_intervals: 0,
        valid_export_intervals: 4,
        invalid_export_intervals: 0,
        gap_interval_count: 0,
        reset_interval_count: 0,
        rollover_interval_count: 0,
        invalid_interval_count: 0,
        first_source_bucket: "2026-09-01T00:00:00.000Z",
        last_source_bucket: "2026-09-07T23:00:00.000Z",
      },
    ],
  };
}

function demandSeriesResponse() {
  return {
    site_id: SITE_ID,
    from: "2026-09-01T00:00:00.000Z",
    to: "2026-09-08T00:00:00.000Z",
    no_data: false,
    series: [
      {
        interval_start: "2026-09-03T00:00:00.000Z",
        interval_end: "2026-09-03T00:15:00.000Z",
        demand_kw: 55,
        peak_power_kw: 70,
        quality_status: "VALID",
        coverage_percent: 100,
      },
    ],
  };
}

function pqResponse() {
  return {
    site_id: SITE_ID,
    resolution: "1d",
    from: "2026-09-01T00:00:00.000Z",
    to: "2026-09-08T00:00:00.000Z",
    no_data: false,
    series: [
      {
        bucket_start: "2026-09-07T00:00:00.000Z",
        power_factor_avg: 0.94,
        current_thd_l1_avg: 3.1,
        current_thd_l2_avg: 3.2,
        current_thd_l3_avg: 3.0,
      },
    ],
  };
}

function stubAllReady() {
  stubFetch((url) => {
    if (url.includes("/energy/consumption/typical-reference")) return { jsonBody: typicalReferenceResponse(100) };
    if (url.includes("/energy/consumption/evidence")) return { jsonBody: evidenceResponse() };
    if (url.includes("/energy/consumption")) return { jsonBody: energyResponse(105) };
    if (url.includes("/demand")) return { jsonBody: demandSeriesResponse() };
    if (url.includes("/power-quality")) return { jsonBody: pqResponse() };
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("SitePerformanceReportView (EMS-REQ-112/113)", () => {
  it("renders the title as 'Performance Report — [context name]' and the six-section structure", async () => {
    stubAllReady();
    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={vi.fn()} onGenerateAnother={vi.fn()} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    expect(screen.getByTestId("report-title")).toHaveTextContent("Performance Report — Radisson Blu");
    await waitFor(() => expect(screen.getByTestId("site-health-banner")).toBeInTheDocument());
    expect(screen.getByTestId("report-attention")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByTestId("report-energy-value")).toHaveTextContent("105.0 kWh"));
    expect(screen.getByTestId("report-energy-value")).toHaveTextContent("+5.0% vs. typical");
    await waitFor(() => expect(screen.getByTestId("report-demand-value")).toHaveTextContent("70.0 kW"));
    await waitFor(() => expect(screen.getByTestId("report-pq-value")).toHaveTextContent("PF 0.94"));
    expect(screen.getByTestId("report-investigate")).toBeInTheDocument();
  });

  it("preserves per-domain Data unavailable states and keeps reporting the other usable domains", async () => {
    stubFetch((url) => {
      if (url.includes("/energy/consumption/typical-reference")) return { jsonBody: typicalReferenceResponse(100) };
      if (url.includes("/energy/consumption/evidence")) return { jsonBody: evidenceResponse() };
      if (url.includes("/energy/consumption")) return { jsonBody: energyResponse(0, true) }; // Energy: no_data
      if (url.includes("/demand")) return { jsonBody: demandSeriesResponse() };
      if (url.includes("/power-quality")) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={vi.fn()} onGenerateAnother={vi.fn()} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    await waitFor(() => expect(screen.getByTestId("report-demand-value")).toHaveTextContent("70.0 kW"));
    // Energy has no data, but Demand and Power Quality still render.
    expect(screen.getByTestId("report-energy")).toHaveTextContent(/no data/i);
    expect(screen.getByTestId("report-pq-value")).toBeInTheDocument();
  });

  it("shows Site Health/Attention as unavailable for a non-whole-day period, without failing the rest of the report (ADR-015 gap resolution 6)", async () => {
    stubFetch((url) => {
      if (url.includes("/energy/consumption/evidence")) return { jsonBody: evidenceResponse() };
      if (url.includes("/energy/consumption")) return { jsonBody: energyResponse(50) };
      if (url.includes("/demand")) return { jsonBody: demandSeriesResponse() };
      if (url.includes("/power-quality")) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    const config = siteConfig({
      period: "MONTHLY",
      range: { from: "2026-09-01T00:00:00.000Z", to: "2026-09-16T10:00:00.000Z" }, // not a whole day
    });
    renderWithProviders(<SitePerformanceReportView config={config} onChange={vi.fn()} onGenerateAnother={vi.fn()} />, {
      sites: () => Promise.resolve(SITES_ONE),
    });

    await waitFor(() => expect(screen.getByTestId("state-no-data")).toBeInTheDocument());
    expect(screen.queryByTestId("site-health-banner")).toBeNull();
    // Energy's own current value is still available (no whole-day constraint on it).
    await waitFor(() => expect(screen.getByTestId("report-energy-value")).toHaveTextContent("50.0 kWh"));
  });

  it("shows a clear error with retry when a domain fetch fails, and recovers on retry", async () => {
    let demandCalls = 0;
    stubFetch((url) => {
      if (url.includes("/energy/consumption/typical-reference")) return { jsonBody: typicalReferenceResponse(100) };
      if (url.includes("/energy/consumption/evidence")) return { jsonBody: evidenceResponse() };
      if (url.includes("/energy/consumption")) return { jsonBody: energyResponse(105) };
      if (url.includes("/demand")) {
        demandCalls += 1;
        if (demandCalls === 1) return { status: 500, jsonBody: { error: "server_error" } };
        return { jsonBody: demandSeriesResponse() };
      }
      if (url.includes("/power-quality")) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    const user = userEvent.setup();
    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={vi.fn()} onGenerateAnother={vi.fn()} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    await waitFor(() => expect(screen.getByTestId("report-demand")).toHaveTextContent(/something went wrong/i));
    await user.click(screen.getByRole("button", { name: /try again/i }));
    await waitFor(() => expect(screen.getByTestId("report-demand-value")).toHaveTextContent("70.0 kW"));
  });

  it("Change and Generate another report call their respective callbacks", async () => {
    stubAllReady();
    const onChange = vi.fn();
    const onGenerateAnother = vi.fn();
    const user = userEvent.setup();
    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={onChange} onGenerateAnother={onGenerateAnother} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    await user.click(screen.getByTestId("report-change"));
    expect(onChange).toHaveBeenCalledTimes(1);
    await user.click(screen.getByTestId("report-generate-another"));
    expect(onGenerateAnother).toHaveBeenCalledTimes(1);
  });

  it("Download PDF triggers generation and leaves the report intact", async () => {
    stubAllReady();
    pdfShouldFail = false;
    mockSave.mockClear();
    const user = userEvent.setup();
    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={vi.fn()} onGenerateAnother={vi.fn()} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    await waitFor(() => expect(screen.getByTestId("report-energy-value")).toBeInTheDocument());
    await user.click(screen.getByTestId("report-download-pdf"));

    expect(mockSave).toHaveBeenCalledTimes(1);
    // The in-app report is still present after a PDF attempt.
    expect(screen.getByTestId("report-title")).toBeInTheDocument();
    expect(screen.getByTestId("report-energy-value")).toBeInTheDocument();
  });

  it("a PDF generation failure shows a clear error and never removes the already-rendered report (EMS-REQ-116)", async () => {
    stubAllReady();
    pdfShouldFail = true;
    const user = userEvent.setup();
    renderWithProviders(
      <SitePerformanceReportView config={siteConfig()} onChange={vi.fn()} onGenerateAnother={vi.fn()} />,
      { sites: () => Promise.resolve(SITES_ONE) },
    );

    await waitFor(() => expect(screen.getByTestId("report-energy-value")).toBeInTheDocument());
    await user.click(screen.getByTestId("report-download-pdf"));

    await waitFor(() => expect(screen.getByText(/couldn't generate the pdf/i)).toBeInTheDocument());
    // The in-app report is unaffected by the PDF failure.
    expect(screen.getByTestId("report-title")).toBeInTheDocument();
    expect(screen.getByTestId("report-energy-value")).toBeInTheDocument();
    pdfShouldFail = false;
  });
});
