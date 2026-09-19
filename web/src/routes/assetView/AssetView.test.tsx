import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AssetView } from "./AssetView";
import { renderWithProviders, stubFetch, SITES_ONE } from "../../test-utils";
import type {
  AssetCurrentDemandResponse,
  AssetDemandSeriesResponse,
  AssetEnergyIntervalsResponse,
  AssetLivePoint,
  AssetLiveStateResponse,
  AssetPowerTrendResponse,
  AssetSummary,
  DemandIntervalPoint,
} from "../../api/types";

const SITE_ID = SITES_ONE.sites[0]!.site_id;
// SITES_ONE (test-utils.tsx) is Alpha One / Org A, timezone Asia/Kolkata
// (UTC+5:30) -- used throughout to prove Asset View renders in the SITE's
// timezone, not the test runner's local/UTC zone.
const ASSET_ID = "11111111-1111-4111-8111-000000000001";
const OTHER_ASSET_ID = "22222222-2222-4222-8222-000000000002";
const EXPECTED_WS_ORIGIN = `ws://${window.location.host}`;

function asset(overrides: Partial<AssetSummary> = {}): AssetSummary {
  return {
    asset_id: ASSET_ID,
    site_id: SITE_ID,
    space_id: null,
    parent_asset_id: null,
    external_id: "AHU-01",
    asset_name: "AHU 01",
    lifecycle_status: "ACTIVE",
    asset_type_id: "type-ahu",
    asset_type_name: "AHU",
    parent_asset_name: null,
    building_id: "b1",
    building_name: "Tower A",
    floor_id: "f1",
    floor_name: "Floor 2",
    space_name: "Lobby",
    location_path: "Tower A / Floor 2 / Lobby",
    ...overrides,
  };
}

function otherAsset(overrides: Partial<AssetSummary> = {}): AssetSummary {
  return asset({
    asset_id: OTHER_ASSET_ID,
    asset_name: "Chiller 2",
    external_id: "CH-02",
    asset_type_name: "Chiller",
    ...overrides,
  });
}

function livePoint(overrides: Partial<AssetLivePoint> = {}): AssetLivePoint {
  return {
    device_id: "d1",
    device_name: "Meter 1",
    relationship_type: "PRIMARY_METER",
    logical_point: "ACTIVE_POWER_TOTAL",
    unit_symbol: "kW",
    numeric_value: 100,
    text_value: null,
    event_time: "2026-09-17T12:00:00Z",
    received_at: "2026-09-17T12:00:00Z",
    freshness_state: "LIVE",
    quality_code: "GOOD",
    ...overrides,
  };
}

function liveState(points: AssetLivePoint[], assetId = ASSET_ID): AssetLiveStateResponse {
  return { asset_id: assetId, points };
}

function emptyEnergyResponse(assetId = ASSET_ID): AssetEnergyIntervalsResponse {
  return { asset_id: assetId, from: "2026-09-16T12:00:00Z", to: "2026-09-17T12:00:00Z", no_data: true, series: [] };
}

function energyResponse(
  kwh: number,
  overrides: Partial<{ resetDetected: boolean; gapDetected: boolean }> = {},
  assetId = ASSET_ID,
): AssetEnergyIntervalsResponse {
  return {
    asset_id: assetId,
    from: "2026-09-16T12:00:00Z",
    to: "2026-09-17T12:00:00Z",
    no_data: false,
    series: [
      {
        interval_start: "2026-09-17T00:00:00Z",
        device_id: "d1",
        device_name: "Meter 1",
        elapsed_minutes: 60,
        import_consumption_kwh: kwh,
        export_consumption_kwh: null,
        import_quality_code: "GOOD",
        export_quality_code: null,
        reset_detected: overrides.resetDetected ?? false,
        gap_detected: overrides.gapDetected ?? false,
      },
    ],
  };
}

function demandInterval(overrides: Partial<DemandIntervalPoint> = {}): DemandIntervalPoint {
  return {
    interval_start: "2026-09-17T11:00:00Z",
    interval_end: "2026-09-17T11:15:00Z",
    demand_kw: 50,
    peak_power_kw: 50,
    quality_status: "PROVISIONAL",
    coverage_percent: 100,
    ...overrides,
  };
}

function emptyDemandSeries(assetId = ASSET_ID): AssetDemandSeriesResponse {
  return { asset_id: assetId, from: "2026-09-16T12:00:00Z", to: "2026-09-17T12:00:00Z", no_data: true, series: [] };
}

function emptyCurrentDemand(assetId = ASSET_ID): AssetCurrentDemandResponse {
  return {
    asset_id: assetId,
    has_data: false,
    interval_start: null,
    interval_end: null,
    current_demand_kw: null,
    current_demand_kva: null,
    quality_status: null,
    coverage_percent: null,
  };
}

