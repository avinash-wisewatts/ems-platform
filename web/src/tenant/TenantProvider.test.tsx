import { describe, expect, it, beforeEach } from "vitest";
import { render, screen, waitFor, act } from "@testing-library/react";
import { TenantProvider, useTenant } from "./TenantProvider";
import { SITES_ONE, SITES_TWO_ORGS } from "../test-utils";
import type { SitesResponse } from "../api/types";

function Probe() {
  const t = useTenant();
  return (
    <div>
      <span data-testid="status">{t.status}</span>
      <span data-testid="orgs">{t.organizations.map((o) => o.organization_id).join(",")}</span>
      <span data-testid="siteCount">{t.sites.length}</span>
      <span data-testid="selected">{t.selectedSite?.site_code ?? "-"}</span>
      <button onClick={() => t.selectSite(t.sites[1]?.site_id ?? null)}>pick-second</button>
      <button onClick={() => t.selectSite("not-a-real-id")}>pick-bogus</button>
    </div>
  );
}

function renderTenant(loader: () => Promise<SitesResponse>) {
  return render(
    <TenantProvider loader={loader}>
      <Probe />
    </TenantProvider>,
  );
}

describe("TenantProvider -- organization / site context from GET /api/v1/sites", () => {
  beforeEach(() => window.sessionStorage.clear());

  it("groups the scope-filtered site list by organization", async () => {
    renderTenant(() => Promise.resolve(SITES_TWO_ORGS));
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("ready"));
    expect(screen.getByTestId("orgs").textContent).toBe("org-a,org-b");
    expect(screen.getByTestId("siteCount").textContent).toBe("3");
  });

  it("auto-selects when exactly one site is accessible", async () => {
    renderTenant(() => Promise.resolve(SITES_ONE));
    await waitFor(() => expect(screen.getByTestId("selected").textContent).toBe("A_ONE"));
  });

  it("does not auto-select when more than one site is accessible", async () => {
    renderTenant(() => Promise.resolve(SITES_TWO_ORGS));
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("ready"));
    expect(screen.getByTestId("selected").textContent).toBe("-");
  });

  it("a selection is honoured and persisted per tab", async () => {
    renderTenant(() => Promise.resolve(SITES_TWO_ORGS));
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("ready"));
    await act(async () => {
      screen.getByText("pick-second").click();
    });
    expect(screen.getByTestId("selected").textContent).toBe("A_TWO");
    expect(window.sessionStorage.getItem("ems.web.selectedSiteId")).toBe(SITES_TWO_ORGS.sites[1]!.site_id);
  });

  it("a stored selection that is no longer accessible is dropped, never trusted", async () => {
    window.sessionStorage.setItem("ems.web.selectedSiteId", "stale-id-from-a-previous-scope");
    renderTenant(() => Promise.resolve(SITES_TWO_ORGS));
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("ready"));
    expect(screen.getByTestId("selected").textContent).toBe("-");
  });

  // Regression: a backend running the pre-organization_name contract (e.g.
  // mid-rollout, or an older deployed version) omits organization_name from
  // GET /api/v1/sites entirely. Grouping/sorting must degrade gracefully,
  // never throw during render -- there is no error boundary above
  // TenantProvider, so an uncaught error here blanks the whole app.
  it("does not throw when a site is missing organization_name (old-contract backend)", async () => {
    const sitesWithoutOrgName = {
      sites: SITES_TWO_ORGS.sites.map(({ organization_name: _organization_name, ...rest }) => rest),
    } as unknown as SitesResponse;
    renderTenant(() => Promise.resolve(sitesWithoutOrgName));
    await waitFor(() => expect(screen.getByTestId("status").textContent).toBe("ready"));
    expect(screen.getByTestId("orgs").textContent).toBe("org-a,org-b");
    expect(screen.getByTestId("siteCount").textContent).toBe("3");
  });
});
