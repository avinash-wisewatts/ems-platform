import { describe, expect, it, vi } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SitePerformanceReportConfig } from "./SitePerformanceReportConfig";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function stubHierarchy() {
  stubFetch((url) => {
    if (url.includes(`/api/v1/sites/${SITE_ID}/spaces`)) {
      return { jsonBody: { site_id: SITE_ID, spaces: [{ space_id: "sp-1", space_name: "Banquet Hall", space_code: "BH1" }] } };
    }
    if (url.includes(`/api/v1/sites/${SITE_ID}/assets`)) {
      return {
        jsonBody: {
          site_id: SITE_ID,
          assets: [{ asset_id: "as-1", asset_name: "Chiller 1", external_id: "CH-1", lifecycle_status: "ACTIVE", space_id: null }],
        },
      };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("SitePerformanceReportConfig (EMS-REQ-111)", () => {
  it("defaults to Site context and Monthly period, and Generate is enabled by default", async () => {
    stubHierarchy();
    const onGenerate = vi.fn();
    renderWithProviders(<SitePerformanceReportConfig onGenerate={onGenerate} />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config-generate")).not.toBeDisabled());
  });

  it("Space/Asset selection is required before Generate is enabled", async () => {
    stubHierarchy();
    const user = userEvent.setup();
    const onGenerate = vi.fn();
    renderWithProviders(<SitePerformanceReportConfig onGenerate={onGenerate} />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config-generate")).toBeInTheDocument());
    await user.click(screen.getByLabelText(/^Space/));
    expect(screen.getByTestId("report-config-generate")).toBeDisabled();

    await user.selectOptions(screen.getByTestId("report-config-space-select"), "sp-1");
    expect(screen.getByTestId("report-config-generate")).not.toBeDisabled();
  });

  it("generates with the selected Space's name and detail path (ADR-015 gap resolution 1: title/investigation only)", async () => {
    stubHierarchy();
    const user = userEvent.setup();
    const onGenerate = vi.fn();
    renderWithProviders(<SitePerformanceReportConfig onGenerate={onGenerate} />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config-generate")).toBeInTheDocument());
    await user.click(screen.getByLabelText(/^Space/));
    await user.selectOptions(screen.getByTestId("report-config-space-select"), "sp-1");
    await user.click(screen.getByTestId("report-config-generate"));

    expect(onGenerate).toHaveBeenCalledWith(
      expect.objectContaining({
        hierarchyLevel: "SPACE",
        contextName: "Banquet Hall",
        investigatePath: "/features/spaces/sp-1",
        siteId: SITE_ID,
      }),
    );
  });

  it("Custom period requires both dates, in order, before Generate is enabled", async () => {
    stubHierarchy();
    const user = userEvent.setup();
    renderWithProviders(<SitePerformanceReportConfig onGenerate={vi.fn()} />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("report-config-generate")).toBeInTheDocument());
    await user.click(screen.getByLabelText("Custom"));
    expect(screen.getByTestId("report-config-generate")).toBeDisabled();

    await user.type(screen.getByTestId("report-config-custom-from"), "2026-09-01");
    await user.type(screen.getByTestId("report-config-custom-to"), "2026-09-10");
    expect(screen.getByTestId("report-config-generate")).not.toBeDisabled();
  });

  it("does not enforce a data-availability bound on Custom dates (ADR-015 gap resolution 2 -- no such API exists)", async () => {
    stubHierarchy();
    const user = userEvent.setup();
    renderWithProviders(<SitePerformanceReportConfig onGenerate={vi.fn()} />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("report-config-generate")).toBeInTheDocument());
    await user.click(screen.getByLabelText("Custom"));
    // No min/max attribute is set on the custom date inputs.
    expect(screen.getByTestId("report-config-custom-from")).not.toHaveAttribute("min");
    expect(screen.getByTestId("report-config-custom-from")).not.toHaveAttribute("max");
  });
});