function emptyPowerTrend(assetId = ASSET_ID): AssetPowerTrendResponse {
  return { asset_id: assetId, from: "2026-09-16T12:00:00Z", to: "2026-09-17T12:00:00Z", no_data: true, series: [] };
}

class MockWebSocket {
  static instances: MockWebSocket[] = [];
  static OPEN = 1;
  static CLOSED = 3;

  url: string;
  readyState = 0;
  onopen: ((ev: Event) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;
  closeCalls: Array<{ code?: number; reason?: string }> = [];

  constructor(url: string) {
    this.url = url;
    MockWebSocket.instances.push(this);
  }

  simulateOpen(): void {
    this.readyState = MockWebSocket.OPEN;
    this.onopen?.(new Event("open"));
  }

  simulateMessage(data: string): void {
    this.onmessage?.({ data } as MessageEvent);
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason });
    this.readyState = MockWebSocket.CLOSED;
  }

  send(_data: string): void {}
}

type FetchOpts = {
  assets?: AssetSummary[];
  live?: AssetLiveStateResponse | (() => AssetLiveStateResponse) | "error";
  energy?: AssetEnergyIntervalsResponse;
  demandCurrent?: AssetCurrentDemandResponse | "error";
  demandSeries?: AssetDemandSeriesResponse | "error";
  powerTrend?: AssetPowerTrendResponse | "error";
};

function stubAssetViewFetch(opts: FetchOpts = {}) {
  const assets = opts.assets ?? [asset()];
  const energy = opts.energy ?? emptyEnergyResponse();
  const powerTrend = opts.powerTrend ?? emptyPowerTrend();
  return stubFetch((url) => {
    if (url.includes("/live-state")) {
      if (opts.live === "error") return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
      const body = typeof opts.live === "function" ? opts.live() : (opts.live ?? liveState([]));
      return { jsonBody: body };
    }
    if (url.includes("/energy/consumption")) return { jsonBody: energy };
    if (url.includes("/demand/current")) {
      if (opts.demandCurrent === "error") return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
      return { jsonBody: opts.demandCurrent ?? emptyCurrentDemand() };
    }
    if (url.includes("/demand")) {
      if (opts.demandSeries === "error") return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
      return { jsonBody: opts.demandSeries ?? emptyDemandSeries() };
    }
    if (url.includes("/power-trend")) {
      if (opts.powerTrend === "error") return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
      return { jsonBody: powerTrend };
    }
    if (url.includes("/assets")) return { jsonBody: { site_id: SITE_ID, assets } };
    return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
  });
}

async function selectAsset(assetId = ASSET_ID) {
  const user = userEvent.setup();
  await waitFor(() => expect(screen.getByTestId("filter-asset")).not.toBeDisabled());
  await user.selectOptions(screen.getByTestId("filter-asset"), assetId);
}

beforeEach(() => {
  MockWebSocket.instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
});

