import { describe, expect, it } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AnalyticsSeries } from "../../api/types";
import { AnalyticsChart } from "./AnalyticsChart";
import { AnalyticsPage } from "./AnalyticsPage";
import { INITIAL_DRAFT } from "./analyticsQuery";
import { catalogFixture, seriesResponseFixture } from "./analyticsTestFixtures";
import type { AppliedQuery } from "./useAnalyticsState";
import { SITES_ONE, renderWithProviders, stubFetch } from "../../test-utils";

const Q = 15 * 60_000;
const FROM = "2026-10-04T18:30:00.000Z";
const TO = "2026-10-05T18:30:00.000Z";

function okSeries(assetId: string, values: (number | null)[], overrides: Partial<AnalyticsSeries> = {}): AnalyticsSeries {
  const t0 = Date.parse(FROM);
  return {
    asset_id: assetId,
    asset_name: `Asset ${assetId}`,
    data_point: "ENERGY_IMPORT",
    label: "Energy",
    qualifier: "TOTAL",
    unit: "kWh",
    chart_kind: "bar",
    aggregation: "sum",
    status: "OK",
    status_reasons: [],
    resolution_available_from: null,
    first_data_at: null,
    last_data_at: null,
    stale: false,
    points: values.map((value, i) => ({
      bucket_start: new Date(t0 + i * Q).toISOString(),
      bucket_end: new Date(t0 + (i + 1) * Q).toISOString(),
      value,
      min: null,
      max: null,
      bucket_state: "COMPLETE" as const,
      data_state: value == null ? ("GAP" as const) : ("MEASURED" as const),
      expected_intervals: 15,
      assigned_expected_intervals: 15,
      valid_intervals: value == null ? 0 : 15,
      invalid_intervals: 0,
      reconstructed_intervals: 0,
      evidence_flags: [],
      evidence_status: value == null ? null : "GOOD",
      quality: null,
      is_partial: false,
    })),
    summary: { total: null, average: null, min: null, min_at: null, max: null, max_at: null },
    ...overrides,
  };
}

function appliedQuery(series: AnalyticsSeries[], assetIds: string[]): AppliedQuery {
  return {
    draft: { ...INITIAL_DRAFT, assetIds, dataPoints: ["ENERGY_IMPORT"] },
    range: { from: FROM, to: TO },
    selections: assetIds.map((assetId) => ({ assetId, dataPoint: "ENERGY_IMPORT" })),
    unavailable: [],
    response: seriesResponseFixture({ from: FROM, to: TO, series }),
  };
}

describe("AnalyticsChart -- the chart card (F5)", () => {
  it("title, one legend entry per OK series, and the non-OK series omitted", () => {
    const applied = appliedQuery(
      [okSeries("a1", [1, 2, null]), okSeries("a2", [], { status: "NO_DATA", status_reasons: ["NO_DATA_IN_RANGE"] }), okSeries("a3", [3, null, 1])],
      ["a1", "a2", "a3"],
    );
    render(<AnalyticsChart applied={applied} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    expect(screen.getByTestId("analytics-chart-title")).toHaveTextContent("3 assets, 05 Oct 2026 – 15 minutes, System");
    const legend = within(screen.getByTestId("chart-legend")).getAllByRole("listitem").map((i) => i.textContent);
    expect(legend).toEqual(["Asset a1 · Energy", "Asset a3 · Energy"]);
    expect(document.querySelectorAll(".chart-frame__bar-series")).toHaveLength(2);
  });

  it("Collapse hides the chart (kept mounted, so the zoom survives); Expand shows it again", async () => {
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1, 2])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    const toggle = screen.getByTestId("analytics-chart-collapse");
    expect(toggle).toHaveTextContent("Collapse");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    await userEvent.click(toggle);
    expect(screen.getByTestId("analytics-chart-body")).not.toBeVisible();
    expect(screen.getByTestId("multi-series-chart")).toBeInTheDocument();
    expect(toggle).toHaveTextContent("Expand");
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    await userEvent.click(toggle);
    expect(screen.getByTestId("analytics-chart-body")).toBeVisible();
  });

  it("the toolbar has Collapse / Expand only (Export CSV is the CSV step)", () => {
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    const header = screen.getByTestId("analytics-chart").querySelector(".analytics-chart__toolbar")!;
    expect(within(header as HTMLElement).getAllByRole("button").map((b) => b.textContent)).toEqual(["Collapse"]);
  });
});

describe("Analytics page -- the chart after Update", () => {
  const SITE_ID = SITES_ONE.sites[0]!.site_id;

  it("the empty state until the first Update, then the chart card; a later Update replaces it unzoomed", async () => {
    let asOf = 0;
    stubFetch((url) => {
      const parsed = new URL(url, "http://localhost");
      if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/catalog`)) return { jsonBody: catalogFixture({ site_id: SITE_ID }) };
      if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/series`)) {
        asOf += 1;
        return {
          jsonBody: seriesResponseFixture({
            site_id: SITE_ID,
            from: parsed.searchParams.get("from")!,
            to: parsed.searchParams.get("to")!,
            as_of: `2026-10-05T07:00:0${asOf}Z`,
            series: [okSeries("a1", [1, 2, 3, 4])],
          }),
        };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await screen.findByTestId("analytics-filters");
    expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument();
    expect(screen.queryByTestId("analytics-chart")).not.toBeInTheDocument();

    const assets = screen.getByTestId("asset-selector");
    await userEvent.click(within(assets).getByRole("button", { name: /^Unassigned/ }));
    await userEvent.click(within(assets).getByRole("checkbox", { name: "Asset a1" }));
    const points = screen.getByTestId("data-point-selector");
    await userEvent.click(within(points).getByRole("button", { name: /^Frequently Used/ }));
    await userEvent.click(within(points).getByRole("checkbox", { name: "Energy" }));
    await userEvent.click(screen.getByTestId("analytics-update"));

    await waitFor(() => expect(screen.getByTestId("analytics-chart")).toBeInTheDocument());
    expect(screen.queryByTestId("analytics-empty-state")).not.toBeInTheDocument();
    expect(screen.getByTestId("analytics-chart-title")).toHaveTextContent(/^Asset a1, .+ – 15 minutes, System$/);
    expect(within(screen.getByTestId("chart-legend")).getByText("Asset a1 · Energy")).toBeInTheDocument();
    const firstChart = screen.getByTestId("multi-series-chart");

    // Change the draft and Update again: a new chart instance (zoom reset).
    await userEvent.click(within(points).getByRole("button", { name: /^Power/ }));
    await userEvent.click(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Energy Export" }));
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(screen.getByTestId("multi-series-chart")).not.toBe(firstChart));
  });
});
