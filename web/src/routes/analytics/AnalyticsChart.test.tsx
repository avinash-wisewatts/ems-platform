import { afterEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { AnalyticsSeries } from "../../api/types";
import { AnalyticsChart } from "./AnalyticsChart";
import { AnalyticsPage } from "./AnalyticsPage";
import { INITIAL_DRAFT } from "./analyticsQuery";
import { catalogFixture, seriesResponseFixture } from "./analyticsTestFixtures";
import type { AppliedQuery } from "./useAnalyticsState";
import { SITES_ONE, renderWithProviders, stubFetch } from "../../test-utils";
import { downloadCsv } from "../../export/downloadCsv";

vi.mock("../../export/downloadCsv", () => ({ downloadCsv: vi.fn() }));

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
    expect(legend).toEqual(["Asset a1-Energy", "Asset a3-Energy"]);
    expect(document.querySelectorAll(".chart-frame__bar-series")).toHaveLength(2);
  });

  it("Collapse hides the chart (kept mounted, so the zoom survives); Expand shows it again", async () => {
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1, 2])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    const toggle = screen.getByTestId("analytics-chart-collapse");
    expect(toggle).toHaveAccessibleName("Collapse chart");
    expect(toggle).toHaveAttribute("title", "Collapse chart");
    expect(toggle.querySelector("svg")).toHaveAttribute("data-direction", "up");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(toggle).toHaveAttribute("aria-controls", screen.getByTestId("analytics-chart-body").id);
    await userEvent.click(toggle);
    expect(screen.getByTestId("analytics-chart-body")).not.toBeVisible();
    expect(screen.getByTestId("multi-series-chart")).toBeInTheDocument();
    expect(toggle).toHaveAccessibleName("Expand chart");
    expect(toggle).toHaveAttribute("title", "Expand chart");
    expect(toggle.querySelector("svg")).toHaveAttribute("data-direction", "down");
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    await userEvent.click(toggle);
    expect(screen.getByTestId("analytics-chart-body")).toBeVisible();
  });

  it("the toolbar has Export CSV and Collapse / Expand only (D27), as named icon buttons with tooltips", () => {
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    const toolbar = screen.getByRole("group", { name: "Chart options" });
    const buttons = within(toolbar).getAllByRole("button");
    expect(buttons.map((b) => b.getAttribute("aria-label"))).toEqual(["Export CSV", "Collapse chart"]);
    expect(buttons.map((b) => b.getAttribute("title"))).toEqual(["Export CSV", "Collapse chart"]);
    // Icons only: no visible text, and the icons are hidden from assistive technology.
    for (const b of buttons) {
      expect(b.textContent).toBe("");
      expect(b.querySelector("svg")).toHaveAttribute("aria-hidden", "true");
    }
  });

  it("the toolbar works from the keyboard", async () => {
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" width={800} />);
    const exportButton = screen.getByRole("button", { name: "Export CSV" });
    const collapse = screen.getByRole("button", { name: "Collapse chart" });
    exportButton.focus();
    await userEvent.tab();
    expect(collapse).toHaveFocus();
    await userEvent.keyboard("{Enter}");
    expect(screen.getByRole("button", { name: "Expand chart" })).toHaveFocus();
    expect(screen.getByTestId("analytics-chart-body")).not.toBeVisible();
  });

  it("chart series use the colours the page assigned", () => {
    const styles = new Map([["a1:ENERGY_IMPORT:TOTAL", { color: "#e34948", pattern: 0 as const }]]);
    render(<AnalyticsChart applied={appliedQuery([okSeries("a1", [1, 2])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" styles={styles} width={800} />);
    expect(document.querySelector(".chart-frame__bar-series")).toHaveAttribute("fill", "#e34948");
  });
});

describe("AnalyticsChart -- Export CSV (F7)", () => {
  afterEach(() => vi.mocked(downloadCsv).mockClear());

  it("downloads the wide CSV of the applied result, named with the site and the local dates", async () => {
    const applied = appliedQuery(
      [okSeries("a1", [1, null]), okSeries("a2", [], { status: "NO_DATA", status_reasons: ["NO_DATA_IN_RANGE"] })],
      ["a1", "a2"],
    );
    render(
      <AnalyticsChart applied={applied} catalog={catalogFixture()} timeZone="Asia/Kolkata" siteName="Radisson Blu" width={800} />,
    );
    const button = screen.getByTestId("analytics-chart-export-csv");
    expect(button).toBeEnabled();
    await userEvent.click(button);
    expect(downloadCsv).toHaveBeenCalledTimes(1);
    const [filename, csv] = vi.mocked(downloadCsv).mock.calls[0]!;
    expect(filename).toBe("Radisson_Blu_analytics_05-Oct-2026_to_05-Oct-2026.csv");
    expect(csv).toBe(
      "Timestamp local,Timestamp UTC,Energy-Asset a1 (kWh),Energy-Asset a2 (kWh)\r\n" +
        "2026-10-05 00:00,2026-10-04T18:30:00Z,1,\r\n" +
        "2026-10-05 00:15,2026-10-04T18:45:00Z,,\r\n",
    );
  });

  it("always the full applied range, never the zoomed window (D28)", async () => {
    const { container } = render(
      <AnalyticsChart applied={appliedQuery([okSeries("a1", [1, 2, 3, 4])], ["a1"])} catalog={catalogFixture()} timeZone="Asia/Kolkata" siteName="Coimbatore" width={800} />,
    );
    // The X axis spans the whole applied day (plot x 64..784), so the four
    // 15-minute buckets sit in its first ~30 px: drag across two of them.
    const wrapper = container.querySelector(".recharts-wrapper")!;
    fireEvent.mouseDown(wrapper, { clientX: 72, clientY: 100, pageX: 72, pageY: 100 });
    fireEvent.mouseMove(wrapper, { clientX: 80, clientY: 100, pageX: 80, pageY: 100 });
    fireEvent.mouseUp(wrapper, { clientX: 80, clientY: 100, pageX: 80, pageY: 100 });
    expect(screen.getByTestId("chart-show-all")).toBeInTheDocument();
    await userEvent.click(screen.getByTestId("analytics-chart-export-csv"));
    const csv = vi.mocked(downloadCsv).mock.calls[0]![1];
    expect(csv.trimEnd().split("\r\n").slice(1).map((r) => r.split(",")[2])).toEqual(["1", "2", "3", "4"]);
  });

  it("series hidden in the legend are still exported, with their full values (hiding is visual only)", async () => {
    render(
      <AnalyticsChart
        applied={appliedQuery([okSeries("a1", [1, 2]), okSeries("a2", [5, null])], ["a1", "a2"])}
        catalog={catalogFixture()}
        timeZone="Asia/Kolkata"
        siteName="Coimbatore"
        width={800}
      />,
    );
    await userEvent.click(within(screen.getByTestId("chart-legend")).getByRole("button", { name: "Asset a1-Energy" }));
    expect(document.querySelectorAll(".chart-frame__bar-series")).toHaveLength(1);
    await userEvent.click(screen.getByRole("button", { name: "Export CSV" }));
    expect(vi.mocked(downloadCsv).mock.calls[0]![1]).toBe(
      "Timestamp local,Timestamp UTC,Energy-Asset a1 (kWh),Energy-Asset a2 (kWh)\r\n" +
        "2026-10-05 00:00,2026-10-04T18:30:00Z,1,5\r\n" +
        "2026-10-05 00:15,2026-10-04T18:45:00Z,2,\r\n",
    );
  });

  it("disabled when nothing could be requested", () => {
    const applied = { ...appliedQuery([], ["a1"]), response: null };
    render(<AnalyticsChart applied={applied} catalog={catalogFixture()} timeZone="Asia/Kolkata" siteName="Coimbatore" width={800} />);
    expect(screen.getByTestId("analytics-chart-export-csv")).toBeDisabled();
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
    expect(within(screen.getByTestId("chart-legend")).getByText("Asset a1-Energy")).toBeInTheDocument();
    const firstChart = screen.getByTestId("multi-series-chart");

    // Change the draft and Update again: a new chart instance (zoom reset).
    await userEvent.click(within(points).getByRole("button", { name: /^Power/ }));
    await userEvent.click(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Energy Export" }));
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(screen.getByTestId("multi-series-chart")).not.toBe(firstChart));
  });
});

describe("Analytics page -- series colours across Updates", () => {
  const SITE_ID = SITES_ONE.sites[0]!.site_id;

  it("a series keeps its colour when another is added before it; chart and Statistics agree", async () => {
    let call = 0;
    const energy = okSeries("a1", [1, 2, 3, 4]);
    const energyExport = okSeries("a1", [4, 3, 2, 1], { data_point: "ENERGY_EXPORT", label: "Energy Export" });
    stubFetch((url) => {
      const parsed = new URL(url, "http://localhost");
      if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/catalog`)) return { jsonBody: catalogFixture({ site_id: SITE_ID }) };
      if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/series`)) {
        call += 1;
        return {
          jsonBody: seriesResponseFixture({
            site_id: SITE_ID,
            from: parsed.searchParams.get("from")!,
            to: parsed.searchParams.get("to")!,
            as_of: `2026-10-05T07:00:0${call}Z`,
            // The second response lists the new series FIRST.
            series: call === 1 ? [energy] : [energyExport, energy],
          }),
        };
      }
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await screen.findByTestId("analytics-filters");
    const assets = screen.getByTestId("asset-selector");
    await userEvent.click(within(assets).getByRole("button", { name: /^Unassigned/ }));
    await userEvent.click(within(assets).getByRole("checkbox", { name: "Asset a1" }));
    const points = screen.getByTestId("data-point-selector");
    await userEvent.click(within(points).getByRole("button", { name: /^Frequently Used/ }));
    await userEvent.click(within(points).getByRole("checkbox", { name: "Energy" }));
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(screen.getByTestId("analytics-chart")).toBeInTheDocument());

    const barFill = (name: string) => {
      const swatch = within(screen.getByTestId("chart-legend")).getByRole("button", { name }).querySelector("svg rect");
      return swatch?.getAttribute("fill");
    };
    const statsFill = (name: string) =>
      screen
        .getAllByTestId("analytics-statistics-row")
        .find((r) => within(r).getByRole("rowheader").textContent === name)!
        .querySelector("svg rect")!
        .getAttribute("fill");
    const energyColour = barFill("Asset a1-Energy");
    expect(statsFill("Energy-Asset a1")).toBe(energyColour);

    await userEvent.click(within(points).getByRole("button", { name: /^Power/ }));
    await userEvent.click(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Energy Export" }));
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(within(screen.getByTestId("chart-legend")).getAllByRole("button")).toHaveLength(2));

    expect(barFill("Asset a1-Energy")).toBe(energyColour);
    expect(barFill("Asset a1-Energy Export")).not.toBe(energyColour);
    expect(statsFill("Energy-Asset a1")).toBe(energyColour);
    expect(statsFill("Energy Export-Asset a1")).toBe(barFill("Asset a1-Energy Export"));
  });
});
