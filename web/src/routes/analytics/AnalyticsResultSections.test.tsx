import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AnalyticsSeries, AnalyticsSeriesResponse } from "../../api/types";
import { AnalyticsChart } from "./AnalyticsChart";
import { AnalyticsDataQuality } from "./AnalyticsDataQuality";
import { AnalyticsPage } from "./AnalyticsPage";
import { AnalyticsStatistics } from "./AnalyticsStatistics";
import { DQ_TEXT } from "./analyticsDataQualityModel";
import { INITIAL_DRAFT, MESSAGES } from "./analyticsQuery";
import {
  SERIES_FROM,
  SERIES_TO,
  catalogFixture,
  notShownFixture,
  pointFixture,
  seriesFixture,
  seriesResponseFixture,
} from "./analyticsTestFixtures";
import type { AppliedQuery } from "./useAnalyticsState";
import { SITES_ONE, renderWithProviders } from "../../test-utils";

const TZ = "Asia/Kolkata";
const catalog = catalogFixture();
const summary = { total: 298.1, average: 12.4, min: 3.2, min_at: "2026-10-05T04:00:00Z", max: 20.9, max_at: "2026-10-05T08:45:00Z" };

function applied(series: AnalyticsSeries[], overrides: Partial<AppliedQuery> = {}, phase: "system" | "three_phase" = "system"): AppliedQuery {
  const assetIds = [...new Set(series.map((s) => s.asset_id))];
  return {
    draft: { ...INITIAL_DRAFT, assetIds, dataPoints: ["ENERGY_IMPORT"], phase },
    range: { from: SERIES_FROM, to: SERIES_TO },
    selections: assetIds.map((assetId) => ({ assetId, dataPoint: "ENERGY_IMPORT" })),
    unavailable: [],
    response: seriesResponseFixture({ from: SERIES_FROM, to: SERIES_TO, as_of: "2026-10-05T06:30:00Z", phase, series }),
    ...overrides,
  };
}

describe("Statistics (F6)", () => {
  it("one row per charted series: Total (Energy), Average, Minimum and Maximum with site-local times", () => {
    const response = seriesResponseFixture({
      series: [seriesFixture("a1", [1], { summary }), notShownFixture("a2", "NO_DATA", ["NO_DATA_IN_RANGE"])],
    });
    render(<AnalyticsStatistics response={response} catalog={catalog} timeZone={TZ} />);
    const table = screen.getByRole("table");
    expect(within(table).getAllByRole("columnheader").map((h) => h.textContent)).toEqual(["Series", "Total", "Average", "Minimum", "Maximum"]);
    const rows = screen.getAllByTestId("analytics-statistics-row");
    expect(rows).toHaveLength(1);
    const cells = within(rows[0]!).getAllByRole("cell").map((c) => c.textContent);
    expect(within(rows[0]!).getByRole("rowheader")).toHaveTextContent("Asset a1 · Energy");
    // 04:00Z and 08:45Z are 09:30 and 14:15 IST.
    expect(cells).toEqual(["298.10 kWh", "12.40 kWh", "3.20 kWh09:30 · 05 Oct 2026", "20.90 kWh14:15 · 05 Oct 2026"]);
  });

  it("a value the API does not return shows as not available, without a time", () => {
    render(<AnalyticsStatistics response={seriesResponseFixture({ series: [seriesFixture("a1", [1])] })} catalog={catalog} timeZone={TZ} />);
    const cells = within(screen.getByTestId("analytics-statistics-row")).getAllByRole("cell").map((c) => c.textContent);
    expect(cells).toEqual(["—", "—", "—", "—"]);
  });

  it("no Total column without an Energy series", () => {
    const power = seriesFixture("a1", [1], { data_point: "ACTIVE_POWER", label: "Active Power", aggregation: "mean", chart_kind: "line", unit: "kW", summary: { ...summary, total: null } });
    render(<AnalyticsStatistics response={seriesResponseFixture({ series: [power] })} catalog={catalog} timeZone={TZ} />);
    expect(screen.getAllByRole("columnheader").map((h) => h.textContent)).toEqual(["Series", "Average", "Minimum", "Maximum"]);
    expect(screen.getByTestId("analytics-statistics-row")).toHaveTextContent("12.40 kW");
  });

  it("absent when nothing is charted", () => {
    render(<AnalyticsStatistics response={seriesResponseFixture({ series: [notShownFixture("a1", "NOT_AVAILABLE")] })} catalog={catalog} timeZone={TZ} />);
    expect(screen.queryByTestId("analytics-statistics")).not.toBeInTheDocument();
  });
});

