import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MainDashboard } from "./MainDashboard";
import { useTenant } from "../../tenant/TenantProvider";
import { renderWithProviders, stubFetch, SITES_TWO_ORGS } from "../../test-utils";
import { resolveEnergyUsageRequestRange } from "./energyUsage";
import type { EnergyConsumptionPoint, EnergyConsumptionResponse, SiteEnergyAvailabilityResponse } from "../../api/types";

// SITES_TWO_ORGS (test-utils.tsx): Alpha One / Alpha Two (Org A, timezone
// Asia/Kolkata, UTC+5:30), Bravo One (Org B, timezone UTC). More than one
// site -> TenantProvider does NOT auto-select; each test drives selection
// itself via the harness below, matching TenantProvider.test.tsx's own
// button-driven pattern.
const ALPHA_ONE = SITES_TWO_ORGS.sites[0]!; // Asia/Kolkata
const BRAVO_ONE = SITES_TWO_ORGS.sites[2]!; // UTC

// 2026-09-19T09:00:00Z is 2026-09-19T14:30 in Kolkata -- "today" is the
// 19th in both fixture sites' timezones, avoiding an incidental date-
// rollover difference muddying the more targeted timezone tests below.
const FIXED_NOW = new Date("2026-09-19T09:00:00Z");

function DashboardHarness() {
  const { selectSite } = useTenant();
  return (
    <>
      <button data-testid="pick-alpha" onClick={() => selectSite(ALPHA_ONE.site_id)}>
        pick-alpha
      </button>
      <button data-testid="pick-bravo" onClick={() => selectSite(BRAVO_ONE.site_id)}>
        pick-bravo
      </button>
      <MainDashboard />
    </>
  );
}

function availabilityResponse(siteId: string, overrides: Partial<SiteEnergyAvailabilityResponse> = {}): SiteEnergyAvailabilityResponse {
  return { site_id: siteId, has_data: true, earliest: "2025-01-01T00:00:00Z", latest: FIXED_NOW.toISOString(), ...overrides };
}

function energyConsumptionResponse(
  siteId: string,
  resolution: EnergyConsumptionResponse["resolution"],
  from: string,
  to: string,
  series: EnergyConsumptionPoint[] = [],
): EnergyConsumptionResponse {
  return { site_id: siteId, resolution, from, to, no_data: series.length === 0, series };
}

const GENERIC_NO_DATA = { from: "2026-01-01T00:00:00Z", to: "2026-01-02T00:00:00Z", no_data: true, series: [] };

type EnergyUsageStub = { from: string; resolution: string; response: EnergyConsumptionResponse };

/**
 * Stubs every endpoint MainDashboard's OTHER cards (YTD/MTD/Demand/Site
 * Health/Freshness) call with a harmless "no data" response -- their own
 * correctness is out of scope here -- plus GET .../energy/consumption/
 * availability, and routes GET .../energy/consumption calls by their exact
 * `resolution`+`from` query params against a LIST of scripted responses
 * (every display resolution now has its own distinct source resolution, so
 * a single test may need several registered at once): a call matching one
 * entry gets its response; every other energy/consumption call (YTD/MTD/
 * Health, all real but uninteresting here) gets a generic no-data response.
 */