describe("AssetView", () => {
  describe("no asset selected", () => {
    it("shows a simple 'Select an asset' empty state and no WebSocket connection", async () => {
      stubAssetViewFetch();
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByText("Select an asset")).toBeTruthy());
      expect(MockWebSocket.instances).toHaveLength(0);
    });

    it("renders no KPI tiles and no charts", async () => {
      stubAssetViewFetch();
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await waitFor(() => expect(screen.getByText("Select an asset")).toBeTruthy());

      for (const testId of [
        "asset-view-kpis",
        "asset-energy-tile",
        "asset-demand-tile",
        "asset-power-trend",
        "asset-demand-chart",
        "live-param-active_power",
      ]) {
        expect(screen.queryByTestId(testId)).toBeNull();
      }
    });
  });

  it("shows the selected asset's name as the breadcrumb leaf, not a hardcoded label", async () => {
    stubAssetViewFetch();
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() => expect(screen.getByTestId("hierarchy-crumb-leaf")).toHaveTextContent("Asset View"));

    await selectAsset();

    await waitFor(() => expect(screen.getByTestId("hierarchy-crumb-leaf")).toHaveTextContent("AHU 01"));
  });

  it("breadcrumb shows Organisation -> Site -> Asset, using the real organization_name, even for a single-site user", async () => {
    stubAssetViewFetch();
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await waitFor(() =>
      expect(screen.getByTestId("hierarchy-crumb-portfolio")).toHaveTextContent(SITES_ONE.sites[0]!.organization_name),
    );
    expect(screen.getByTestId("hierarchy-crumb")).toHaveTextContent(SITES_ONE.sites[0]!.site_name);

    await selectAsset();

    const crumb = screen.getByTestId("hierarchy-crumb");
    expect(crumb).toHaveTextContent(SITES_ONE.sites[0]!.organization_name);
    expect(crumb).toHaveTextContent(SITES_ONE.sites[0]!.site_name);
    expect(crumb).toHaveTextContent("AHU 01");
  });

  it("fetches the REST snapshot, opens a WebSocket to the correct asset URL, and renders the snapshot", async () => {
    const fetchMock = stubAssetViewFetch({
      live: liveState([livePoint({ numeric_value: 100 })]),
      energy: energyResponse(500),
    });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();

    await waitFor(() => expect(MockWebSocket.instances).toHaveLength(1));
    expect(MockWebSocket.instances[0]!.url).toBe(`${EXPECTED_WS_ORIGIN}/api/live/assets/${ASSET_ID}/ws`);

    await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("100.00"));
    expect(screen.getByTestId("asset-energy-tile")).toHaveTextContent("500");

    const liveStateCalls = fetchMock.mock.calls.filter((c) => String(c[0]).includes("/live-state"));
    expect(liveStateCalls).toHaveLength(1);
  });

  it("applies a WebSocket telemetry update without any additional REST fetch (no polling)", async () => {
    const fetchMock = stubAssetViewFetch({ live: liveState([livePoint({ numeric_value: 100 })]) });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();
    await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("100.00"));

    act(() => MockWebSocket.instances[0]!.simulateOpen());
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({
          type: "telemetry",
          asset_id: ASSET_ID,
          points: [livePoint({ numeric_value: 250 })],
        }),
      ),
    );

    await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("250.00"));

    const liveStateCalls = fetchMock.mock.calls.filter((c) => String(c[0]).includes("/live-state"));
    expect(liveStateCalls).toHaveLength(1);
  });

  it("regression: a REST snapshot resolving after live telemetry must not overwrite it", async () => {
    let resolveLiveState: (body: AssetLiveStateResponse) => void = () => {};
    const pendingLiveState = new Promise<AssetLiveStateResponse>((resolve) => {
      resolveLiveState = resolve;
    });

    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input.toString();
      const jsonResponse = (body: unknown) =>
        ({
          ok: true,
          status: 200,
          statusText: "",
          headers: new Headers(),
          json: async () => body,
          text: async () => JSON.stringify(body),
        }) as unknown as Response;

      if (url.includes("/live-state")) {
        const body = await pendingLiveState;
        return jsonResponse(body);
      }
      if (url.includes("/energy/consumption")) return jsonResponse(emptyEnergyResponse());
      if (url.includes("/demand/current")) return jsonResponse(emptyCurrentDemand());
      if (url.includes("/demand")) return jsonResponse(emptyDemandSeries());
      if (url.includes("/power-trend")) return jsonResponse(emptyPowerTrend());
      if (url.includes("/assets")) return jsonResponse({ site_id: SITE_ID, assets: [asset()] });
      return jsonResponse({ error: "not_found", detail: "unexpected" });
    });
    vi.stubGlobal("fetch", fetchMock);

    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
    await selectAsset();

    await waitFor(() => expect(MockWebSocket.instances).toHaveLength(1));
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({
          type: "telemetry",
          asset_id: ASSET_ID,
          points: [livePoint({ numeric_value: 999 })],
        }),
      ),
    );
    await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("999.00"));

    // The initial REST snapshot only resolves now, with a now-stale reading.
    await act(async () => {
      resolveLiveState(liveState([livePoint({ numeric_value: 1 })]));
      await pendingLiveState;
    });

    // Fresher WebSocket value must still be displayed, not regressed.
    expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("999.00");
  });

  it("switching the selected asset closes the previous socket, resets stale values, and reconnects to the new asset", async () => {
    stubAssetViewFetch({
      assets: [asset(), otherAsset()],
      live: () => liveState([livePoint({ numeric_value: 100 })], ASSET_ID),
    });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset(ASSET_ID);
    await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("100.00"));
    const firstSocket = MockWebSocket.instances[0]!;

    const user = userEvent.setup();
    await user.selectOptions(screen.getByTestId("filter-asset"), OTHER_ASSET_ID);

    expect(firstSocket.closeCalls.length).toBeGreaterThan(0);
    await waitFor(() => expect(MockWebSocket.instances).toHaveLength(2));
    expect(MockWebSocket.instances[1]!.url).toBe(`${EXPECTED_WS_ORIGIN}/api/live/assets/${OTHER_ASSET_ID}/ws`);
    expect(screen.getByTestId("asset-detail-meta")).toHaveTextContent("Chiller");
  });

  it("closes the WebSocket on unmount", async () => {
    stubAssetViewFetch({ live: liveState([livePoint()]) });
    const { unmount } = renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();
    await waitFor(() => expect(MockWebSocket.instances).toHaveLength(1));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    unmount();

    expect(MockWebSocket.instances[0]!.closeCalls.length).toBeGreaterThan(0);
  });

  it("shows an error state when the initial snapshot fails and no live data has arrived, with a working retry", async () => {
    let attempt = 0;
    stubFetch((url) => {
      if (url.includes("/live-state")) {
        attempt += 1;
        if (attempt === 1) return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
        return { jsonBody: liveState([livePoint({ numeric_value: 42 })]) };
      }
      if (url.includes("/energy/consumption")) return { jsonBody: emptyEnergyResponse() };
      if (url.includes("/demand/current")) return { jsonBody: emptyCurrentDemand() };
      if (url.includes("/demand")) return { jsonBody: emptyDemandSeries() };
      if (url.includes("/power-trend")) return { jsonBody: emptyPowerTrend() };
      if (url.includes("/assets")) return { jsonBody: { site_id: SITE_ID, assets: [asset()] } };
      return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
    });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();

    const tile = await screen.findByTestId("live-param-active_power");
    await waitFor(() => expect(within(tile).getByTestId("state-error")).toBeTruthy());

    const user = userEvent.setup();
    await user.click(within(tile).getByRole("button", { name: "Try again" }));

    await waitFor(() => expect(within(tile).getByText("42.00")).toBeTruthy());
  });

  it("a live telemetry delivery overrides an initial-snapshot failure (no dishonest error once real data arrives)", async () => {
    stubAssetViewFetch({ live: "error" });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();
    const tile = await screen.findByTestId("live-param-active_power");
    await waitFor(() => expect(within(tile).getByTestId("state-error")).toBeTruthy());

    await waitFor(() => expect(MockWebSocket.instances).toHaveLength(1));
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "snapshot", asset_id: ASSET_ID, points: [livePoint({ numeric_value: 7 })] }),
      ),
    );

    await waitFor(() => expect(within(tile).queryByTestId("state-error")).toBeNull());
    expect(within(tile).getByText("7.00")).toBeTruthy();
  });

  describe("parameter-specific phase labels and unit placement", () => {
    it("labels Power phases P1/P2/P3, not L1/L2/L3", async () => {
      stubAssetViewFetch({
        live: liveState([
          livePoint({ logical_point: "ACTIVE_POWER_TOTAL", numeric_value: 100 }),
          livePoint({ logical_point: "ACTIVE_POWER_L1", numeric_value: 33 }),
          livePoint({ logical_point: "ACTIVE_POWER_L2", numeric_value: 34 }),
          livePoint({ logical_point: "ACTIVE_POWER_L3", numeric_value: 35 }),
        ]),
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      const tile = await screen.findByTestId("live-param-active_power");
      await waitFor(() => expect(tile).toHaveTextContent("100.00"));
      expect(within(tile).getByText("P1")).toBeTruthy();
      expect(within(tile).getByText("P2")).toBeTruthy();
      expect(within(tile).getByText("P3")).toBeTruthy();
      expect(within(tile).queryByText("L1")).toBeNull();
      expect(within(tile).queryByText("L2")).toBeNull();
      expect(within(tile).queryByText("L3")).toBeNull();
    });

    it("uses parameter-specific phase labels for Voltage, Current, Power Factor, and Current THD -- never a generic P1/P2/P3 for all of them", async () => {
      stubAssetViewFetch({
        live: liveState([
          livePoint({ logical_point: "VOLTAGE_LN_AVG", numeric_value: 230 }),
          livePoint({ logical_point: "VOLTAGE_L1", numeric_value: 229 }),
          livePoint({ logical_point: "VOLTAGE_L2", numeric_value: 231 }),
          livePoint({ logical_point: "VOLTAGE_L3", numeric_value: 230 }),
          livePoint({ logical_point: "CURRENT_TOTAL", numeric_value: 10 }),
          livePoint({ logical_point: "CURRENT_L1", numeric_value: 3 }),
          livePoint({ logical_point: "CURRENT_L2", numeric_value: 3 }),
          livePoint({ logical_point: "CURRENT_L3", numeric_value: 4 }),
          livePoint({ logical_point: "POWER_FACTOR_TOTAL", numeric_value: 0.95 }),
          livePoint({ logical_point: "POWER_FACTOR_L1", numeric_value: 0.94 }),
          livePoint({ logical_point: "POWER_FACTOR_L2", numeric_value: 0.95 }),
          livePoint({ logical_point: "POWER_FACTOR_L3", numeric_value: 0.96 }),
          livePoint({ logical_point: "CURRENT_THD_TOTAL", numeric_value: 2 }),
          livePoint({ logical_point: "CURRENT_THD_L1", numeric_value: 1.8 }),
          livePoint({ logical_point: "CURRENT_THD_L2", numeric_value: 2.1 }),
          livePoint({ logical_point: "CURRENT_THD_L3", numeric_value: 2.0 }),
        ]),
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      const voltageTile = await screen.findByTestId("live-param-voltage");
      await waitFor(() => expect(voltageTile).toHaveTextContent("230.00"));
      expect(within(voltageTile).getByText("V1")).toBeTruthy();
      expect(within(voltageTile).getByText("V2")).toBeTruthy();
      expect(within(voltageTile).getByText("V3")).toBeTruthy();

      const currentTile = screen.getByTestId("live-param-current");
      expect(within(currentTile).getByText("I1")).toBeTruthy();
      expect(within(currentTile).getByText("I2")).toBeTruthy();
      expect(within(currentTile).getByText("I3")).toBeTruthy();

      const pfTile = screen.getByTestId("live-param-power_factor");
      expect(within(pfTile).getByText("PF1")).toBeTruthy();
      expect(within(pfTile).getByText("PF2")).toBeTruthy();
      expect(within(pfTile).getByText("PF3")).toBeTruthy();

      const thdTile = screen.getByTestId("live-param-current_thd");
      expect(within(thdTile).getByText("I-THD1")).toBeTruthy();
      expect(within(thdTile).getByText("I-THD2")).toBeTruthy();
      expect(within(thdTile).getByText("I-THD3")).toBeTruthy();

      // None of the non-Power tiles use the generic P1/P2/P3.
      for (const tile of [voltageTile, currentTile, pfTile, thdTile]) {
        expect(within(tile).queryByText("P1")).toBeNull();
        expect(within(tile).queryByText("P2")).toBeNull();
        expect(within(tile).queryByText("P3")).toBeNull();
      }
    });

    it("states the unit once in the tile heading, not repeated beside each reading", async () => {
      stubAssetViewFetch({
        live: liveState([
          livePoint({ logical_point: "ACTIVE_POWER_TOTAL", numeric_value: 100 }),
          livePoint({ logical_point: "ACTIVE_POWER_L1", numeric_value: 33.3 }),
        ]),
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      const tile = await screen.findByTestId("live-param-active_power");
      await waitFor(() => expect(tile).toHaveTextContent("Power (kW)"));
      // The value itself carries no unit suffix.
      expect(within(tile).getByText("100.00")).toBeTruthy();
      expect(within(tile).queryByText("100.00 kW")).toBeNull();
      expect(within(tile).queryByText(/kW$/)).toBeNull();
    });
  });

  describe("conditional measurement visibility", () => {
    it("hides a live-parameter tile with no evidence the asset reports it, once ready", async () => {
      stubAssetViewFetch({ live: liveState([livePoint({ logical_point: "ACTIVE_POWER_TOTAL" })]) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toBeTruthy());
      expect(screen.queryByTestId("live-param-voltage")).toBeNull();
      expect(screen.queryByTestId("live-param-current")).toBeNull();
      expect(screen.queryByTestId("live-param-power_factor")).toBeNull();
      expect(screen.queryByTestId("live-param-current_thd")).toBeNull();
    });

    it("keeps a tile visible when its point has been observed even though the current reading is null (temporarily stale), not hidden", async () => {
      stubAssetViewFetch({
        live: liveState([
          livePoint({ logical_point: "ACTIVE_POWER_TOTAL", numeric_value: null, freshness_state: "OFFLINE" }),
        ]),
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      const tile = await screen.findByTestId("live-param-active_power");
      expect(within(tile).getAllByText("—").length).toBeGreaterThan(0);
    });

    it("never renders a Voltage THD tile or an 'unavailable' placeholder at all, regardless of live data", async () => {
      stubAssetViewFetch({ live: liveState([livePoint({ numeric_value: 100 })]) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();
      await waitFor(() => expect(screen.getByTestId("live-param-active_power")).toHaveTextContent("100.00"));

      expect(screen.queryByTestId("live-param-voltage_thd")).toBeNull();
      expect(screen.queryByText(/Voltage THD/)).toBeNull();
    });

    it("shows every live-parameter tile while still loading/erroring, regardless of evidence", async () => {
      let attempt = 0;
      stubFetch((url) => {
        if (url.includes("/live-state")) {
          attempt += 1;
          if (attempt === 1) return { status: 500, jsonBody: { error: "internal", detail: "boom" } };
          return { jsonBody: liveState([livePoint({ logical_point: "ACTIVE_POWER_TOTAL" })]) };
        }
        if (url.includes("/energy/consumption")) return { jsonBody: emptyEnergyResponse() };
        if (url.includes("/demand/current")) return { jsonBody: emptyCurrentDemand() };
        if (url.includes("/demand")) return { jsonBody: emptyDemandSeries() };
        if (url.includes("/power-trend")) return { jsonBody: emptyPowerTrend() };
        if (url.includes("/assets")) return { jsonBody: { site_id: SITE_ID, assets: [asset()] } };
        return { status: 404, jsonBody: { error: "not_found", detail: "unexpected" } };
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("live-param-voltage")).toBeTruthy());
      expect(screen.getByTestId("live-param-current")).toBeTruthy();
    });
  });

  describe("site timezone", () => {
    it("formats 'Last updated' in the selected site's configured timezone, not the runtime's local zone", async () => {
      // 2026-09-17T12:00:00Z (the livePoint default received_at) is
      // 17:30 (05:30 pm) the same day in Asia/Kolkata (UTC+5:30).
      stubAssetViewFetch({ live: liveState([livePoint({ received_at: "2026-09-17T12:00:00Z" })]) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("asset-view-last-updated")).toHaveTextContent("05:30"));
    });
  });

  describe("Energy tile -- Today vs. Yesterday comparison, evidence icon", () => {
    it("has no top-level time-range selector -- the KPI tiles always request Today", async () => {
      const fetchMock = stubAssetViewFetch();
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      expect(screen.queryByTestId("asset-view-time-range")).toBeNull();

      await selectAsset();
      await waitFor(() => expect(screen.getByTestId("asset-energy-tile")).toHaveTextContent("kWh"));

      const calls = fetchMock.mock.calls.filter((c) => String(c[0]).includes("/energy/consumption"));
      expect(calls).toHaveLength(2); // current (Today) + comparison (Yesterday)
    });

    it("compares Today against the SAME clock-time window exactly one day earlier, not a duration-equal shift", async () => {
      const fetchMock = stubAssetViewFetch();
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();
      await waitFor(() => expect(screen.getByTestId("asset-energy-tile")).toHaveTextContent("kWh"));

      const calls = fetchMock.mock.calls.filter((c) => String(c[0]).includes("/energy/consumption"));
      expect(calls).toHaveLength(2);
      const ranges = calls.map((c) => {
        const url = new URL(String(c[0]), "http://localhost");
        return { from: url.searchParams.get("from")!, to: url.searchParams.get("to")! };
      });
      const [a, b] = ranges;
      const current = Date.parse(a!.to) > Date.parse(b!.to) ? a! : b!;
      const previous = current === a ? b! : a!;

      // Exactly 24 hours earlier at both ends -- the defining property of
      // "same clock-time window yesterday" (a duration-equal shift of a
      // partial "Today" window would NOT be exactly 24h at both ends).
      expect(Date.parse(current.from) - Date.parse(previous.from)).toBe(86_400_000);
      expect(Date.parse(current.to) - Date.parse(previous.to)).toBe(86_400_000);
    });

    it("labels the comparison basis 'Yesterday', not 'previous Today'", async () => {
      stubAssetViewFetch({ energy: energyResponse(500) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("asset-energy-delta")).toHaveTextContent("(Yesterday)"));
      expect(screen.getByTestId("asset-energy-delta")).not.toHaveTextContent("previous");
    });

    it("shows an info icon beside 'Energy (kWh)' (not a separate 'Data quality note' line) that reveals the evidence message on hover", async () => {
      stubAssetViewFetch({ energy: energyResponse(500, { resetDetected: true, gapDetected: true }) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const tile = await screen.findByTestId("asset-energy-tile");
      await waitFor(() => expect(tile).toHaveTextContent("500"));
      expect(screen.queryByText("Data quality note")).toBeNull();
      const icon = within(tile).getByTestId("asset-energy-evidence-info");
      expect(icon.closest("h2")).toBeTruthy(); // sits beside the heading

      const user = userEvent.setup();
      await user.hover(icon);
      expect(screen.getByText(/missing reading/)).toBeTruthy();
      expect(screen.getByText(/meter reset/)).toBeTruthy();
    });

    it("shows no evidence icon when no interval reports a reset or gap", async () => {
      stubAssetViewFetch({ energy: energyResponse(500) });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("asset-energy-tile")).toHaveTextContent("500"));
      expect(screen.queryByTestId("asset-energy-evidence-info")).toBeNull();
    });
  });

  describe("Demand tile -- Current Demand / Max Demand, no status line", () => {
    it("shows Current Demand and Max Demand (demand_kw-based), never 'Peak Power'/peak_power_kw", async () => {
      stubAssetViewFetch({
        demandCurrent: {
          asset_id: ASSET_ID,
          has_data: true,
          interval_start: "2026-09-17T11:45:00Z",
          interval_end: "2026-09-17T12:00:00Z",
          current_demand_kw: 63.4,
          current_demand_kva: 70.1,
          quality_status: "PROVISIONAL",
          coverage_percent: 100,
        },
        demandSeries: {
          asset_id: ASSET_ID,
          from: "2026-09-16T12:00:00Z",
          to: "2026-09-17T12:00:00Z",
          no_data: false,
          series: [
            // The interval with the highest peak_power_kw (200) is NOT the
            // one with the highest demand_kw (88.2) -- proves Max Demand
            // uses demand_kw, not peak_power_kw.
            demandInterval({ interval_start: "2026-09-17T09:00:00Z", demand_kw: 40, peak_power_kw: 200 }),
            demandInterval({ interval_start: "2026-09-17T10:30:00Z", demand_kw: 88.2, peak_power_kw: 90 }),
            demandInterval({ interval_start: "2026-09-17T11:00:00Z", demand_kw: 20, peak_power_kw: 20 }),
          ],
        },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const tile = await screen.findByTestId("asset-demand-tile");
      await waitFor(() => expect(tile).toHaveTextContent("Current Demand (kW)"));
      expect(screen.getByTestId("asset-demand-current-value")).toHaveTextContent("63.4");
      expect(within(tile).getByText("Max Demand")).toBeTruthy();
      expect(within(tile).queryByText("Peak Power")).toBeNull();
      expect(screen.getByTestId("asset-demand-max")).toHaveTextContent("88.2 kW");
      expect(screen.getByTestId("asset-demand-max")).not.toHaveTextContent("200");
    });

    it("shows the Max Demand occurrence time in 12-hour site-timezone format (e.g. 06:00PM)", async () => {
      stubAssetViewFetch({
        demandCurrent: { ...emptyCurrentDemand(), has_data: true, current_demand_kw: 10 },
        demandSeries: {
          asset_id: ASSET_ID,
          from: "2026-09-16T12:00:00Z",
          to: "2026-09-17T12:00:00Z",
          no_data: false,
          // 2026-09-17T12:30:00Z is 18:00 (06:00PM) the same day in Kolkata.
          series: [demandInterval({ interval_start: "2026-09-17T12:30:00Z", demand_kw: 112 })],
        },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() => expect(screen.getByTestId("asset-demand-max")).toHaveTextContent("112.0 kW (06:00PM)"));
    });

    it("removes the status line and the 'Latest 15-min interval' caption entirely", async () => {
      stubAssetViewFetch({
        demandCurrent: { ...emptyCurrentDemand(), has_data: true, current_demand_kw: 10, quality_status: "PROVISIONAL" },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const tile = await screen.findByTestId("asset-demand-tile");
      await waitFor(() => expect(tile).toHaveTextContent("10.0"));
      expect(screen.queryByTestId("asset-demand-status")).toBeNull();
      expect(within(tile).queryByText("Calculating")).toBeNull();
      expect(within(tile).queryByText(/Latest 15-min interval/)).toBeNull();
    });

    it("shows an always-present info icon beside 'Current Demand (kW)' that reveals what the figure means on hover", async () => {
      stubAssetViewFetch({ demandCurrent: { ...emptyCurrentDemand(), has_data: true, current_demand_kw: 10 } });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const tile = await screen.findByTestId("asset-demand-tile");
      await waitFor(() => expect(tile).toHaveTextContent("10.0"));
      const icon = within(tile).getByTestId("asset-demand-current-info");
      expect(icon.closest("h2")).toBeTruthy();

      const user = userEvent.setup();
      await user.hover(icon);
      expect(screen.getByText(/latest available calculated demand/i)).toBeTruthy();
    });

    it("shows an honest 'not recorded' Max Demand when today's series has no data", async () => {
      stubAssetViewFetch({ demandCurrent: { ...emptyCurrentDemand(), has_data: true, current_demand_kw: 10 } });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() =>
        expect(screen.getByTestId("asset-demand-max")).toHaveTextContent("Not recorded for today yet."),
      );
    });

    it("shows an honest 'no current demand reading' state when the asset has no demand data yet", async () => {
      stubAssetViewFetch({ demandCurrent: emptyCurrentDemand() });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() =>
        expect(screen.getByTestId("asset-demand-tile")).toHaveTextContent(
          "No current demand reading yet for this asset.",
        ),
      );
    });

    it("shows a working error/retry state when the Asset Demand API fails", async () => {
      stubAssetViewFetch({ demandCurrent: "error" });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const tile = await screen.findByTestId("asset-demand-tile");
      await waitFor(() => expect(within(tile).getByTestId("state-error")).toBeTruthy());
    });
  });

  describe("per-chart time-range selectors", () => {
    it("Power Trend and Demand charts each offer Today/Yesterday/1 Week/1 Month, defaulting to Today, independently of each other", async () => {
      stubAssetViewFetch();
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const powerSelect = (await screen.findByTestId("asset-power-trend-range")) as HTMLSelectElement;
      const demandSelect = (await screen.findByTestId("asset-demand-chart-range")) as HTMLSelectElement;

      expect(within(powerSelect).getAllByRole("option").map((o) => o.textContent)).toEqual([
        "Today",
        "Yesterday",
        "1 Week",
        "1 Month",
      ]);
      expect(powerSelect.value).toBe("TODAY");
      expect(demandSelect.value).toBe("TODAY");

      const user = userEvent.setup();
      await user.selectOptions(powerSelect, "1 Week");
      expect(powerSelect.value).toBe("1W");
      // Changing Power Trend's selector does not affect the Demand chart's.
      expect(demandSelect.value).toBe("TODAY");

      await user.selectOptions(demandSelect, "Yesterday");
      expect(demandSelect.value).toBe("YESTERDAY");
      expect(powerSelect.value).toBe("1W");
    });

    it("changing a chart's own range does not change the KPI tiles' fixed Today figures", async () => {
      const fetchMock = stubAssetViewFetch({
        demandCurrent: { ...emptyCurrentDemand(), has_data: true, current_demand_kw: 63.4 },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();
      await waitFor(() => expect(screen.getByTestId("asset-demand-current-value")).toHaveTextContent("63.4"));

      const demandSelect = screen.getByTestId("asset-demand-chart-range") as HTMLSelectElement;
      const user = userEvent.setup();
      await user.selectOptions(demandSelect, "1 Month");

      // The chart refetches, but the KPI tile's own value is untouched.
      expect(screen.getByTestId("asset-demand-current-value")).toHaveTextContent("63.4");
      const demandCurrentCalls = fetchMock.mock.calls.filter((c) => String(c[0]).includes("/demand/current"));
      expect(demandCurrentCalls).toHaveLength(1); // never refetched by the chart's own selector
    });
  });

  describe("Demand chart -- closing the finalization-lag gap", () => {
    it("appends the live current-interval point so the chart isn't dishonestly 'no data' while an interval is still finalizing", async () => {
      stubAssetViewFetch({
        demandSeries: emptyDemandSeries(), // no finalized intervals yet today
        demandCurrent: {
          asset_id: ASSET_ID,
          has_data: true,
          interval_start: new Date(Date.now() - 5 * 60_000).toISOString(), // within "today"
          interval_end: new Date().toISOString(),
          current_demand_kw: 42,
          current_demand_kva: null,
          quality_status: "PROVISIONAL",
          coverage_percent: 50,
        },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      const chart = await screen.findByTestId("asset-demand-chart");
      await waitFor(() => expect(within(chart).queryByTestId("chart-frame")).toBeTruthy());
      expect(chart).not.toHaveTextContent("No demand trend data for this period yet.");
    });

    it("shows the honest 'no data' state when there is truly nothing to plot (no finalized series, no live reading)", async () => {
      stubAssetViewFetch(); // emptyDemandSeries + emptyCurrentDemand (has_data: false)
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });
      await selectAsset();

      await waitFor(() =>
        expect(screen.getByTestId("asset-demand-chart")).toHaveTextContent("No demand trend data for this period yet."),
      );
    });
  });

  describe("historical charts -- units and timezone", () => {
    it("renders the historical Demand chart and Power Trend chart with an explicit kW axis unit", async () => {
      stubAssetViewFetch({
        demandSeries: {
          asset_id: ASSET_ID,
          from: "2026-09-16T12:00:00Z",
          to: "2026-09-17T12:00:00Z",
          no_data: false,
          series: [demandInterval()],
        },
        powerTrend: {
          asset_id: ASSET_ID,
          from: "2026-09-16T12:00:00Z",
          to: "2026-09-17T12:00:00Z",
          no_data: false,
          series: [
            { sample_time: "2026-09-17T11:00:00Z", active_power_kw: 12.5, is_estimated: false },
            { sample_time: "2026-09-17T11:01:00Z", active_power_kw: 13.1, is_estimated: true },
          ],
        },
      });
      renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

      await selectAsset();

      // ResponsiveContainer resolves to a zero-size box in jsdom, so
      // recharts skips its internal axis-label elements here --
      // ChartFrame.test.tsx covers that rendering with a fixed
      // width/height. What's testable black-box is ChartFrame's own
      // computed aria-label ("<value> (kW) over time").
      const demandChart = screen.getByTestId("asset-demand-chart");
      await waitFor(() => expect(within(demandChart).getAllByTestId("chart-frame").length).toBe(1));
      expect(within(demandChart).getByTestId("chart-frame")).toHaveAttribute(
        "aria-label",
        expect.stringContaining("(kW)"),
      );

      const powerTrendChart = screen.getByTestId("asset-power-trend");
      await waitFor(() => expect(within(powerTrendChart).getAllByTestId("chart-frame").length).toBe(1));
      expect(within(powerTrendChart).getByTestId("chart-frame")).toHaveAttribute(
        "aria-label",
        expect.stringContaining("(kW)"),
      );
      expect(powerTrendChart).toHaveTextContent("Some readings in this period are estimated.");
    });
  });

  it("keeps Energy, Demand tile, Demand chart, live parameters, and Power Trend as independently failing sections", async () => {
    stubAssetViewFetch({ live: "error", demandCurrent: "error", demandSeries: "error", powerTrend: "error" });
    renderWithProviders(<AssetView />, { sites: () => Promise.resolve(SITES_ONE) });

    await selectAsset();

    await waitFor(() =>
      expect(within(screen.getByTestId("asset-demand-tile")).getByTestId("state-error")).toBeTruthy(),
    );
    await waitFor(() =>
      expect(within(screen.getByTestId("asset-demand-chart")).getByTestId("state-error")).toBeTruthy(),
    );
    await waitFor(() =>
      expect(within(screen.getByTestId("asset-power-trend")).getByTestId("state-error")).toBeTruthy(),
    );
    const liveTile = await screen.findByTestId("live-param-active_power");
    expect(within(liveTile).getByTestId("state-error")).toBeTruthy();
    // Energy did not fail, and still renders normally.
    expect(screen.getByTestId("asset-energy-tile")).not.toHaveTextContent("Try again");
  });
});