describe("Data quality section (F6)", () => {
  it("absent when no condition applies", () => {
    render(<AnalyticsDataQuality applied={applied([seriesFixture("a1", [1, 2])])} catalog={catalog} timeZone={TZ} />);
    expect(screen.queryByTestId("analytics-data-quality")).not.toBeInTheDocument();
  });

  it("Series not shown is always expanded; other groups are collapsed with heading and count visible", async () => {
    const stale = seriesFixture("a1", [1], { stale: true, last_data_at: "2026-10-05T04:15:00Z" });
    const reset = seriesFixture("a3", [1]);
    reset.points[0] = pointFixture(0, 1, { evidence_flags: ["RESET_DETECTED"] });
    render(
      <AnalyticsDataQuality
        applied={applied([stale, notShownFixture("a2", "NO_DATA", ["RANGE_IN_FUTURE"]), reset])}
        catalog={catalog}
        timeZone={TZ}
      />,
    );
    const section = screen.getByTestId("analytics-data-quality");
    expect(within(section).getByRole("heading", { level: 2 })).toHaveTextContent("Data quality");
    const groups = [...section.querySelectorAll<HTMLElement>(".analytics-dq__group")];
    expect(groups.map((g) => g.querySelector(".analytics-dq__heading")!.textContent)).toEqual([
      "Series not shown in chart · 1",
      "Meter resets and rollovers · 1 series",
      "No recent data · 1 series",
    ]);
    const notShown = screen.getByTestId("analytics-dq-not-shown");
    expect(notShown.tagName).toBe("SECTION");
    expect(within(notShown).getByText("Asset a2 · Energy")).toBeVisible();
    expect(within(notShown).getByText(DQ_TEXT.reasonFuture)).toBeVisible();

    const noRecent = screen.getByTestId("analytics-dq-no-recent-data") as HTMLDetailsElement;
    expect(noRecent.tagName).toBe("DETAILS");
    expect(noRecent.open).toBe(false);
    await userEvent.click(within(noRecent).getByText("No recent data · 1 series"));
    expect(noRecent.open).toBe(true);
    expect(within(noRecent).getByText("Latest data: 09:45 · 05 Oct 2026 · 2 h 15 min before the chart was updated")).toBeInTheDocument();
  });

  it("a group that is the only one present is expanded", () => {
    const s = seriesFixture("a1", [1, 2]);
    s.points[1] = pointFixture(1, 2, { evidence_flags: ["GAPS_DETECTED"] });
    render(<AnalyticsDataQuality applied={applied([s])} catalog={catalog} timeZone={TZ} />);
    const group = screen.getByTestId("analytics-dq-after-missing") as HTMLDetailsElement;
    expect(group.open).toBe(true);
    expect(within(group).getByText(DQ_TEXT.afterMissingExplanation)).toBeInTheDocument();
    expect(within(group).getByText("00:15 · 05 Oct 2026 · 1 period")).toBeInTheDocument();
  });

  it("explains a selection with no data that the chart leaves out (D6)", () => {
    const a = applied([seriesFixture("a1", [1, 2]), notShownFixture("a2", "NO_DATA", ["NO_DATA_IN_RANGE"])]);
    render(
      <>
        <AnalyticsChart applied={a} catalog={catalog} timeZone={TZ} width={800} />
        <AnalyticsDataQuality applied={a} catalog={catalog} timeZone={TZ} />
      </>,
    );
    expect(within(screen.getByTestId("chart-legend")).queryByText("Asset a2 · Energy")).not.toBeInTheDocument();
    const notShown = screen.getByTestId("analytics-dq-not-shown");
    expect(within(notShown).getByText("Asset a2 · Energy")).toBeInTheDocument();
    expect(within(notShown).getByText(DQ_TEXT.reasonNoData)).toBeInTheDocument();
  });

  it("3 Phase with System-only series lists them under 'Shown as System values'", () => {
    render(<AnalyticsDataQuality applied={applied([seriesFixture("a1", [1])], {}, "three_phase")} catalog={catalog} timeZone={TZ} />);
    const group = screen.getByTestId("analytics-dq-system-values");
    expect(group).toHaveTextContent("Shown as System values · 1 series");
    expect(group).toHaveTextContent(DQ_TEXT.systemValuesExplanation);
    expect(group).toHaveTextContent("Asset a1 · Energy");
  });
});