function stubDashboard(
  siteId: string,
  opts: {
    availability?: SiteEnergyAvailabilityResponse;
    energyUsage?: EnergyUsageStub | EnergyUsageStub[];
  } = {},
) {
  const energyUsageStubs = opts.energyUsage ? ([] as EnergyUsageStub[]).concat(opts.energyUsage) : [];
  return stubFetch((url) => {
    if (url.includes(`/api/v1/sites/${siteId}/energy/consumption/availability`)) {
      return { jsonBody: opts.availability ?? availabilityResponse(siteId) };
    }
    if (url.includes(`/api/v1/sites/${siteId}/telemetry-freshness`)) {
      return {
        jsonBody: {
          site_id: siteId,
          energy: { state: "UNKNOWN", as_of: null },
          demand: { state: "UNKNOWN", as_of: null },
          power_quality: { state: "UNKNOWN", as_of: null },
        },
      };
    }
    if (url.includes(`/api/v1/sites/${siteId}/demand/current`)) {
      return {
        jsonBody: {
          site_id: siteId,
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
    if (url.includes(`/api/v1/sites/${siteId}/demand`)) {
      return { jsonBody: { site_id: siteId, ...GENERIC_NO_DATA } };
    }
    if (url.includes(`/api/v1/sites/${siteId}/energy/consumption/evidence`)) {
      return { jsonBody: { site_id: siteId, resolution: "1h", ...GENERIC_NO_DATA } };
    }
    if (url.includes(`/api/v1/sites/${siteId}/energy/consumption/typical-reference`)) {
      return {
        jsonBody: {
          site_id: siteId,
          period_length_days: 7,
          from: "2026-01-01T00:00:00Z",
          to: "2026-01-08T00:00:00Z",
          typical_kwh: null,
          requested_period_count: 8,
          windows_with_data_count: 0,
          eligible_period_count: 0,
          sufficient: false,
          windows: [],
        },
      };
    }
    if (url.includes(`/api/v1/sites/${siteId}/energy/consumption`)) {
      const parsed = new URL(url, "http://localhost");
      const from = parsed.searchParams.get("from");
      const resolution = parsed.searchParams.get("resolution");
      const match = energyUsageStubs.find((s) => s.from === from && s.resolution === resolution);
      if (match) return { jsonBody: match.response };
      return { jsonBody: { site_id: siteId, resolution: resolution ?? "1d", ...GENERIC_NO_DATA } };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

async function pickAlpha() {
  const user = userEvent.setup();
  await user.click(screen.getByTestId("pick-alpha"));
  await waitFor(() => expect(screen.getByTestId("page-main-dashboard")).toBeInTheDocument());
}

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(FIXED_NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe("MainDashboard -- Energy Usage chart", () => {
  it("defaults to Today (site-local) at Hourly resolution -- never a rolling preset", async () => {
    const defaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: defaultRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", defaultRange.from, defaultRange.to, [
          { bucket_start: "2026-09-19T04:00:00Z", import_kwh: 12, export_kwh: null, source_interval_count: 4 },
        ]),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).toHaveValue("2026-09-19"));
    expect(screen.getByTestId("energy-usage-to")).toHaveValue("2026-09-19");
    expect(screen.getByTestId("energy-usage-resolution")).toHaveValue("HOURLY");
  });

  it("REGRESSION: with real hourly data available for today, the DEFAULT initial state renders a real bar, not an empty/no-data chart", async () => {
    const defaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: defaultRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", defaultRange.from, defaultRange.to, [
          { bucket_start: "2026-09-19T04:00:00Z", import_kwh: 42, export_kwh: null, source_interval_count: 4 },
        ]),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() => expect(screen.getByTestId("chart-frame")).toBeInTheDocument());
    expect(screen.getByTestId("energy-usage").querySelector('[data-testid="state-no-data"]')).toBeNull();
  });

  it("bounds the date pickers to the site's ACTUAL earliest/latest data, not an API window cap", async () => {
    stubDashboard(ALPHA_ONE.site_id, {
      availability: availabilityResponse(ALPHA_ONE.site_id, { earliest: "2025-03-10T00:00:00Z", latest: FIXED_NOW.toISOString() }),
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).not.toBeDisabled());
    expect(screen.getByTestId("energy-usage-from")).toHaveAttribute("min", "2025-03-10");
    expect(screen.getByTestId("energy-usage-to")).toHaveAttribute("max", "2026-09-19");
  });

  it("a no-data site's picker collapses to today only, never a fabricated range", async () => {
    stubDashboard(ALPHA_ONE.site_id, {
      availability: availabilityResponse(ALPHA_ONE.site_id, { has_data: false, earliest: null, latest: null }),
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).not.toBeDisabled());
    expect(screen.getByTestId("energy-usage-from")).toHaveAttribute("min", "2026-09-19");
    expect(screen.getByTestId("energy-usage-to")).toHaveAttribute("max", "2026-09-19");
  });

  it("all four Energy Usage controls (From, To, Apply, Resolution) share the same horizontal control row", async () => {
    stubDashboard(ALPHA_ONE.site_id);
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() => expect(screen.getByTestId("energy-usage-apply")).toBeInTheDocument());

    const controls = screen.getByTestId("energy-usage-apply").closest(".energy-usage__controls");
    expect(controls).not.toBeNull();
    expect(controls!.contains(screen.getByTestId("energy-usage-from"))).toBe(true);
    expect(controls!.contains(screen.getByTestId("energy-usage-to"))).toBe(true);
    expect(controls!.contains(screen.getByTestId("energy-usage-resolution"))).toBe(true);
  });

  it("a range of 31 days or less offers all five resolutions, including Hourly", async () => {
    stubDashboard(ALPHA_ONE.site_id);
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() => expect(screen.getByTestId("energy-usage-resolution")).toBeInTheDocument());

    const options = screen.getByTestId("energy-usage-resolution").querySelectorAll("option");
    expect(Array.from(options).map((o) => o.textContent)).toEqual(["Hourly", "Daily", "Weekly", "Monthly", "Yearly"]);
  });

  it("applying a range beyond 31 days removes Hourly from the resolution options -- the date range is NOT restricted because of this", async () => {
    const longRange = resolveEnergyUsageRequestRange("2026-06-01", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: longRange.from,
        resolution: "1d",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1d", longRange.from, longRange.to, []),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).not.toBeDisabled());

    fireEvent.change(screen.getByTestId("energy-usage-from"), { target: { value: "2026-06-01" } });
    const user = userEvent.setup();
    await user.click(screen.getByTestId("energy-usage-apply"));

    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).toHaveValue("2026-06-01"));
    // The date range itself was applied exactly as entered -- never shrunk.
    expect(screen.getByTestId("energy-usage-to")).toHaveValue("2026-09-19");
    const options = screen.getByTestId("energy-usage-resolution").querySelectorAll("option");
    expect(Array.from(options).map((o) => o.textContent)).toEqual(["Daily", "Weekly", "Monthly", "Yearly"]);
  });

  it("applying a range beyond 31 days while Hourly is selected automatically switches to Daily, keeping the applied range unchanged", async () => {
    const longRange = resolveEnergyUsageRequestRange("2026-06-01", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    const fetchMock = stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: longRange.from,
        resolution: "1d",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1d", longRange.from, longRange.to, [
          { bucket_start: longRange.from, import_kwh: 10, export_kwh: null, source_interval_count: 96 },
        ]),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() => expect(screen.getByTestId("energy-usage-resolution")).toHaveValue("HOURLY"));

    fireEvent.change(screen.getByTestId("energy-usage-from"), { target: { value: "2026-06-01" } });
    const user = userEvent.setup();
    await user.click(screen.getByTestId("energy-usage-apply"));

    await waitFor(() => expect(screen.getByTestId("energy-usage-resolution")).toHaveValue("DAILY"));
    // The range itself was preserved exactly, not reverted or shrunk.
    expect(screen.getByTestId("energy-usage-from")).toHaveValue("2026-06-01");
    expect(screen.getByTestId("energy-usage-to")).toHaveValue("2026-09-19");
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(
          (c) => String(c[0]).includes(encodeURIComponent(longRange.from)) && String(c[0]).includes("resolution=1d"),
        ),
      ).toBe(true),
    );
  });

  it("does not re-fetch when the dates are changed but Apply is not clicked, and fetches the new range once Apply is clicked", async () => {
    const defaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    const appliedRange = resolveEnergyUsageRequestRange("2026-09-01", "2026-09-05", ALPHA_ONE.timezone, FIXED_NOW);
    const fetchMock = stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: appliedRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", appliedRange.from, appliedRange.to, []),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() =>
      expect(fetchMock.mock.calls.some((c) => String(c[0]).includes(encodeURIComponent(defaultRange.from)))).toBe(true),
    );
    const callsBefore = fetchMock.mock.calls.length;

    fireEvent.change(screen.getByTestId("energy-usage-from"), { target: { value: "2026-09-01" } });
    fireEvent.change(screen.getByTestId("energy-usage-to"), { target: { value: "2026-09-05" } });
    // Changing the drafts alone must not trigger any new request.
    expect(fetchMock.mock.calls.length).toBe(callsBefore);
    expect(fetchMock.mock.calls.some((c) => String(c[0]).includes(encodeURIComponent(appliedRange.from)))).toBe(false);

    const user = userEvent.setup();
    await user.click(screen.getByTestId("energy-usage-apply"));
    await waitFor(() =>
      expect(fetchMock.mock.calls.some((c) => String(c[0]).includes(encodeURIComponent(appliedRange.from)))).toBe(true),
    );
    // A short range keeps Hourly valid -- no auto-switch should occur here.
    expect(screen.getByTestId("energy-usage-resolution")).toHaveValue("HOURLY");
  });

  it("the Apply button is disabled for an out-of-order (From after To) selection", async () => {
    stubDashboard(ALPHA_ONE.site_id);
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).not.toBeDisabled());

    fireEvent.change(screen.getByTestId("energy-usage-from"), { target: { value: "2026-09-19" } });
    fireEvent.change(screen.getByTestId("energy-usage-to"), { target: { value: "2026-09-10" } });

    expect(screen.getByTestId("energy-usage-apply")).toBeDisabled();
  });

  it("Weekly/Monthly/Yearly each request the server-side aggregation resolution (1w/1mo/1y) and render the server's totals directly", async () => {
    const range = resolveEnergyUsageRequestRange("2026-06-01", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    const fetchMock = stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: [
        {
          from: range.from,
          resolution: "1d",
          response: energyConsumptionResponse(ALPHA_ONE.site_id, "1d", range.from, range.to, [
            { bucket_start: range.from, import_kwh: 1, export_kwh: null, source_interval_count: 96 },
          ]),
        },
        {
          from: range.from,
          resolution: "1w",
          response: energyConsumptionResponse(ALPHA_ONE.site_id, "1w", range.from, range.to, [
            { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 70, export_kwh: null, source_interval_count: 672 },
          ]),
        },
        {
          from: range.from,
          resolution: "1mo",
          response: energyConsumptionResponse(ALPHA_ONE.site_id, "1mo", range.from, range.to, [
            { bucket_start: "2026-06-01T00:00:00Z", import_kwh: 300, export_kwh: null, source_interval_count: 2880 },
          ]),
        },
        {
          from: range.from,
          resolution: "1y",
          response: energyConsumptionResponse(ALPHA_ONE.site_id, "1y", range.from, range.to, [
            { bucket_start: "2026-01-01T00:00:00Z", import_kwh: 3650, export_kwh: null, source_interval_count: 35040 },
          ]),
        },
      ],
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    fireEvent.change(screen.getByTestId("energy-usage-from"), { target: { value: "2026-06-01" } });
    const user = userEvent.setup();
    await user.click(screen.getByTestId("energy-usage-apply"));
    await waitFor(() => expect(screen.getByTestId("energy-usage-resolution")).toHaveValue("DAILY"));

    for (const [option, resolution] of [
      ["WEEKLY", "1w"],
      ["MONTHLY", "1mo"],
      ["YEARLY", "1y"],
    ] as const) {
      await user.selectOptions(screen.getByTestId("energy-usage-resolution"), option);
      await waitFor(() =>
        expect(
          fetchMock.mock.calls.some(
            (c) => String(c[0]).includes(encodeURIComponent(range.from)) && String(c[0]).includes(`resolution=${resolution}`),
          ),
        ).toBe(true),
      );
    }
  });

  it("shows kWh on the chart (axis/tooltip labelling)", async () => {
    const defaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: defaultRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", defaultRange.from, defaultRange.to, [
          { bucket_start: "2026-09-19T04:00:00Z", import_kwh: 12, export_kwh: null, source_interval_count: 4 },
        ]),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() => expect(screen.getByTestId("chart-frame")).toBeInTheDocument());
    expect(screen.getByTestId("chart-frame")).toHaveAttribute("aria-label", expect.stringContaining("kWh"));
  });

  it("shows the existing no-data state, never a fabricated chart, when the selected range has no usable data", async () => {
    const defaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    stubDashboard(ALPHA_ONE.site_id, {
      energyUsage: {
        from: defaultRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", defaultRange.from, defaultRange.to, []),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();

    await waitFor(() =>
      expect(screen.getByTestId("energy-usage").querySelector('[data-testid="state-no-data"]')).toBeInTheDocument(),
    );
    expect(screen.getByTestId("energy-usage").querySelector('[data-testid="chart-frame"]')).toBeNull();
  });

  it("uses the SELECTED SITE's own timezone for the default range and availability bounds, not UTC", async () => {
    const bravoDefaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", BRAVO_ONE.timezone, FIXED_NOW);
    const alphaDefaultRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    expect(bravoDefaultRange.from).not.toBe(alphaDefaultRange.from); // sanity: the two zones really do diverge

    const fetchMock = stubDashboard(BRAVO_ONE.site_id, {
      energyUsage: {
        from: bravoDefaultRange.from,
        resolution: "1h",
        response: energyConsumptionResponse(BRAVO_ONE.site_id, "1h", bravoDefaultRange.from, bravoDefaultRange.to, []),
      },
    });
    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    const user = userEvent.setup();
    await user.click(screen.getByTestId("pick-bravo"));

    await waitFor(() =>
      expect(fetchMock.mock.calls.some((c) => String(c[0]).includes(encodeURIComponent(bravoDefaultRange.from)))).toBe(
        true,
      ),
    );
  });

  it("reloads Energy Usage (fresh default range + fresh availability) for a newly selected site", async () => {
    const alphaRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", ALPHA_ONE.timezone, FIXED_NOW);
    const bravoRange = resolveEnergyUsageRequestRange("2026-09-19", "2026-09-19", BRAVO_ONE.timezone, FIXED_NOW);

    const fetchMock = stubFetch((url) => {
      for (const site of [ALPHA_ONE, BRAVO_ONE]) {
        if (url.includes(`/api/v1/sites/${site.site_id}/energy/consumption/availability`)) {
          return { jsonBody: availabilityResponse(site.site_id) };
        }
        if (url.includes(`/api/v1/sites/${site.site_id}/telemetry-freshness`)) {
          return {
            jsonBody: {
              site_id: site.site_id,
              energy: { state: "UNKNOWN", as_of: null },
              demand: { state: "UNKNOWN", as_of: null },
              power_quality: { state: "UNKNOWN", as_of: null },
            },
          };
        }
        if (url.includes(`/api/v1/sites/${site.site_id}/demand/current`)) {
          return {
            jsonBody: {
              site_id: site.site_id,
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
        if (url.includes(`/api/v1/sites/${site.site_id}/demand`)) {
          return { jsonBody: { site_id: site.site_id, ...GENERIC_NO_DATA } };
        }
        if (url.includes(`/api/v1/sites/${site.site_id}/energy/consumption/evidence`)) {
          return { jsonBody: { site_id: site.site_id, resolution: "1h", ...GENERIC_NO_DATA } };
        }
        if (url.includes(`/api/v1/sites/${site.site_id}/energy/consumption/typical-reference`)) {
          return {
            jsonBody: {
              site_id: site.site_id,
              period_length_days: 7,
              from: "2026-01-01T00:00:00Z",
              to: "2026-01-08T00:00:00Z",
              typical_kwh: null,
              requested_period_count: 8,
              windows_with_data_count: 0,
              eligible_period_count: 0,
              sufficient: false,
              windows: [],
            },
          };
        }
      }
      if (url.includes(`/api/v1/sites/${ALPHA_ONE.site_id}/energy/consumption`)) {
        return { jsonBody: energyConsumptionResponse(ALPHA_ONE.site_id, "1h", alphaRange.from, alphaRange.to, []) };
      }
      if (url.includes(`/api/v1/sites/${BRAVO_ONE.site_id}/energy/consumption`)) {
        return { jsonBody: energyConsumptionResponse(BRAVO_ONE.site_id, "1h", bravoRange.from, bravoRange.to, []) };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<DashboardHarness />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await pickAlpha();
    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some((c) => String(c[0]).includes(`/sites/${ALPHA_ONE.site_id}/energy/consumption`)),
      ).toBe(true),
    );

    const user = userEvent.setup();
    await user.click(screen.getByTestId("pick-bravo"));

    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(
          (c) =>
            String(c[0]).includes(`/sites/${BRAVO_ONE.site_id}/energy/consumption`) &&
            String(c[0]).includes(encodeURIComponent(bravoRange.from)),
        ),
      ).toBe(true),
    );
    await waitFor(() => expect(screen.getByTestId("energy-usage-from")).toHaveValue("2026-09-19"));
  });
});
