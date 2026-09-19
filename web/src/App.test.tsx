import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor, within } from "@testing-library/react";
import { AppRoutes } from "./router";
import { UnauthenticatedError } from "./api/errors";
import {
  ADMIN_USER,
  NO_SHELL_USER,
  renderWithProviders,
  SITES_ONE,
  SITES_THREE_ORGS,
  SITES_TWO_ORGS,
  stubFetch,
  VIEWER_USER,
} from "./test-utils";

/**
 * MVP-3: `/home` is now SiteOverview, which fetches Energy/Demand/Power
 * Quality data on mount (unlike the old, static ShellHome placeholder).
 * Tests below that reach `/home` while authenticated with shell access stub
 * every request to an honest "no data" response -- these tests assert on
 * shell/nav/identity, not on SiteOverview's own content (that is covered by
 * SiteOverview.test.tsx), so the exact response shape doesn't matter here,
 * only that every request resolves deterministically.
 */
function stubHomeNoDataFetch() {
  return stubFetch((url) => {
    if (url.includes("/energy/consumption/evidence")) {
      return { jsonBody: { site_id: "x", resolution: "1h", from: "", to: "", no_data: true, series: [] } };
    }
    if (url.includes("/energy/consumption/typical-reference")) {
      return {
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
    }
    if (url.includes("/energy/consumption")) {
      return { jsonBody: { site_id: "x", resolution: "1h", from: "", to: "", no_data: true, series: [] } };
    }
    if (url.includes("/demand/current")) {
      return {
        jsonBody: {
          site_id: "x",
          has_data: false,
          interval_start: null,
          interval_end: null,
          current_demand_kw: null,
          current_demand_kva: null,
          quality_status: null,
          coverage_percent: null,
        },
      };
    }
    if (url.includes("/demand")) {
      return { jsonBody: { site_id: "x", from: "", to: "", no_data: true, series: [] } };
    }
    if (url.includes("/power-quality")) {
      return { jsonBody: { site_id: "x", resolution: "1h", from: "", to: "", no_data: true, series: [] } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("application shell -- foundation routing, auth and tenant context", () => {
  // A stored selection (used by the org-switch test below) must never leak
  // into a neighbouring test's expectations about the picker/select flow.
  beforeEach(() => window.sessionStorage.clear());

  it("renders the empty shell for an authenticated user with one accessible site", async () => {
    // WiseWatts redesign: Bootstrap's "/" landing redirect now targets
    // /dashboard (Main Dashboard), not /home (SiteOverview stays intact,
    // reachable from the sidebar's Archive section) -- see Bootstrap.tsx.
    stubHomeNoDataFetch();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());
    expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument();
    expect(screen.getByTestId("identity-name")).toHaveTextContent("Platform Admin");
    expect(screen.getByTestId("context-site")).toHaveTextContent("Alpha One");
  });

  it("shows the organization as static text (no dropdown) for a single-org user", async () => {
    stubHomeNoDataFetch();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());
    expect(screen.getByTestId("org-switcher-static")).toHaveTextContent("Org A");
    expect(screen.queryByTestId("org-switcher-trigger")).not.toBeInTheDocument();
    expect(screen.getByTestId("context-site")).toHaveTextContent("Org A: Alpha One");
  });

  it("lets a multi-org user switch organizations from the sidebar, which switches the selected site", async () => {
    stubHomeNoDataFetch();
    window.sessionStorage.setItem("ems.web.selectedSiteId", SITES_TWO_ORGS.sites[0]!.site_id);
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_TWO_ORGS),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());
    expect(screen.getByTestId("context-site")).toHaveTextContent("Org A: Alpha One");
    expect(screen.getByTestId("org-switcher-trigger")).toHaveTextContent("Org A");

    fireEvent.click(screen.getByTestId("org-switcher-trigger"));
    fireEvent.click(screen.getByTestId("org-switcher-item-org-b"));

    expect(screen.getByTestId("context-site")).toHaveTextContent("Org B: Bravo One");
    expect(screen.getByTestId("org-switcher-trigger")).toHaveTextContent("Org B");
    expect(screen.getByTestId("site-switcher-trigger")).toHaveTextContent("Bravo One");
  });

  it("lists every accessible organization and scopes the Site dropdown to whichever one is current", async () => {
    stubHomeNoDataFetch();
    window.sessionStorage.setItem("ems.web.selectedSiteId", SITES_THREE_ORGS.sites[0]!.site_id);
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_THREE_ORGS),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());

    // All three orgs the user has access to are listed, not just the current one.
    fireEvent.click(screen.getByTestId("org-switcher-trigger"));
    const orgList = screen.getByRole("listbox", { name: "Organizations" });
    expect(within(orgList).getByTestId("org-switcher-item-org-a")).toBeInTheDocument();
    expect(within(orgList).getByTestId("org-switcher-item-org-b")).toBeInTheDocument();
    expect(within(orgList).getByTestId("org-switcher-item-org-c")).toBeInTheDocument();

    // Switching to Org C (two sites) scopes the Site dropdown to exactly those two.
    fireEvent.click(screen.getByTestId("org-switcher-item-org-c"));
    expect(screen.getByTestId("site-switcher-trigger")).toHaveTextContent("Charlie One");
    fireEvent.click(screen.getByTestId("site-switcher-trigger"));
    const siteList = screen.getByRole("listbox", { name: "Sites" });
    expect(within(siteList).getByText("Charlie One")).toBeInTheDocument();
    expect(within(siteList).getByText("Charlie Two")).toBeInTheDocument();
    expect(within(siteList).queryByText("Alpha One")).not.toBeInTheDocument();
    expect(within(siteList).queryByText("Alpha Two")).not.toBeInTheDocument();
    expect(within(siteList).queryByText("Bravo One")).not.toBeInTheDocument();

    // Switching again to Org B (one site) re-scopes the Site dropdown to just that one.
    fireEvent.click(screen.getByTestId("site-switcher-trigger")); // close the site panel first
    fireEvent.click(screen.getByTestId("org-switcher-trigger"));
    fireEvent.click(screen.getByTestId("org-switcher-item-org-b"));
    expect(screen.getByTestId("site-switcher-trigger")).toHaveTextContent("Bravo One");
    fireEvent.click(screen.getByTestId("site-switcher-trigger"));
    const siteListAfterB = screen.getByRole("listbox", { name: "Sites" });
    expect(within(siteListAfterB).getByText("Bravo One")).toBeInTheDocument();
    expect(within(siteListAfterB).queryByText("Charlie One")).not.toBeInTheDocument();
  });

  it("falls back to organization_id (never a blank label) when a backend omits organization_name", async () => {
    stubHomeNoDataFetch();
    const oldContractSites = {
      sites: SITES_TWO_ORGS.sites.map(({ organization_name: _organization_name, ...rest }) => rest),
    } as unknown as typeof SITES_TWO_ORGS;
    window.sessionStorage.setItem("ems.web.selectedSiteId", oldContractSites.sites[0]!.site_id);
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(oldContractSites),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());
    expect(screen.getByTestId("org-switcher-trigger")).toHaveTextContent("org-a");
    fireEvent.click(screen.getByTestId("org-switcher-trigger"));
    expect(screen.getByTestId("org-switcher-item-org-b")).toHaveTextContent("org-b");
  });

  it("routes an authenticated user with several sites to the site picker first", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_TWO_ORGS),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("page-select-context")).toBeInTheDocument());
    // organizations are derived from the (already scope-filtered) site list.
    // Scoped to the page itself: the WiseWatts redesign's sidebar also has
    // its own site search/switcher (visible shell-wide, including here),
    // so "Bravo One" now legitimately appears twice on this screen.
    expect(within(screen.getByTestId("page-select-context")).getByText("Bravo One")).toBeInTheDocument();
  });

  it("shows the loading state while the session resolves", () => {
    renderWithProviders(<AppRoutes />, {
      session: () => new Promise(() => {}), // never resolves
      initialEntries: ["/"],
    });
    expect(screen.getByTestId("state-loading")).toBeInTheDocument();
  });

  it("redirects an unauthenticated user to the existing /login page (no SPA login form)", async () => {
    const assign = vi.fn();
    vi.stubGlobal("location", { ...window.location, assign, pathname: "/app/", search: "" });
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.reject(new UnauthenticatedError()),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("page-login-redirect")).toBeInTheDocument());
    expect(assign).toHaveBeenCalledWith(expect.stringContaining("/login?next_path="));
  });

  it("shows an error state (with retry) when the session bootstrap fails", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.reject(new Error("backend unavailable")),
      initialEntries: ["/"],
    });
    await waitFor(() => expect(screen.getByTestId("state-error")).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("permission-gates navigation: a VIEWER sees fewer nav items than an ADMIN", async () => {
    stubHomeNoDataFetch();
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(VIEWER_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/home"],
    });
    await waitFor(() => expect(screen.getByTestId("app-shell")).toBeInTheDocument());
    expect(screen.getByTestId("nav-home")).toBeInTheDocument();
    expect(screen.getByTestId("nav-features")).toBeInTheDocument();
    expect(screen.queryByTestId("nav-admin")).not.toBeInTheDocument();
  });

  it("an identity without dashboard.view is shown Forbidden, not the shell", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(NO_SHELL_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/home"],
    });
    await waitFor(() => expect(screen.getByTestId("page-forbidden")).toBeInTheDocument());
    expect(screen.queryByTestId("app-shell")).not.toBeInTheDocument();
  });

  it("the feature namespace is an honest placeholder, not a pretend feature", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/features/anything"],
    });
    await waitFor(() => expect(screen.getByTestId("page-placeholder")).toBeInTheDocument());
    expect(screen.getByText(/not implemented yet/i)).toBeInTheDocument();
  });

  it("an unknown route renders Not found inside the shell", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve(SITES_ONE),
      initialEntries: ["/nope"],
    });
    await waitFor(() => expect(screen.getByTestId("page-not-found")).toBeInTheDocument());
  });

  it("an accessible site with no sites at all shows an empty state, not an error", async () => {
    renderWithProviders(<AppRoutes />, {
      session: () => Promise.resolve(ADMIN_USER),
      sites: () => Promise.resolve({ sites: [] }),
      initialEntries: ["/select"],
    });
    await waitFor(() => expect(screen.getByTestId("state-empty")).toBeInTheDocument());
    expect(screen.getByText(/No accessible sites/i)).toBeInTheDocument();
  });
});
