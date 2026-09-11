import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { DemandOverview } from "./DemandOverview";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function currentDemandResponse(hasData: boolean, kw = 60.5) {
  return hasData
    ? {
        site_id: SITE_ID,
        has_data: true,
        interval_start: "2026-09-08T11:15:00Z",
        interval_end: "2026-09-08T11:30:00Z",
        current_demand_kw: kw,
        current_demand_kva: kw + 2,
        quality_status: "VALID",
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
            quality_status: "GOOD",
            coverage_percent: 90,
          },
        ],
  };
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

    await waitFor(() => expect(screen.getByTestId("demand-current-value")).toHaveTextContent("60.5 kW"));
    expect(screen.getByTestId("demand-peak")).toHaveTextContent("70.0 kW");
    expect(screen.getByTestId("chart-frame")).toBeTruthy();
    expect(screen.getByTestId("demand-status")).toHaveTextContent("VALID");
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
});
