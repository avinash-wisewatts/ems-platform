import { describe, expect, it } from "vitest";
import { screen, waitFor } from "@testing-library/react";
import { SiteOverview } from "./SiteOverview";
import { renderWithProviders, stubFetch, SITES_ONE, SITES_TWO_ORGS } from "../test-utils";
import type { EnergyTypicalReferenceResponse } from "../api/types";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

function isEvidenceUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption/evidence`);
}
function isTypicalReferenceUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption/typical-reference`);
}
function isConsumptionUrl(url: string): boolean {
  return (
    !isEvidenceUrl(url) &&
    !isTypicalReferenceUrl(url) &&
    url.includes(`/api/v1/sites/${SITE_ID}/energy/consumption`)
  );
}
function isDemandCurrentUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/demand/current`);
}
function isDemandSeriesUrl(url: string): boolean {
  return !isDemandCurrentUrl(url) && url.includes(`/api/v1/sites/${SITE_ID}/demand`);
}
function isPowerQualityUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/power-quality`);
}
function isFreshnessUrl(url: string): boolean {
  return url.includes(`/api/v1/sites/${SITE_ID}/telemetry-freshness`);
}

function energyResponse(importKwh: number, noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [{ bucket_start: "2026-06-01T00:00:00Z", import_kwh: importKwh, export_kwh: null, source_interval_count: 4 }],
  };
}

function evidenceResponse(noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    no_data: noData,
    series: noData
      ? []
      : [
          {
            bucket_start: "2026-06-01T00:00:00Z",
            source_interval_count: 4,
            valid_import_intervals: 4,
            invalid_import_intervals: 0,
            valid_export_intervals: 4,
            invalid_export_intervals: 0,
            gap_interval_count: 0,
            reset_interval_count: 0,
            rollover_interval_count: 0,
            invalid_interval_count: 0,
            first_source_bucket: "2026-06-01T00:00:00Z",
            last_source_bucket: "2026-06-01T00:45:00Z",
          },
        ],
  };
}

function typicalReferenceWindow(index: number): EnergyTypicalReferenceResponse["windows"][number] {
  return {
    window_index: index,
    from: "2026-05-01T00:00:00Z",
    to: "2026-05-08T00:00:00Z",
    has_data: true,
    total_kwh: 100,
    source_interval_count: 7,
    valid_import_intervals: 7,
    coverage_percent: 100,
    eligible: true,
    gap_interval_count: 0,
    reset_interval_count: 0,
    rollover_interval_count: 0,
    invalid_interval_count: 0,
  };
}

function typicalReferenceResponse(
  overrides: Partial<EnergyTypicalReferenceResponse> = {},
): EnergyTypicalReferenceResponse {
  return {
    site_id: SITE_ID,
    period_length_days: 7,
    from: "2026-06-01T00:00:00Z",
    to: "2026-06-08T00:00:00Z",
    typical_kwh: 100,
    requested_period_count: 8,
    windows_with_data_count: 8,
    eligible_period_count: 8,
    sufficient: true,
    windows: Array.from({ length: 8 }, (_, i) => typicalReferenceWindow(i + 1)),
    ...overrides,
  };
}

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

function demandSeriesResponse(noData = false) {
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
            peak_power_kw: 70.0,
            quality_status: "VALID",
            coverage_percent: 96,
          },
        ],
  };
}

