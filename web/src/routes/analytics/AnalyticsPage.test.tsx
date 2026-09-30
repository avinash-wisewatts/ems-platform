import { beforeEach, describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AnalyticsPage } from "./AnalyticsPage";
import { AppRoutes } from "../../router";
import { ADMIN_USER, SITES_ONE, renderWithProviders, stubFetch } from "../../test-utils";
import { catalogFixture } from "./analyticsTestFixtures";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function stubAnalytics(catalogStatus = 200) {
  const requests: string[] = [];
  const mock = stubFetch((url) => {
    requests.push(new URL(url, "http://localhost").pathname);
    if (url.includes(`/sites/${SITE_ID}/analytics/catalog`)) {
      return catalogStatus === 200
        ? { jsonBody: catalogFixture({ site_id: SITE_ID }) }
        : { status: catalogStatus, jsonBody: { error: "internal", detail: "Catalogue unavailable." } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
  return { mock, requests };
}

describe("AnalyticsPage (F3)", () => {
  beforeEach(() => window.sessionStorage.clear());

  it("first load: the exact empty state, Update unavailable, no 'Changes not applied', and no series request (D1, D2)", async () => {
    const { requests } = stubAnalytics();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument());
    expect(screen.getByTestId("analytics-empty-state")).toHaveTextContent("Select data to explore");
    expect(screen.getByTestId("analytics-empty-state")).toHaveTextContent("Choose an asset and data point to get started.");
    expect(screen.getByTestId("analytics-update")).toBeDisabled();
    expect(screen.queryByTestId("analytics-changes-not-applied")).not.toBeInTheDocument();
    expect(screen.queryByTestId("analytics-result")).not.toBeInTheDocument();
    expect(requests).toEqual([`/api/v1/sites/${SITE_ID}/analytics/catalog`]);
  });

  it("no site-name page header (D32)", async () => {
    stubAnalytics();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument());
    expect(screen.queryByRole("heading", { name: /Alpha One/ })).not.toBeInTheDocument();
  });

  it("a catalogue failure shows the error state with a retry", async () => {
    stubAnalytics(500);
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(screen.getByTestId("state-error")).toBeInTheDocument());
    expect(screen.queryByTestId("analytics-filters")).not.toBeInTheDocument();
    stubAnalytics();
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument());
  });

  it("/features/analytics renders the Analytics page, not the placeholder (D81)", async () => {
    stubAnalytics();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/features/analytics"],
    });
    await waitFor(() => expect(screen.getByTestId("page-analytics")).toBeInTheDocument());
    await waitFor(() => expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument());
  });
});
