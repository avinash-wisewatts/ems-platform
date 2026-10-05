import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AnalyticsPage, NARROW_QUERY } from "./AnalyticsPage";
import { SITES_ONE, renderWithProviders, stubFetch } from "../../test-utils";
import { catalogFixture, seriesResponseFixture } from "./analyticsTestFixtures";

const SITE_ID = SITES_ONE.sites[0]!.site_id;

/** a1-a4: Plant Room / Chillers; a5-a8: Lobby / AHU; a9-a12 and x1: no Space, no Asset Type. */
function groupedCatalog() {
  const base = catalogFixture({ site_id: SITE_ID });
  return {
    ...base,
    assets: base.assets.map((asset, i) => {
      if (i < 4) return { ...asset, space_id: "s-plant", space_name: "Plant Room", asset_type_id: "t-ch", asset_type_name: "Chillers" };
      if (i < 8) return { ...asset, space_id: "s-lobby", space_name: "Lobby", asset_type_id: "t-ahu", asset_type_name: "AHU" };
      return asset;
    }),
  };
}

function stubAnalytics(catalog: () => unknown = groupedCatalog) {
  const seriesUrls: URL[] = [];
  stubFetch((url) => {
    const parsed = new URL(url, "http://localhost");
    if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/catalog`)) return { jsonBody: catalog() };
    if (parsed.pathname.endsWith(`/sites/${SITE_ID}/analytics/series`)) {
      seriesUrls.push(parsed);
      return { jsonBody: seriesResponseFixture({ site_id: SITE_ID }) };
    }
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
  return { seriesUrls };
}

async function renderPage() {
  renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
  return await screen.findByTestId("analytics-filters");
}

const assets = () => screen.getByTestId("asset-selector");
const dataPoints = () => screen.getByTestId("data-point-selector");
const groupButtons = (container: HTMLElement) =>
  within(container)
    .getAllByRole("button", { expanded: false })
    .map((b) => b.textContent);

async function openSection(title: RegExp) {
  await userEvent.click(within(screen.getByTestId("analytics-filters")).getByRole("button", { name: title, expanded: false }));
}

function mockMatchMedia(matches: boolean) {
  vi.stubGlobal(
    "matchMedia",
    vi.fn((query: string) => ({
      matches: query === NARROW_QUERY ? matches : false,
      media: query,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    })),
  );
}

describe("Analytics filter panel (F4)", () => {
  beforeEach(() => window.sessionStorage.clear());
  afterEach(() => vi.unstubAllGlobals());

  it("shows the controls in the D36 order, each as a row with its current choice", async () => {
    stubAnalytics();
    const panel = await renderPage();
    const order = [...panel.querySelectorAll("[data-testid]")]
      .map((el) => el.getAttribute("data-testid"))
      .filter((id) => id === "analytics-update" || id?.startsWith("filter-section-"));
    expect(order).toEqual([
      "analytics-update",
      "filter-section-assets",
      "filter-section-data-points",
      "filter-section-resolution",
      "filter-section-phase-type",
      "filter-section-comparison",
    ]);
    // Assets and Data points open; Resolution and Phase type collapsed, showing their values.
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("None");
    expect(screen.getByTestId("data-point-selected-count")).toHaveTextContent("None");
    expect(screen.getByTestId("resolution-summary")).toHaveTextContent("Auto");
    expect(screen.getByTestId("phase-type-summary")).toHaveTextContent("System");
    expect(screen.queryByTestId("resolution-selector")).not.toBeInTheDocument();
  });

  it("the date range is above the panel and separate from it", async () => {
    stubAnalytics();
    const panel = await renderPage();
    const toolbar = screen.getByTestId("analytics-toolbar");
    expect(panel.contains(toolbar)).toBe(false);
    expect(within(toolbar).getByTestId("analytics-date-range")).toBeInTheDocument();
    expect(toolbar.compareDocumentPosition(panel) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("Assets: Group by Space by default, groups collapsed, Unassigned last; Group by Asset Type puts Other last (D38, D71, D72)", async () => {
    stubAnalytics();
    await renderPage();
    expect(within(assets()).getByRole("radio", { name: "Group by Space" })).toBeChecked();
    expect(groupButtons(assets())).toEqual(["Lobby4", "Plant Room4", "Unassigned5"]);
    expect(within(assets()).queryByRole("checkbox", { name: "Asset a1" })).not.toBeInTheDocument();

    await userEvent.click(within(assets()).getByRole("radio", { name: "Group by Asset Type" }));
    expect(groupButtons(assets())).toEqual(["AHU4", "Chillers4", "Other5"]);
  });

  it("Assets: a group opens on click; the row shows the choice; selections survive regrouping", async () => {
    stubAnalytics();
    await renderPage();
    await userEvent.click(within(assets()).getByRole("button", { name: /^Plant Room/ }));
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Asset a2" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("Asset a2");
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Asset a3" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("2 of 13");
    await userEvent.click(within(assets()).getByRole("radio", { name: "Group by Asset Type" }));
    await userEvent.click(within(assets()).getByRole("button", { name: /^Chillers/ }));
    expect(within(assets()).getByRole("checkbox", { name: "Asset a2" })).toBeChecked();
  });

  it("Assets: group selection fills in visual order up to 10, then the limit message and locked checkboxes (D44, D65)", async () => {
    stubAnalytics();
    await renderPage();
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Select group Unassigned" }));
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Select group Plant Room" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("9 of 13");
    expect(screen.queryByTestId("asset-limit-reached")).not.toBeInTheDocument();

    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Select group Lobby" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("10 of 13");
    expect(screen.getByTestId("asset-limit-reached")).toHaveTextContent("You can select up to 10 assets.");
    await userEvent.click(within(assets()).getByRole("button", { name: /^Lobby/ }));
    // Lobby's first asset by name was added; the rest stay unselected and locked.
    expect(within(assets()).getByRole("checkbox", { name: "Asset a5" })).toBeChecked();
    expect(within(assets()).getByRole("checkbox", { name: "Asset a6" })).toBeDisabled();
    expect(within(assets()).getByRole("checkbox", { name: "Select group Lobby" })).toHaveProperty("indeterminate", true);

    await userEvent.click(within(assets()).getByRole("button", { name: "Clear All" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("None");
  });

  it("Assets: Select All takes the first 10 in visual order; search narrows the list", async () => {
    stubAnalytics();
    await renderPage();
    await userEvent.click(within(assets()).getByRole("button", { name: "Select All" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("10 of 13");
    await userEvent.click(within(assets()).getByRole("button", { name: /^Unassigned/ }));
    // Lobby (4) + Plant Room (4) + the first two Unassigned by name.
    expect(within(assets()).getByRole("checkbox", { name: "Asset a10" })).toBeChecked();
    expect(within(assets()).getByRole("checkbox", { name: "Asset a11" })).not.toBeChecked();

    await userEvent.type(within(assets()).getByRole("searchbox", { name: "Search assets" }), "x1");
    expect(within(assets()).getAllByRole("button", { expanded: true }).map((b) => b.textContent)).toEqual(["Unassigned1"]);
  });

  it("Data points: the approved groups, no group checkboxes, the same point in two groups is one selection (D39, D40, D67)", async () => {
    stubAnalytics();
    await renderPage();
    expect(groupButtons(dataPoints())).toEqual(["Frequently Used1", "Power2"]);
    expect(within(dataPoints()).queryAllByRole("checkbox")).toHaveLength(0);

    await userEvent.click(within(dataPoints()).getByRole("button", { name: /^Frequently Used/ }));
    await userEvent.click(within(dataPoints()).getByRole("button", { name: /^Power/ }));
    expect(within(dataPoints()).queryByRole("checkbox", { name: /Select group/ })).not.toBeInTheDocument();
    await userEvent.click(within(screen.getByTestId("data-point-group-Frequently Used")).getByRole("checkbox", { name: "Energy" }));
    expect(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Energy" })).toBeChecked();
    expect(screen.getByTestId("data-point-selected-count")).toHaveTextContent("Energy");
  });

  it("Resolution: options the range cannot use are disabled; a chosen one the new range cannot use switches to Auto with the notice (D9, D68)", async () => {
    stubAnalytics();
    await renderPage();
    await openSection(/^Resolution/);
    const resolution = () => screen.getByTestId("resolution-selector");
    expect(within(resolution()).getAllByRole("radio").map((r) => r.parentElement?.textContent)).toEqual([
      "Auto",
      "1 minute",
      "15 minutes",
      "30 minutes",
      "1 hour",
      "1 day",
    ]);
    await userEvent.click(within(resolution()).getByRole("radio", { name: "1 minute" }));
    expect(screen.getByTestId("resolution-summary")).toHaveTextContent("1 minute");

    await userEvent.click(screen.getByRole("button", { name: /From.*To/ }));
    const dialog = screen.getByRole("dialog", { name: "Date range" });
    await userEvent.click(within(dialog).getByRole("button", { name: "1 Year" }));
    await userEvent.click(within(dialog).getByRole("button", { name: "Apply" }));

    expect(within(resolution()).getByRole("radio", { name: "Auto" })).toBeChecked();
    expect(screen.getByTestId("resolution-summary")).toHaveTextContent("Auto");
    expect(screen.getByTestId("analytics-resolution-notice")).toHaveTextContent(
      "Resolution changed to Auto because the selected resolution is not available for this range.",
    );
    expect(within(resolution()).getByRole("radio", { name: "1 minute" })).toBeDisabled();
    expect(within(resolution()).getByRole("radio", { name: "1 hour" })).toBeDisabled();
    expect(within(resolution()).getByRole("radio", { name: "1 day" })).toBeEnabled();
    expect(screen.getByTestId("analytics-changes-not-applied")).toBeInTheDocument();
  });

  it("Phase type is System or 3 Phase; Comparison is a disabled placeholder (D52, D53)", async () => {
    stubAnalytics();
    await renderPage();
    await openSection(/^Phase type/);
    const phase = screen.getByTestId("phase-type-selector");
    expect(within(phase).getByRole("radio", { name: "System" })).toBeChecked();
    await userEvent.click(within(phase).getByRole("radio", { name: "3 Phase" }));
    expect(within(phase).getByRole("radio", { name: "3 Phase" })).toBeChecked();
    expect(screen.getByTestId("phase-type-summary")).toHaveTextContent("3 Phase");
    const comparison = screen.getByTestId("comparison-placeholder");
    expect(comparison).toBeDisabled();
    expect(comparison).toHaveTextContent("Coming soon");
  });

  it("selections made in the panel are sent on Update (F2, F3)", async () => {
    const { seriesUrls } = stubAnalytics();
    await renderPage();
    await userEvent.click(within(assets()).getByRole("button", { name: /^Plant Room/ }));
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Asset a1" }));
    await userEvent.click(within(dataPoints()).getByRole("button", { name: /^Power/ }));
    await userEvent.click(within(dataPoints()).getByRole("checkbox", { name: "Energy Export" }));
    await userEvent.click(screen.getByTestId("analytics-update"));
    await waitFor(() => expect(seriesUrls).toHaveLength(1));
    expect(seriesUrls[0]!.searchParams.getAll("selection")).toEqual(["a1:ENERGY_EXPORT"]);
    await waitFor(() => expect(screen.getByTestId("analytics-result")).toBeInTheDocument());
  });

  it("Hide Filters and Show Filters (D33, D34)", async () => {
    stubAnalytics();
    await renderPage();
    await userEvent.click(screen.getByRole("button", { name: "Hide Filters" }));
    expect(screen.queryByTestId("analytics-filters")).not.toBeInTheDocument();
    expect(screen.getByTestId("analytics-date-range")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Show Filters" }));
    expect(screen.getByTestId("analytics-filters")).not.toHaveAttribute("role");
  });

  it("narrow screens: the filters are a drawer opened with Show Filters (D82)", async () => {
    mockMatchMedia(true);
    stubAnalytics();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await userEvent.click(await screen.findByRole("button", { name: "Show Filters" }));
    const drawer = screen.getByRole("dialog", { name: "Filters" });
    expect(drawer).toHaveAttribute("aria-modal", "true");
    await userEvent.click(within(drawer).getByRole("button", { name: "Hide Filters" }));
    expect(screen.queryByRole("dialog", { name: "Filters" })).not.toBeInTheDocument();
  });
});

/** A site whose catalogue has 13 data points over three assets, as a larger
 *  registry would return: a1 electrical, a2 environmental, a3 one code with no
 *  D67 item. */
function fullCatalog() {
  const base = catalogFixture({ site_id: SITE_ID });
  const point = (data_point: string, label: string) => ({ ...base.assets[0]!.data_points[0]!, data_point, label });
  const electrical = [
    ["CURRENT", "Current"],
    ["ENERGY_IMPORT", "Energy"],
    ["ENERGY_EXPORT", "Energy Export"],
    ["POWER_FACTOR", "Power Factor"],
    ["VOLTAGE_LINE_NEUTRAL", "Voltage (Line-Neutral)"],
    ["APPARENT_POWER", "Apparent Power"],
    ["FREQUENCY", "Frequency"],
    ["REACTIVE_POWER", "Reactive Power"],
  ].map(([c, l]) => point(c!, l!));
  const environmental = [
    ["TEMPERATURE", "Temperature"],
    ["HUMIDITY", "Relative Humidity"],
    ["ILLUMINANCE", "Illuminance"],
    ["BATTERY_VOLTAGE", "Battery Voltage"],
  ].map(([c, l]) => point(c!, l!));
  return {
    ...base,
    assets: [
      { ...base.assets[0]!, data_points: electrical },
      { ...base.assets[1]!, data_points: environmental },
      { ...base.assets[2]!, data_points: [point("DEW_POINT", "Dew Point")] },
    ],
  };
}

describe("Data points: the full site catalogue (D40, D42, D66, D67)", () => {
  beforeEach(() => window.sessionStorage.clear());

  const GROUPS = ["Frequently Used", "Power", "Environmental", "Misc/Other"];
  const expandAll = async () => {
    for (const name of GROUPS) {
      const button = within(dataPoints())
        .getAllByRole("button", { expanded: false })
        .find((b) => b.textContent?.startsWith(name));
      await userEvent.click(button!);
    }
  };
  const labelsIn = (group: string) =>
    within(screen.getByTestId(`data-point-group-${group}`))
      .getAllByRole("checkbox")
      .map((c) => c.parentElement?.textContent);

  it("renders every catalogue group and point; Frequently Used is the fixed list", async () => {
    stubAnalytics(fullCatalog);
    await renderPage();
    expect(groupButtons(dataPoints())).toEqual(["Frequently Used4", "Power5", "Environmental3", "Misc/Other2"]);
    await expandAll();
    expect(labelsIn("Frequently Used")).toEqual(["Current", "Energy", "Power Factor", "Voltage (Line-Neutral)"]);
    expect(labelsIn("Power")).toEqual(["Apparent Power", "Energy", "Energy Export", "Frequency", "Reactive Power"]);
    expect(labelsIn("Environmental")).toEqual(["Illuminance", "Relative Humidity", "Temperature"]);
    expect(labelsIn("Misc/Other")).toEqual(["Battery Voltage", "Dew Point"]);
    expect(within(dataPoints()).queryAllByRole("checkbox", { name: /Select group/ })).toHaveLength(0);
  });

  it("the list does not depend on the selected assets", async () => {
    stubAnalytics(fullCatalog);
    await renderPage();
    await userEvent.click(within(assets()).getByRole("button", { name: /^Unassigned/ }));
    await userEvent.click(within(assets()).getByRole("checkbox", { name: "Asset a3" }));
    expect(screen.getByTestId("asset-selected-count")).toHaveTextContent("Asset a3");
    expect(groupButtons(dataPoints())).toEqual(["Frequently Used4", "Power5", "Environmental3", "Misc/Other2"]);
  });

  it("Select All fills 5 in visual order and locks the rest; Clear All clears (D5, D66)", async () => {
    stubAnalytics(fullCatalog);
    await renderPage();
    await userEvent.click(within(dataPoints()).getByRole("button", { name: "Select All" }));
    expect(screen.getByTestId("data-point-selected-count")).toHaveTextContent("5 data points");
    expect(screen.getByTestId("data-point-limit-reached")).toHaveTextContent("You can select up to 5 data points.");
    await expandAll();
    // Frequently Used (4), then the first point of Power not already selected.
    const checked = within(dataPoints())
      .getAllByRole("checkbox", { checked: true })
      .map((c) => c.parentElement?.textContent);
    expect(new Set(checked)).toEqual(new Set(["Current", "Energy", "Power Factor", "Voltage (Line-Neutral)", "Apparent Power"]));
    expect(within(screen.getByTestId("data-point-group-Environmental")).getByRole("checkbox", { name: "Temperature" })).toBeDisabled();

    await userEvent.click(within(dataPoints()).getByRole("button", { name: "Clear All" }));
    expect(screen.getByTestId("data-point-selected-count")).toHaveTextContent("None");
    expect(within(screen.getByTestId("data-point-group-Environmental")).getByRole("checkbox", { name: "Temperature" })).toBeEnabled();
  });

  it("the limit also holds for individual selections, and unselecting frees a slot", async () => {
    stubAnalytics(fullCatalog);
    await renderPage();
    await expandAll();
    for (const label of ["Current", "Power Factor", "Frequency", "Temperature", "Dew Point"]) {
      await userEvent.click(within(dataPoints()).getAllByRole("checkbox", { name: label })[0]!);
    }
    expect(screen.getByTestId("data-point-selected-count")).toHaveTextContent("5 data points");
    expect(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Reactive Power" })).toBeDisabled();
    await userEvent.click(within(dataPoints()).getAllByRole("checkbox", { name: "Current" })[0]!);
    expect(within(screen.getByTestId("data-point-group-Power")).getByRole("checkbox", { name: "Reactive Power" })).toBeEnabled();
    expect(screen.queryByTestId("data-point-limit-reached")).not.toBeInTheDocument();
  });
});

describe("narrow-screen drawer", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("takes focus when opened and closes on Escape", async () => {
    mockMatchMedia(true);
    stubAnalytics();
    renderWithProviders(<AnalyticsPage />, { sites: () => Promise.resolve(SITES_ONE) });
    await userEvent.click(await screen.findByRole("button", { name: "Show Filters" }));
    const drawer = screen.getByRole("dialog", { name: "Filters" });
    expect(within(drawer).getByRole("button", { name: "Hide Filters" })).toHaveFocus();
    await userEvent.keyboard("{Escape}");
    expect(screen.queryByRole("dialog", { name: "Filters" })).not.toBeInTheDocument();
  });
});