describe("Chart tooltip -- the period's Data quality lines (D22, DQ9)", () => {
  it("lists each series' quality lines; a series with lines but no value is listed without a value", () => {
    const incomplete = seriesFixture("a1", [1, 2, 3, 4]);
    incomplete.points = incomplete.points.map((_, i) => pointFixture(i, i + 1, { valid_intervals: 12 }));
    const missing = seriesFixture("a2", [null, null, null, null]);
    const healthy = seriesFixture("a3", [5, 5, 5, 5]);
    const { container } = render(
      <AnalyticsChart applied={applied([incomplete, missing, healthy])} catalog={catalog} timeZone={TZ} width={800} />,
    );
    fireEvent.mouseMove(container.querySelector(".recharts-wrapper")!, { clientX: 400, clientY: 100, pageX: 400, pageY: 100 });
    const tooltip = screen.getByTestId("chart-tooltip");
    const items = [...tooltip.querySelectorAll<HTMLElement>(".chart-frame__tooltip-list > li")];
    expect(items.map((li) => li.querySelector(".chart-frame__tooltip-name")!.textContent)).toEqual([
      "Asset a1 · Energy",
      "Asset a2 · Energy",
      "Asset a3 · Energy",
    ]);
    expect(within(items[0]!).getByTestId("chart-tooltip-notes")).toHaveTextContent(DQ_TEXT.tipNotReceived);
    expect(items[0]!.querySelector(".chart-frame__tooltip-value")).not.toBeNull();
    expect(within(items[1]!).getByTestId("chart-tooltip-notes")).toHaveTextContent(DQ_TEXT.tipNoneReceived);
    expect(items[1]!.querySelector(".chart-frame__tooltip-value")).toBeNull();
    expect(within(items[2]!).queryByTestId("chart-tooltip-notes")).not.toBeInTheDocument();
  });
});

// ---- The page: draft vs applied, loading and errors -----------------------------------

