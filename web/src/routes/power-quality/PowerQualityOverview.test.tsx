import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { PowerQualityOverview } from "./PowerQualityOverview";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function pqResponse(noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "15min",
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-02T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [
          {
            bucket_start: "2026-09-01T00:00:00Z",
            power_factor_avg: 0.94,
            power_factor_min: 0.9,
            power_factor_max: 0.98,
            current_thd_l1_avg: 4.2,
            current_thd_l1_max: 5.1,
            current_thd_l2_avg: 4.0,
            current_thd_l2_max: 4.9,
            current_thd_l3_avg: 4.4,
            current_thd_l3_max: 5.3,
          },
        ],
  };
}

describe("PowerQualityOverview (Slice B)", () => {
  it("composes PF Current -> PF Trend -> per-phase THD Current -> Data quality note from the verified endpoint", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/power-quality`)) {
        return { jsonBody: pqResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<PowerQualityOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("pq-current-pf")).toHaveTextContent("0.94"));
    expect(screen.getByTestId("chart-frame")).toBeTruthy();
    expect(screen.getByTestId("pq-thd-l1")).toHaveTextContent("L1: 4.2%");
    expect(screen.getByTestId("pq-thd-l2")).toHaveTextContent("L2: 4.0%");
    expect(screen.getByTestId("pq-thd-l3")).toHaveTextContent("L3: 4.4%");
  });

  it("never fabricates a total-THD or cross-phase average value", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/power-quality`)) {
        return { jsonBody: pqResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<PowerQualityOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("pq-current-thd")).toBeTruthy());
    // Exactly three per-phase THD values, each explicitly labelled -- no
    // fourth "total" or cross-phase-average entry in the list.
    const thdSection = screen.getByTestId("pq-current-thd");
    const thdItems = thdSection.querySelectorAll("li");
    expect(thdItems).toHaveLength(3);
    expect(thdSection).not.toHaveTextContent(/average across/i);
  });

  it("never renders a StatusBadge or a fabricated data-quality claim -- honest deferred note instead", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/power-quality`)) {
        return { jsonBody: pqResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<PowerQualityOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("pq-evidence")).toBeTruthy());
    expect(screen.queryByTestId("status-badge")).toBeNull();
    expect(screen.getByTestId("pq-evidence")).toHaveTextContent("not yet available");
  });

  it("renders NoDataYet, never an error, when the range genuinely has no data", async () => {
    stubFetch((url) => {
      if (url.includes(`/api/v1/sites/${SITE_ID}/power-quality`)) {
        return { jsonBody: pqResponse(true) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<PowerQualityOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getAllByTestId("state-no-data").length).toBeGreaterThan(0));
  });
});
