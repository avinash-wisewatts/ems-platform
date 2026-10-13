import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { DemandOverview, findPeak, toChartPoints } from "./DemandOverview";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type { DemandIntervalPoint } from "../../api/types";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
// SITES_ONE (test-utils.tsx) is Alpha One / Org A, timezone Asia/Kolkata
// (UTC+5:30).

function demandInterval(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return {
    interval_start: "2026-09-17T09:00:00Z",
    interval_end: "2026-09-17T09:15:00Z",
    demand_kw: 50,
    peak_power_kw: null,
    quality_status: "VALID",
    coverage_percent: 100,
    ...overrides,
  };
}

/**
 * GET .../demand/current. T1.3a (revised run 11): the screen renders only
 * last_completed_interval. The provisional current fields are still in the
 * API response (guarded server-side) and the fixtures below deliberately
 * include one (60.5 kW, PROVISIONAL, [11:15, 11:30) UTC) to prove the
 * screen never displays it.
 */
function currentDemandResponse(
  lastCompleted: DemandIntervalPoint | null,
  opts: { provisional?: boolean } = {},
) {
  const provisional = opts.provisional ?? true;
  return {
    site_id: SITE_ID,
    has_data: provisional,
    current_status: provisional ? "CURRENT" : lastCompleted ? "STALE" : "MISSING",
    evaluated_at: "2026-09-08T11:20:00Z",
    interval_start: provisional ? "2026-09-08T11:15:00Z" : null,
    interval_end: provisional ? "2026-09-08T11:30:00Z" : null,
    current_demand_kw: provisional ? 60.5 : null,
    current_demand_kva: provisional ? 62.5 : null,
    quality_status: provisional ? "PROVISIONAL" : null,
    coverage_percent: provisional ? 33 : null,
    last_completed_interval: lastCompleted,
  };
}

/** [16:30, 16:45) IST on 08 Sep, VALID, 52.4 kW. */
function lastCompletedInterval(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return demandInterval({
    interval_start: "2026-09-08T11:00:00Z",
    interval_end: "2026-09-08T11:15:00Z",
    demand_kw: 52.4,
    peak_power_kw: 58.1,
    quality_status: "VALID",
    coverage_percent: 100,
    ...overrides,
  });
}

function seriesResponse(noData = false) {
  return {
    site_id: SITE_ID,
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-08T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [
          {
            interval_start: "2026-09-01T00:00:00Z",
            interval_end: "2026-09-01T00:15:00Z",
            demand_kw: 40.0,
            peak_power_kw: 45.0,
            quality_status: "VALID",
            coverage_percent: 100,
          },
          {
            interval_start: "2026-09-02T00:00:00Z",
            interval_end: "2026-09-02T00:15:00Z",
            demand_kw: 55.0,
            peak_power_kw: 70.0,
            quality_status: "VALID",
            coverage_percent: 90,
          },
        ],
  };
}

function freshnessResponse(state = "FRESH") {
  return {
    site_id: SITE_ID,
    energy: { state: "FRESH", as_of: "2026-09-13T09:58:00Z" },
    demand: { state, as_of: "2026-09-13T09:58:00Z" },
    power_quality: { state: "FRESH", as_of: "2026-09-13T09:58:00Z" },
  };
}

