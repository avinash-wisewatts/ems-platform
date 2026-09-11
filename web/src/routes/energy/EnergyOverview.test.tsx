import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { EnergyOverview } from "./EnergyOverview";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

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

describe("EnergyOverview (Slice A)", () => {
  it("composes Current Value -> Comparison -> Trend -> Status -> Data coverage from two unmodified consumption calls", async () => {
    let callCount = 0;
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption`)) {
        callCount += 1;
        // First call = current period (higher usage); second = comparison (lower).
        return { jsonBody: callCount === 1 ? energyResponse(120) : energyResponse(100) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(callCount).toBe(2));
    await waitFor(() => expect(screen.getByTestId("energy-current-value")).toHaveTextContent("120.0 kWh"));

    expect(screen.getByTestId("energy-comparison")).toHaveTextContent("100.0 kWh");
    expect(screen.getByTestId("energy-delta")).toHaveTextContent("+20.0 kWh");
    expect(screen.getByTestId("energy-delta")).toHaveTextContent("+20.0%");
    expect(screen.getByTestId("status-badge")).toHaveTextContent("Higher than comparison");
    expect(screen.getByTestId("chart-frame")).toBeTruthy();
    const coverage = screen.getByTestId("energy-data-coverage");
    expect(coverage).toHaveTextContent("Data coverage");
    expect(coverage).toHaveTextContent("4 source interval");
    // Not labelled as "Evidence" -- that element is explicitly deferred.
    expect(coverage).toHaveTextContent("not yet available");
    expect(screen.queryByText("Evidence")).toBeNull();
  });

  it("renders NoDataYet for the current period, never an error, when the range genuinely has no data", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption`)) {
        return { jsonBody: energyResponse(0, true) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getAllByTestId("state-no-data").length).toBeGreaterThan(0));
  });

  it("switching the comparison basis re-fetches with the new basis", async () => {
    let calls: string[] = [];
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption`)) {
        calls.push(url);
        return { jsonBody: energyResponse(100) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<EnergyOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(calls.length).toBe(2));

    calls = [];
    screen.getByTestId("comparison-basis-SAME_PERIOD_PREVIOUSLY").click();
    await waitFor(() => expect(calls.length).toBe(2));
  });
});
