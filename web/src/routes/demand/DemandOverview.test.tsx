import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { DemandOverview, findPeak } from "./DemandOverview";
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
 * MVP-5 fixture-correctness fix: `analytics.demand_state` -- the table this
 * endpoint reads -- always computes `calculate_demand_window(..., p_final =
 * FALSE)`, which can never resolve to `VALID` (that value only exists on
 * the finalized, interval-level `analytics.demand_intervals` path). The
 * realistic "has a current reading, still live" value is `PROVISIONAL`,
 * matching the backend's own test suite
 * (app/tests/test_analytics_api_v1_demand_routes.py::test_current_demand_returns_the_live_reading).
 * Default here corrected accordingly; callers needing a different one of
 * the four real quality_status values pass it explicitly.
 */
function currentDemandResponse(hasData: boolean, kw = 60.5, qualityStatus = "PROVISIONAL") {
  return hasData
    ? {
        site_id: SITE_ID,
        has_data: true,
        interval_start: "2026-09-08T11:15:00Z",
        interval_end: "2026-09-08T11:30:00Z",
        current_demand_kw: kw,
        current_demand_kva: kw + 2,
        quality_status: qualityStatus,
        coverage_percent: 96,
      }
    : {
        site_id: SITE_ID,
        has_data: false,
        interval_start: null,
        interval_end: null,
        current_demand_kw: null,
        current_demand_kva: null,
        quality_status: null,
        coverage_percent: null,
      };
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

function stubDemand(qualityStatus: string, opts: { hasData?: boolean; freshness?: string } = {}) {
  const hasData = opts.hasData ?? true;
  stubFetch((url) => {
    if (url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`)) {
      return { jsonBody: freshnessResponse(opts.freshness ?? "FRESH") };
    }
    if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
      return { jsonBody: currentDemandResponse(hasData, 60.5, qualityStatus) };
    }
    if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
      return { jsonBody: seriesResponse() };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("DemandOverview (Slice B)", () => {
  it("composes Current Value -> Peak -> Trend -> Status -> Data quality from the two verified endpoints", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
        return { jsonBody: currentDemandResponse(true) };
      }
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
        return { jsonBody: seriesResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-current")).toHaveTextContent("60.5"));
    expect(screen.getByTestId("demand-current-value")).toHaveTextContent("Current Demand (kW)");
    // Peak Power uses peak_power_kw (70.0, the second interval) -- never
    // demand_kw, and never labelled "Demand".
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("Peak Power");
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("70.0 kW");
    // 2026-09-02T00:00:00Z is 05:30 the same day in Asia/Kolkata.
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("05:30, 02 Sep");
    expect(screen.getByTestId("chart-frame")).toBeTruthy();
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Calculating");
    expect(screen.getByTestId("demand-evidence")).toHaveTextContent("96%");
    // Never a StatusBadge here -- no comparison exists for Demand.
    expect(screen.queryByTestId("status-badge")).toBeNull();
  });

  it("renders NoDataYet for current value when has_data is false, never an error", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
        return { jsonBody: currentDemandResponse(false) };
      }
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
        return { jsonBody: seriesResponse(true) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getAllByTestId("state-no-data").length).toBeGreaterThan(0));
  });

  it("does not display any contract-demand, target, or utilization figure", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
        return { jsonBody: currentDemandResponse(true) };
      }
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
        return { jsonBody: seriesResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-current-value")).toBeTruthy());
    expect(screen.queryByText(/contract/i)).toBeNull();
    expect(screen.queryByText(/utilization/i)).toBeNull();
    expect(screen.queryByText(/target/i)).toBeNull();
  });

  it("MVP-4: shows device freshness next to, not merged into, the Status (quality_status) label", async () => {
    stubDemand("PROVISIONAL", { freshness: "STALE" });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-freshness")).toHaveTextContent("Outdated"));
    // The Status paragraph is a distinct signal, not merged with freshness.
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Calculating");
  });

  it("MVP-4: a freshness fetch failure is non-blocking -- Current/Peak/Trend/Status still render", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`)) {
        return { status: 500, jsonBody: { error: "server_error" } };
      }
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
        return { jsonBody: currentDemandResponse(true) };
      }
      if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
        return { jsonBody: seriesResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("demand-current")).toHaveTextContent("60.5"));
    expect(screen.getByTestId("demand-status")).toHaveTextContent("Calculating");
    expect(screen.queryByTestId("freshness-indicator")).toBeNull();
  });

  describe("MVP-5: Demand Status customer labels", () => {
    it.each([
      ["PROVISIONAL", "Calculating"],
      ["NO_DATA", "Data unavailable"],
      ["INVALID_SOURCE", "Data unavailable"],
      ["INSUFFICIENT_SOURCE_RESOLUTION", "Data unavailable"],
    ])("%s -> %s", async (qualityStatus, label) => {
      stubDemand(qualityStatus);
      renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByTestId("demand-status")).toHaveTextContent(label));
      // The raw technical value is never leaked into the visible label text.
      expect(screen.getByTestId("demand-status").textContent).not.toContain(qualityStatus);
    });

    it("no current-demand row at all (has_data: false) also reads 'Data unavailable', per Product decision", async () => {
      stubFetch((url) => {
        if (url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`)) {
          return { jsonBody: freshnessResponse() };
        }
        if (url.includes(`/api/v1/sites/${SITE_ID}/demand/current`)) {
          return { jsonBody: currentDemandResponse(false) };
        }
        if (url.includes(`/api/v1/sites/${SITE_ID}/demand`)) {
          return { jsonBody: seriesResponse() };
        }
        return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
      });

      renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByTestId("demand-status")).toHaveTextContent("Data unavailable"));
      expect(screen.getByTestId("demand-status")).not.toHaveTextContent("Unknown");
    });

    it("pairs the Status label with an accessible info explanation", async () => {
      stubDemand("PROVISIONAL");
      renderWithProviders(<DemandOverview />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByTestId("demand-status")).toHaveTextContent("Calculating"));
      expect(screen.getByTestId("demand-status-info")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: 'What does "Calculating" mean?' })).toBeInTheDocument();
      expect(screen.getByTestId("demand-status-explanation")).toHaveTextContent(
        "This Demand value is still being calculated and hasn't been finalized yet.",
      );
    });
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