function stubDemand(
  lastCompleted: DemandIntervalPoint | null,
  opts: { freshness?: string | "fail"; noSeries?: boolean; provisional?: boolean } = {},
) {
  stubFetch((url) => {
    if (url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`)) {
      return opts.freshness === "fail"
        ? { status: 500, jsonBody: { error: "server_error" } }
        : { jsonBody: freshnessResponse(opts.freshness ?? "FRESH") };
    }
    if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
      return { jsonBody: currentDemandResponse(lastCompleted, { provisional: opts.provisional }) };
    }
    if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
      return { jsonBody: seriesResponse(opts.noSeries) };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("DemandOverview (Slice B)", () => {
  it("composes Last Completed -> Peak -> Trend -> Status -> Data quality from the two verified endpoints", async () => {
    stubDemand(lastCompletedInterval());

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("52.4"));
    expect(screen.getByTestId("demand-current-value")).toHaveTextContent("Last Completed Demand (kW)");
    // 11:00-11:15 UTC is 16:30-16:45 IST: the interval's own site-local time.
    expect(screen.getByTestId("demand-last-completed-interval")).toHaveTextContent(
      "Last completed 15-min interval 16:30–16:45, 08 Sep",
    );
    expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Complete data");
    // Peak Power uses peak_power_kw (70.0, the second interval) -- never
    // demand_kw, and never labelled "Demand".
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("Peak Power");
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("70.0 kW");
    // 2026-09-02T00:00:00Z is 05:30 the same day in Asia/Kolkata.
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("05:30, 02 Sep");
    expect(screen.getByTestId("chart-frame")).toBeTruthy();
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Complete data");
    expect(screen.getByTestId("demand-coverage")).toHaveTextContent("Coverage of the last completed interval: 100%");
    // Never a StatusBadge here -- no comparison exists for Demand.
    expect(screen.queryByTestId("status-badge")).toBeNull();
  });

  it("T1.3a: never displays the provisional current-interval value the API still returns", async () => {
    stubDemand(lastCompletedInterval());

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("52.4"));
    const page = screen.getByTestId("page-demand-overview");
    expect(page).not.toHaveTextContent("60.5");
    expect(page).not.toHaveTextContent("33%");
    expect(page).not.toHaveTextContent(/current demand|provisional|calculating|in progress/i);
  });

  it("T1.3a: an INCOMPLETE last interval shows its time and status, but its value is not presented as demand", async () => {
    stubDemand(lastCompletedInterval({ demand_kw: 31.7, quality_status: "INCOMPLETE", coverage_percent: 74 }));

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Incomplete data (74% coverage)"),
    );
    expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("—");
    expect(screen.getByTestId("page-demand-overview")).not.toHaveTextContent("31.7");
    expect(screen.getByTestId("demand-last-completed-interval")).toHaveTextContent("16:30–16:45, 08 Sep");
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Incomplete data");
    expect(screen.getByTestId("demand-coverage")).toHaveTextContent("74%");
    // Peak Power stays visible.
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("70.0 kW");
  });

  it("T1.3a: an unavailable last interval reads 'Data unavailable' with no value", async () => {
    stubDemand(lastCompletedInterval({ demand_kw: null, quality_status: "NO_DATA", coverage_percent: 0 }));

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("demand-last-completed-status")).toHaveTextContent("Data unavailable"),
    );
    expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("—");
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Data unavailable");
  });

  it("T1.3a: dates the last interval of a site-local day by that day (IST midnight boundary)", async () => {
    // [18:15, 18:30) UTC on 12 Oct = [23:45, 00:00) IST.
    stubDemand(
      lastCompletedInterval({ interval_start: "2026-10-12T18:15:00Z", interval_end: "2026-10-12T18:30:00Z" }),
    );

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("demand-last-completed-interval")).toHaveTextContent(
        "Last completed 15-min interval 23:45–00:00, 12 Oct",
      ),
    );
  });

  it("says so when there is no completed interval, never an error", async () => {
    stubDemand(null, { provisional: false, noSeries: true });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("demand-last-completed-none")).toHaveTextContent(
        "No completed demand interval in the last 7 days.",
      ),
    );
    expect(screen.queryByTestId("demand-last-completed-value")).toBeNull();
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Data unavailable");
    expect(screen.getByTestId("demand-status")).not.toHaveTextContent("Unknown");
    expect(screen.getByTestId("demand-evidence")).toHaveTextContent("No coverage information available yet.");
    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("does not display any contract-demand, target, or utilization figure", async () => {
    stubDemand(lastCompletedInterval());

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-current-value")).toBeTruthy());
    expect(screen.queryByText(/contract/i)).toBeNull();
    expect(screen.queryByText(/utilization/i)).toBeNull();
    expect(screen.queryByText(/target/i)).toBeNull();
  });

  it("MVP-4: shows device freshness next to, not merged into, the Status (quality_status) label", async () => {
    stubDemand(lastCompletedInterval(), { freshness: "STALE" });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-freshness")).toHaveTextContent("Outdated"));
    // The Status paragraph is a distinct signal, not merged with freshness.
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Complete data");
  });

  it("MVP-4: a freshness fetch failure is non-blocking -- Last Completed/Peak/Trend/Status still render", async () => {
    stubDemand(lastCompletedInterval(), { freshness: "fail" });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-last-completed-value")).toHaveTextContent("52.4"));
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Complete data");
    expect(screen.queryByTestId("freshness-indicator")).toBeNull();
  });

  describe("MVP-5: Demand Status customer labels (last completed interval)", () => {
    it.each([
      ["VALID", "Complete data"],
      ["INCOMPLETE", "Incomplete data"],
      ["NO_DATA", "Data unavailable"],
      ["INVALID_SOURCE", "Data unavailable"],
      ["SOURCE_BOUNDARY", "Data unavailable"],
      ["INSUFFICIENT_SOURCE_RESOLUTION", "Data unavailable"],
    ])("%s -> %s", async (qualityStatus, label) => {
      stubDemand(lastCompletedInterval({ quality_status: qualityStatus }));
      renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByTestId("demand-status")).toHaveTextContent(label));
      // The raw technical value is never leaked into the visible label text.
      expect(screen.getByTestId("demand-status").textContent).not.toContain(qualityStatus);
    });

    it("pairs the Status label with an accessible info explanation", async () => {
      stubDemand(lastCompletedInterval({ quality_status: "INCOMPLETE", coverage_percent: 60 }));
      renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByTestId("demand-status")).toHaveTextContent("Incomplete data"));
      expect(screen.getByTestId("demand-status-info")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: 'What does "Incomplete data" mean?' })).toBeInTheDocument();
      expect(screen.getByTestId("demand-status-explanation")).toHaveTextContent(
        "Some meter readings for this interval are missing, so its demand value is not reliable and is not shown.",
      );
    });
  });
});

describe("toChartPoints (T1.3a)", () => {
  it("charts VALID intervals and leaves a gap for any other status", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-17T09:00:00Z", demand_kw: 50 }),
      demandInterval({ interval_start: "2026-09-17T09:15:00Z", demand_kw: 31.7, quality_status: "INCOMPLETE" }),
      demandInterval({ interval_start: "2026-09-17T09:30:00Z", demand_kw: null, quality_status: "NO_DATA" }),
    ];
    expect(toChartPoints(series)).toEqual([
      { t: Date.parse("2026-09-17T09:00:00Z"), value: 50 },
      { t: Date.parse("2026-09-17T09:15:00Z"), value: null },
      { t: Date.parse("2026-09-17T09:30:00Z"), value: null },
    ]);
  });
});

describe("findPeak", () => {
  it("finds the interval with the highest peak_power_kw, not demand_kw", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-17T09:00:00Z", demand_kw: 88.2, peak_power_kw: 90 }),
      demandInterval({ interval_start: "2026-09-17T09:15:00Z", demand_kw: 40, peak_power_kw: 200 }),
      demandInterval({ interval_start: "2026-09-17T09:30:00Z", demand_kw: 20, peak_power_kw: null }),
    ];
    // The highest demand_kw (88.2) is in the FIRST interval, but the
    // highest peak_power_kw (200) is in the SECOND -- findPeak must report
    // the second interval, proving it uses peak_power_kw.
    expect(findPeak(series)).toEqual({ kw: 200, at: "2026-09-17T09:15:00Z" });
  });

  it("skips intervals with a null peak_power_kw rather than treating them as zero", () => {
    const series = [
      demandInterval({ interval_start: "2026-09-17T09:00:00Z", peak_power_kw: null }),
      demandInterval({ interval_start: "2026-09-17T09:15:00Z", peak_power_kw: 30 }),
    ];
    expect(findPeak(series)).toEqual({ kw: 30, at: "2026-09-17T09:15:00Z" });
  });

  it("returns null for an empty series, or when every peak_power_kw is null (e.g. METER_NATIVE source)", () => {
    expect(findPeak([])).toBeNull();
    expect(findPeak([demandInterval({ peak_power_kw: null })])).toBeNull();
  });
});
