import { describe, expect, it } from "vitest";
import { screen, waitFor, within } from "@testing-library/react";
import { MainDashboard } from "./MainDashboard";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

/**
 * Component-level tests for the Main Dashboard. Every section fetches from
 * an already-live /api/v1 endpoint (see MainDashboard.tsx's own header) --
 * these tests stub those HTTP responses and assert on what the page
 * renders, the same pattern EnergyOverview.test.tsx / SiteOverview tests
 * already use. Not wired into router.tsx/AppLayout.tsx in this change (see
 * PR notes) -- rendered directly, like every other route-level test file.
 */

function energyConsumption(totalKwh: number) {
  return {
    jsonBody: {
      site_id: "x",
      resolution: "1d",
      from: "",
      to: "",
      no_data: false,
      series: [{ bucket_start: "2026-09-01T00:00:00Z", import_kwh: totalKwh, export_kwh: 0, source_interval_count: 1 }],
    },
  };
}

const NO_DATA_ENERGY = {
  jsonBody: { site_id: "x", resolution: "1d", from: "", to: "", no_data: true, series: [] },
};

const INSUFFICIENT_TYPICAL_REFERENCE = {
  jsonBody: {
    site_id: "x",
    period_length_days: 7,
    from: "",
    to: "",
    typical_kwh: null,
    requested_period_count: 8,
    windows_with_data_count: 0,
    eligible_period_count: 0,
    sufficient: false,
    windows: [],
  },
};

const NO_DATA_EVIDENCE = {
  jsonBody: { site_id: "x", resolution: "1d", from: "", to: "", no_data: true, series: [] },
};

const CURRENT_DEMAND_WITH_DATA = {
  jsonBody: {
    site_id: "x",
    has_data: true,
    interval_start: "2026-09-16T12:00:00Z",
    interval_end: "2026-09-16T12:15:00Z",
    current_demand_kw: 42.3,
    current_demand_kva: 45.1,
    quality_status: "GOOD",
    coverage_percent: 100,
  },
};

function demandSeriesWithPeak(peakKw: number) {
  return {
    jsonBody: {
      site_id: "x",
      from: "",
      to: "",
      no_data: false,
      series: [
        {
          interval_start: "2026-09-16T08:00:00Z",
          interval_end: "2026-09-16T08:15:00Z",
          demand_kw: peakKw,
          peak_power_kw: peakKw,
          quality_status: "GOOD",
          coverage_percent: 100,
        },
      ],
    },
  };
}

const NO_DATA_DEMAND_SERIES = {
  jsonBody: { site_id: "x", from: "", to: "", no_data: true, series: [] },
};

const FRESHNESS_WITH_AS_OF = {
  jsonBody: {
    site_id: "x",
    energy: { state: "FRESH", as_of: "2026-09-16T12:30:00Z" },
    demand: { state: "FRESH", as_of: "2026-09-16T12:45:00Z" },
    power_quality: { state: "FRESH", as_of: "2026-09-16T12:00:00Z" },
  },
};

const FRESHNESS_UNKNOWN = {
  jsonBody: {
    site_id: "x",
    energy: { state: "UNKNOWN", as_of: null },
    demand: { state: "UNKNOWN", as_of: null },
    power_quality: { state: "UNKNOWN", as_of: null },
  },
};

/** A fully-populated stub: real YTD/MTD totals, a real demand peak, and a
 *  deliberately-insufficient typical-reference so Site Health resolves
 *  deterministically to "not available" without depending on the Energy
 *  Attention materiality threshold's exact internals. */