describe("Analytics page -- Statistics and Data quality after Update", () => {
  const SITE_ID = SITES_ONE.sites[0]!.site_id;
  afterEach(() => vi.unstubAllGlobals());

  type Pending = { resolve: (r: Response) => void };
  function jsonResponse(status: number, body: unknown): Response {
    return {
      ok: status >= 200 && status < 300,
      status,
      statusText: "",
      headers: new Headers(),
      json: async () => body,
      text: async () => JSON.stringify(body),
    } as unknown as Response;
  }

  /** Catalogue at once; each series request waits until the test answers it. */
  function stubPendingSeries() {
    const pending: Pending[] = [];
    vi.stubGlobal(
      "fetch",
      vi.fn((input: RequestInfo | URL) => {
        const url = new URL(typeof input === "string" ? input : input.toString(), "http://localhost");
        if (url.pathname.endsWith(`/sites/${SITE_ID}/analytics/catalog`)) {
          return Promise.resolve(jsonResponse(200, catalogFixture({ site_id: SITE_ID })));
        }
        return new Promise<Response>((resolve) => pending.push({ resolve }));
      }),
    );
    return pending;
  }

  function response(series: AnalyticsSeries[]): AnalyticsSeriesResponse {
    return seriesResponseFixture({ site_id: SITE_ID, from: SERIES_FROM, to: SERIES_TO, as_of: "2026-10-05T06:30:00Z", series });
  }

  async function selectAssetA1AndEnergy() {
    const assets = screen.getByTestId("asset-selector");
    await userEvent.click(within(assets).getByRole("button", { name: /^Unassigned/ }));
    await userEvent.click(within(assets).getByRole("checkbox", { name: "Asset a1" }));
    const points = screen.getByTestId("data-point-selector");
    await userEvent.click(within(points).getByRole("button", { name: /^Frequently Used/ }));
    await userEvent.click(within(points).getByRole("checkbox", { name: "Energy" }));
  }

  it("hidden until the first successful Update; kept while loading and after a failure; replaced by the next result", async () => {
    const pending = stubPendingSeries();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await screen.findByTestId("analytics-filters");
    await selectAssetA1AndEnergy();

    // A draft alone shows nothing (D64).
    expect(screen.queryByTestId("analytics-statistics")).not.toBeInTheDocument();
    expect(screen.queryByTestId("analytics-data-quality")).not.toBeInTheDocument();

    // First Update: nothing until the response lands.
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(pending).toHaveLength(1));
    expect(screen.queryByTestId("analytics-statistics")).not.toBeInTheDocument();
    pending[0]!.resolve(
      jsonResponse(200, response([seriesFixture("a1", [1, 2], { summary, stale: true, last_data_at: "2026-10-05T04:15:00Z" })])),
    );
    await screen.findByTestId("analytics-statistics");
    expect(screen.getByTestId("analytics-statistics-row")).toHaveTextContent("298.10 kWh");
    expect(screen.getByTestId("analytics-dq-no-recent-data")).toBeInTheDocument();

    // A changed draft does not touch the applied sections.
    const points = screen.getByTestId("data-point-selector");
    await userEvent.click(within(points).getByRole("button", { name: /^Power/ }));
    await userEvent.click(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Energy Export" }));
    expect(screen.getByTestId("analytics-changes-not-applied")).toBeInTheDocument();
    expect(screen.getAllByTestId("analytics-statistics-row")).toHaveLength(1);

    // Loading: the previous result stays (D7).
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(pending).toHaveLength(2));
    expect(screen.getByTestId("analytics-main")).toHaveAttribute("aria-busy", "true");
    expect(screen.getByTestId("analytics-statistics-row")).toHaveTextContent("298.10 kWh");
    expect(screen.getByTestId("analytics-dq-no-recent-data")).toBeInTheDocument();

    // Failure: the previous result stays, with the error near Update (D50, DQ9).
    pending[1]!.resolve(jsonResponse(500, { error: "internal", detail: "boom" }));
    await screen.findByText(MESSAGES.updateFailed);
    expect(screen.getByTestId("analytics-statistics-row")).toHaveTextContent("298.10 kWh");
    expect(screen.getByTestId("analytics-dq-no-recent-data")).toBeInTheDocument();
    expect(screen.queryByTestId("analytics-dq-not-shown")).not.toBeInTheDocument();

    // A successful Update replaces both; a no-data selection is explained, not dropped.
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(pending).toHaveLength(3));
    pending[2]!.resolve(
      jsonResponse(
        200,
        response([
          seriesFixture("a1", [3, 4], { summary: { ...summary, total: 7 } }),
          notShownFixture("a1", "NO_DATA", ["NO_DATA_EVER"], { data_point: "ENERGY_EXPORT", label: "Energy Export" }),
        ]),
      ),
    );
    await waitFor(() => expect(screen.getByTestId("analytics-statistics-row")).toHaveTextContent("7.00 kWh"));
    expect(screen.queryByTestId("analytics-dq-no-recent-data")).not.toBeInTheDocument();
    const notShown = screen.getByTestId("analytics-dq-not-shown");
    expect(within(notShown).getByText("Asset a1 · Energy Export")).toBeInTheDocument();
    expect(within(notShown).getByText(DQ_TEXT.reasonNoData)).toBeInTheDocument();
    expect(screen.queryByText(MESSAGES.updateFailed)).not.toBeInTheDocument();
  });

  it("a failed first Update shows the error and no Statistics or Data quality (not 'no data')", async () => {
    const pending = stubPendingSeries();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await screen.findByTestId("analytics-filters");
    await selectAssetA1AndEnergy();
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(pending).toHaveLength(1));
    pending[0]!.resolve(jsonResponse(500, { error: "internal", detail: "boom" }));
    await screen.findByText(MESSAGES.updateFailed);
    expect(screen.getByTestId("analytics-empty-state")).toBeInTheDocument();
    expect(screen.queryByTestId("analytics-statistics")).not.toBeInTheDocument();
    expect(screen.queryByTestId("analytics-data-quality")).not.toBeInTheDocument();
  });
});
