import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SitePerformanceReport } from "./SitePerformanceReport";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function stubEverything() {
  stubFetch((url) => {
    if (url.includes(`/api/v1/sites/${SITE_ID}/spaces`)) return { jsonBody: { site_id: SITE_ID, spaces: [] } };
    if (url.includes(`/api/v1/sites/${SITE_ID}/assets`)) return { jsonBody: { site_id: SITE_ID, assets: [] } };
    if (url.includes("/energy/consumption/typical-reference")) {
      return {
        jsonBody: {
          site_id: SITE_ID,
          period_length_days: 7,
          from: "2026-01-01T00:00:00.000Z",
          to: "2026-01-08T00:00:00.000Z",
          typical_kwh: 100,
          requested_period_count: 8,
          windows_with_data_count: 8,
          eligible_period_count: 8,
          sufficient: true,
          windows: [],
        },
      };
    }
    if (url.includes("/energy/consumption/evidence")) {
      return {
        jsonBody: {
          site_id: SITE_ID,
          resolution: "1d",
          from: "2026-01-01T00:00:00.000Z",
          to: "2026-01-08T00:00:00.000Z",
          no_data: true,
          series: [],
        },
      };
    }
    if (url.includes("/energy/consumption")) {
      return {
        jsonBody: {
          site_id: SITE_ID,
          resolution: "1d",
          from: "2026-01-01T00:00:00.000Z",
          to: "2026-01-08T00:00:00.000Z",
          no_data: true,
          series: [],
        },
      };
    }
    if (url.includes("/demand")) {
      return { jsonBody: { site_id: SITE_ID, from: "", to: "", no_data: true, series: [] } };
    }
    if (url.includes("/power-quality")) {
      return { jsonBody: { site_id: SITE_ID, resolution: "1d", from: "", to: "", no_data: true, series: [] } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("SitePerformanceReport -- orchestrates configuration <-> generated report (EMS-REQ-110)", () => {
  it("starts on configuration, generates the report on demand, and 'Change' returns to configuration with the selection preserved", async () => {
    stubEverything();
    const user = userEvent.setup();
    renderWithProviders(<SitePerformanceReport />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config")).toBeInTheDocument());
    await user.click(screen.getByTestId("report-config-generate"));

    await waitFor(() => expect(screen.getByTestId("report-view")).toBeInTheDocument());
    expect(screen.getByTestId("report-title")).toHaveTextContent("Performance Report — Alpha One");

    await user.click(screen.getByTestId("report-change"));
    await waitFor(() => expect(screen.getByTestId("report-config")).toBeInTheDocument());
    // Preserved selection: Monthly (the default) is still checked.
    expect(screen.getByLabelText("Monthly (this month)")).toBeChecked();
  });

  it("'Generate another report' also returns to configuration", async () => {
    stubEverything();
    const user = userEvent.setup();
    renderWithProviders(<SitePerformanceReport />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config")).toBeInTheDocument());
    await user.click(screen.getByTestId("report-config-generate"));
    await waitFor(() => expect(screen.getByTestId("report-view")).toBeInTheDocument());

    await user.click(screen.getByTestId("report-generate-another"));
    await waitFor(() => expect(screen.getByTestId("report-config")).toBeInTheDocument());
  });
});