function stubDashboardWithData() {
  return stubFetch((url) => {
    if (url.includes("/energy/consumption/evidence")) return NO_DATA_EVIDENCE;
    if (url.includes("/energy/consumption/typical-reference")) return INSUFFICIENT_TYPICAL_REFERENCE;
    if (url.includes("/energy/consumption")) return energyConsumption(1234);
    if (url.includes("/demand/current")) return CURRENT_DEMAND_WITH_DATA;
    if (url.includes("/demand")) return demandSeriesWithPeak(78.5);
    if (url.includes("/telemetry-freshness")) return FRESHNESS_WITH_AS_OF;
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("MainDashboard", () => {
  it("renders YTD/MTD energy, demand values, and the last-updated timestamp for a site with data", async () => {
    stubDashboardWithData();
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument());

    const ytd = screen.getByTestId("kpi-energy-ytd");
    await waitFor(() => expect(within(ytd).getByText("1,234")).toBeInTheDocument());

    const mtd = screen.getByTestId("kpi-energy-mtd");
    await waitFor(() => expect(within(mtd).getByText("1,234")).toBeInTheDocument());

    const demand = screen.getByTestId("kpi-demand");
    await waitFor(() => expect(within(demand).getByText("42.3 kW")).toBeInTheDocument());
    // Peak (Today) and Max (This Month) both read the same stubbed series in
    // this test, so 78.5 kW legitimately appears twice.
    expect(within(demand).getAllByText("78.5 kW")).toHaveLength(2);

    await waitFor(() =>
      expect(screen.getByTestId("dashboard-last-update")).toHaveTextContent("Last data update:"),
    );
    // The freshest as_of across energy/demand/power_quality is demand's 12:45.
    expect(screen.getByTestId("dashboard-last-update")).not.toHaveTextContent("not available");

    // Site Health: typical-reference is insufficient (sufficient: false), so
    // energyAssessable is false and it resolves deterministically to
    // INSUFFICIENT_DATA rather than depending on the Energy Attention
    // threshold's exact numbers.
    await waitFor(() =>
      expect(screen.getByTestId("dashboard-site-health")).toHaveTextContent("Insufficient Data"),
    );
    expect(screen.getByTestId("dashboard-site-health")).toHaveAttribute("data-state", "INSUFFICIENT_DATA");

    // Load Trend chart renders (not a "no data" placeholder) once its own
    // demand series resolves.
    await waitFor(() => expect(screen.getByTestId("chart-frame")).toBeInTheDocument());
  });

  it("always shows Live Electrical Parameters as 'Not available yet', even when every other section has real data", async () => {
    stubDashboardWithData();
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument());

    const liveParams = screen.getByTestId("live-electrical-parameters");
    expect(within(liveParams).getByText("Voltage")).toBeInTheDocument();
    expect(within(liveParams).getByText("Current")).toBeInTheDocument();
    expect(within(liveParams).getByText("Power Factor")).toBeInTheDocument();
    expect(within(liveParams).getByText("Frequency")).toBeInTheDocument();
    expect(within(liveParams).getAllByText("Not available yet")).toHaveLength(4);
  });

  it("shows an honest 'no data' state per card, not a fabricated value, when a site has no energy/demand/freshness data yet", async () => {
    stubFetch((url) => {
      if (url.includes("/energy/consumption/evidence")) return NO_DATA_EVIDENCE;
      if (url.includes("/energy/consumption/typical-reference")) return INSUFFICIENT_TYPICAL_REFERENCE;
      if (url.includes("/energy/consumption")) return NO_DATA_ENERGY;
      if (url.includes("/demand/current")) return { jsonBody: { site_id: "x", has_data: false, interval_start: null, interval_end: null, current_demand_kw: null, current_demand_kva: null, quality_status: null, coverage_percent: null } };
      if (url.includes("/demand")) return NO_DATA_DEMAND_SERIES;
      if (url.includes("/telemetry-freshness")) return FRESHNESS_UNKNOWN;
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument());

    await waitFor(() =>
      expect(screen.getByTestId("kpi-energy-ytd")).toHaveTextContent("No data for the selected range."),
    );
    expect(screen.getByTestId("kpi-energy-mtd")).toHaveTextContent("No data for the selected range.");

    const demand = screen.getByTestId("kpi-demand");
    await waitFor(() => expect(within(demand).getAllByText("No data available").length).toBeGreaterThan(0));

    await waitFor(() =>
      expect(screen.getByTestId("dashboard-last-update")).toHaveTextContent("not available"),
    );
  });

  it("shows an empty state with no fabricated dashboard when the user has no accessible sites", async () => {
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve({ sites: [] }) });

    await waitFor(() => expect(screen.getByText("No site selected")).toBeInTheDocument());
    expect(screen.queryByTestId("page-main-dashboard")).not.toBeInTheDocument();
  });

  it("one card's failure (Demand) does not block the YTD/MTD cards from rendering their own data", async () => {
    stubFetch((url) => {
      if (url.includes("/energy/consumption/evidence")) return NO_DATA_EVIDENCE;
      if (url.includes("/energy/consumption/typical-reference")) return INSUFFICIENT_TYPICAL_REFERENCE;
      if (url.includes("/energy/consumption")) return energyConsumption(500);
      if (url.includes("/demand/current")) return { status: 500, jsonBody: { error: "internal_error", detail: "boom" } };
      if (url.includes("/demand")) return { status: 500, jsonBody: { error: "internal_error", detail: "boom" } };
      if (url.includes("/telemetry-freshness")) return FRESHNESS_WITH_AS_OF;
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<MainDashboard />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument());

    const ytd = screen.getByTestId("kpi-energy-ytd");
    await waitFor(() => expect(within(ytd).getByText("500")).toBeInTheDocument());

    await waitFor(() => expect(screen.getByTestId("kpi-demand")).toHaveTextContent(/Try again|Retry/i));
  });
});