function pqResponse(noData = false) {
  return {
    site_id: SITE_ID,
    resolution: "1h",
    from: "2026-09-01T00:00:00Z",
    to: "2026-09-08T00:00:00Z",
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

function freshnessResponse(overrides: Partial<{ energy: string; demand: string; power_quality: string }> = {}) {
  return {
    site_id: SITE_ID,
    energy: { state: overrides.energy ?? "FRESH", as_of: "2026-09-13T09:58:00Z" },
    demand: { state: overrides.demand ?? "FRESH", as_of: "2026-09-13T09:58:00Z" },
    power_quality: { state: overrides.power_quality ?? "FRESH", as_of: "2026-09-13T09:58:00Z" },
  };
}

/** Wires the standard "healthy" set of stub responses: current=118 vs.
 *  typical=100 -> +18% -- deliberately ABOVE the 15% MVP-3 threshold is
 *  avoided here (this is the "no attention" fixture); see the dedicated
 *  attention tests below for the triggering cases. */
function stubAllHealthy() {
  return stubFetch((url) => {
    if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
    if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
    if (isConsumptionUrl(url)) return { jsonBody: energyResponse(105) }; // +5%, within band
    if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
    if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
    if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

describe("SiteOverview (MVP-3 -- Site Health & Attention)", () => {
  it("composes Site Health, Energy, Demand, and Power Quality from their existing, unmodified endpoints, and shows Healthy when the deviation is within +/-15%", async () => {
    stubAllHealthy();
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "HEALTHY"));
    expect(screen.getByTestId("site-health-label")).toHaveTextContent("Healthy");
    expect(screen.getByTestId("attention-empty")).toBeInTheDocument();

    expect(screen.getByTestId("site-overview-energy-value")).toHaveTextContent("105.0 kWh");
    expect(screen.getByTestId("site-overview-energy-delta")).toHaveTextContent("+5.0%");

    await waitFor(() => expect(screen.getByTestId("site-overview-demand-value")).toHaveTextContent("60.5 kW"));
    expect(screen.getByTestId("site-overview-demand-peak")).toHaveTextContent("70.0 kW");
    // Demand is informational only -- no StatusBadge/attention coloring.
    expect(screen.queryByTestId("status-badge")).toBeNull();

    await waitFor(() => expect(screen.getByTestId("site-overview-pq-value")).toHaveTextContent("PF 0.94"));
  });

  it("triggers Needs Attention with HIGH direction at +18% (above the 15% threshold), and Site Health reflects it", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(118) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "NEEDS_ATTENTION"),
    );
    expect(screen.getByTestId("site-health-summary")).toHaveTextContent("1 significant issue detected.");

    const item = await screen.findByTestId("attention-item");
    expect(item).toHaveTextContent("Unusually high consumption");
    expect(screen.getByTestId("attention-item-trigger")).toHaveTextContent("+18.0%");
    expect(screen.getByTestId("attention-item-trigger")).toHaveTextContent("15%");
    expect(screen.getByTestId("attention-item-evidence")).toHaveTextContent("8 of 8 comparable historical periods");
    expect(screen.getByTestId("attention-item-investigate")).toHaveAttribute("href", "/features/energy");
  });

  it("triggers Needs Attention with LOW direction at -20%", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(80) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "NEEDS_ATTENTION"),
    );
    const item = await screen.findByTestId("attention-item");
    expect(item).toHaveTextContent("Unusually low consumption");
  });

  it("reports Insufficient Data, never Healthy, when the typical reference is insufficient", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url))
        return { jsonBody: typicalReferenceResponse({ sufficient: false, typical_kwh: null, eligible_period_count: 3 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(999) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "INSUFFICIENT_DATA"),
    );
    expect(screen.getByTestId("site-health-label")).toHaveTextContent("Insufficient Data");
    expect(screen.getByTestId("attention-insufficient-data")).toBeInTheDocument();
    expect(screen.queryByTestId("attention-item")).toBeNull();
    expect(screen.queryByTestId("attention-empty")).toBeNull();
  });

  it("reports Insufficient Data when the current period has no energy value at all", async () => {
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse(true) };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(0, true) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "INSUFFICIENT_DATA"),
    );
  });

  it("isolates failures per section: a Demand fetch failure leaves Energy and Power Quality rendering", async () => {
    stubFetch((url) => {
      if (isDemandCurrentUrl(url) || isDemandSeriesUrl(url)) return { status: 500, jsonBody: { error: "server_error" } };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(105) };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("site-overview-demand")).toHaveTextContent("Something went wrong"));
    expect(screen.getByTestId("site-overview-energy-value")).toHaveTextContent("105.0 kWh");
    await waitFor(() => expect(screen.getByTestId("site-overview-pq-value")).toHaveTextContent("PF 0.94"));
    expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "HEALTHY");
  });

  it("renders investigation links into Spaces and Assets", async () => {
    stubAllHealthy();
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("site-overview-hierarchy")).toBeInTheDocument());
    expect(screen.getByText("Spaces →").closest("a")).toHaveAttribute("href", "/features/spaces");
    expect(screen.getByText("Assets →").closest("a")).toHaveAttribute("href", "/features/assets");
  });

  it("shows the Portfolio 'Sites' crumb segment for a multi-site user (once a site is selected), and hides it for single-site (MVP-1 regression)", async () => {
    // Multi-site users are not auto-selected onto a site (Q62) -- simulate
    // an already-made selection the same way a returning-from-/select user
    // would arrive, via the same sessionStorage key TenantProvider itself
    // reads (see tenant/TenantProvider.test.tsx for the same convention).
    window.sessionStorage.setItem("ems.web.selectedSiteId", SITES_TWO_ORGS.sites[0]!.site_id);
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(105) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_TWO_ORGS) });
    await waitFor(() => expect(screen.getByTestId("hierarchy-crumb-portfolio")).toBeInTheDocument());
    window.sessionStorage.clear();
  });

  it("shows no site-selected empty state when the tenant has no accessible sites", async () => {
    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve({ sites: [] }) });
    await waitFor(() => expect(screen.getByTestId("state-empty")).toBeInTheDocument());
  });

  it("shared time range: changing the range re-fetches Energy, Demand, and Power Quality together", async () => {
    let consumptionCalls = 0;
    let demandSeriesCalls = 0;
    let pqCalls = 0;
    stubFetch((url) => {
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) {
        consumptionCalls += 1;
        return { jsonBody: energyResponse(105) };
      }
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) {
        demandSeriesCalls += 1;
        return { jsonBody: demandSeriesResponse() };
      }
      if (isPowerQualityUrl(url)) {
        pqCalls += 1;
        return { jsonBody: pqResponse() };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });
    await waitFor(() => expect(consumptionCalls).toBe(1));
    await waitFor(() => expect(demandSeriesCalls).toBe(1));
    await waitFor(() => expect(pqCalls).toBe(1));

    screen.getByRole("button", { name: "30 Days" }).click();

    await waitFor(() => expect(consumptionCalls).toBe(2));
    await waitFor(() => expect(demandSeriesCalls).toBe(2));
    await waitFor(() => expect(pqCalls).toBe(2));
  });

  it("MVP-4: shows each section's own device freshness, independently, with no blended site-wide verdict", async () => {
    stubFetch((url) => {
      if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse({ energy: "FRESH", demand: "STALE", power_quality: "NO_DATA" }) };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(105) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("site-overview-energy-value")).toHaveTextContent("105.0 kWh"));
    const indicators = await screen.findAllByTestId("freshness-indicator");
    expect(indicators).toHaveLength(3);
    expect(screen.getByTestId("site-overview-energy-freshness")).toHaveTextContent("FRESH");
    expect(screen.getByTestId("site-overview-demand-freshness")).toHaveTextContent("STALE");
    expect(screen.getByTestId("site-overview-pq-freshness")).toHaveTextContent("NO_DATA");
  });

  it("MVP-4 fix: Demand and Power Quality freshness render even when their primary sections have no data -- previously suppressed alongside the missing value", async () => {
    stubFetch((url) => {
      if (isFreshnessUrl(url)) return { jsonBody: freshnessResponse({ energy: "UNKNOWN", demand: "STALE", power_quality: "NO_DATA" }) };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(0, true) }; // Energy: no_data
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(false) }; // Demand: has_data false
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse(true) };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse(true) }; // PQ: no_data
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    // Primary values are genuinely absent -- NoDataYet, not a fabricated value.
    await waitFor(() => expect(screen.getAllByTestId("state-no-data").length).toBeGreaterThanOrEqual(3));
    expect(screen.queryByTestId("site-overview-energy-value")).toBeNull();
    expect(screen.queryByTestId("site-overview-demand-value")).toBeNull();
    expect(screen.queryByTestId("site-overview-pq-value")).toBeNull();

    // Freshness still renders for all three, including the real UNKNOWN value.
    const indicators = await screen.findAllByTestId("freshness-indicator");
    expect(indicators).toHaveLength(3);
    expect(screen.getByTestId("site-overview-energy-freshness")).toHaveTextContent("UNKNOWN");
    expect(screen.getByTestId("site-overview-demand-freshness")).toHaveTextContent("STALE");
    expect(screen.getByTestId("site-overview-pq-freshness")).toHaveTextContent("NO_DATA");
  });

  it("MVP-4: a freshness fetch failure is non-blocking -- Energy, Demand, and Power Quality values still render, with no freshness indicator shown", async () => {
    stubFetch((url) => {
      if (isFreshnessUrl(url)) return { status: 500, jsonBody: { error: "server_error" } };
      if (isEvidenceUrl(url)) return { jsonBody: evidenceResponse() };
      if (isTypicalReferenceUrl(url)) return { jsonBody: typicalReferenceResponse({ typical_kwh: 100 }) };
      if (isConsumptionUrl(url)) return { jsonBody: energyResponse(105) };
      if (isDemandCurrentUrl(url)) return { jsonBody: currentDemandResponse(true) };
      if (isDemandSeriesUrl(url)) return { jsonBody: demandSeriesResponse() };
      if (isPowerQualityUrl(url)) return { jsonBody: pqResponse() };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });

    renderWithProviders(<SiteOverview />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("site-overview-energy-value")).toHaveTextContent("105.0 kWh"));
    await waitFor(() => expect(screen.getByTestId("site-overview-demand-value")).toHaveTextContent("60.5 kW"));
    await waitFor(() => expect(screen.getByTestId("site-overview-pq-value")).toHaveTextContent("PF 0.94"));
    expect(screen.queryByTestId("freshness-indicator")).toBeNull();
    // Freshness failing never touches Site Health/Attention.
    expect(screen.getByTestId("site-health-banner")).toHaveAttribute("data-state", "HEALTHY");
  });
});
