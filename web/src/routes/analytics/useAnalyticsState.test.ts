import { describe, expect, it } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";
import { stubFetch } from "../../test-utils";
import { INITIAL_DRAFT, MESSAGES } from "./analyticsQuery";
import { INITIAL_STATE, analyticsReducer, hasUnappliedChanges, useAnalyticsState } from "./useAnalyticsState";
import { catalogFixture, seriesResponseFixture } from "./analyticsTestFixtures";

const catalog = catalogFixture();
const NOW = new Date("2026-06-15T12:00:00Z"); // 17:30 IST
const now = () => NOW;

type Props = { siteId: string | null };

function renderState(initial: Props = { siteId: "site-1" }) {
  return renderHook((props: Props) => useAnalyticsState({ siteId: props.siteId, timeZone: "Asia/Kolkata", catalog, now }), {
    initialProps: initial,
  });
}

/** A controllable fetch: each series request waits until resolved or rejected. */
function deferredSeriesFetch() {
  const pending: { url: string; resolve: (body: unknown) => void; reject: () => void }[] = [];
  const mock = stubFetch(() => ({ jsonBody: undefined }));
  mock.mockImplementation(
    (input: RequestInfo | URL) =>
      new Promise<Response>((resolve) => {
        const url = typeof input === "string" ? input : input.toString();
        pending.push({
          url,
          resolve: (body) => resolve({ ok: true, status: 200, statusText: "", headers: new Headers(), json: async () => body } as Response),
          reject: () =>
            resolve({
              ok: false,
              status: 500,
              statusText: "Server Error",
              headers: new Headers(),
              json: async () => ({ error: "internal", detail: "boom" }),
            } as Response),
        });
      }),
  );
  return { mock, pending };
}

describe("analyticsReducer -- selection limits (D5)", () => {
  it("hard-stops assets at 10 and data points at 5 while selecting", () => {
    let state = INITIAL_STATE;
    for (let i = 1; i <= 11; i++) state = analyticsReducer(state, { type: "toggleAsset", assetId: `a${i}`, maxAssets: 10 });
    expect(state.draft.assetIds).toHaveLength(10);
    expect(state.draft.assetIds).not.toContain("a11");
    for (const dp of ["P1", "P2", "P3", "P4", "P5", "P6"]) {
      state = analyticsReducer(state, { type: "toggleDataPoint", dataPoint: dp, maxDataPoints: 5 });
    }
    expect(state.draft.dataPoints).toEqual(["P1", "P2", "P3", "P4", "P5"]);
  });

  it("toggling a selected item deselects it, making room for another", () => {
    let state = analyticsReducer(INITIAL_STATE, { type: "setAssets", assetIds: ["a1", "a2"], maxAssets: 2 });
    state = analyticsReducer(state, { type: "toggleAsset", assetId: "a3", maxAssets: 2 });
    expect(state.draft.assetIds).toEqual(["a1", "a2"]);
    state = analyticsReducer(state, { type: "toggleAsset", assetId: "a1", maxAssets: 2 });
    state = analyticsReducer(state, { type: "toggleAsset", assetId: "a3", maxAssets: 2 });
    expect(state.draft.assetIds).toEqual(["a2", "a3"]);
  });

  it("bulk selection keeps order, drops duplicates and stops at the limit", () => {
    const state = analyticsReducer(INITIAL_STATE, { type: "setAssets", assetIds: ["a3", "a1", "a3", "a2"], maxAssets: 2 });
    expect(state.draft.assetIds).toEqual(["a3", "a1"]);
  });
});

describe("analyticsReducer -- resolution auto-switch (D9, D68)", () => {
  it("a manual resolution the new range cannot use switches to Auto with the approved notice", () => {
    let state = analyticsReducer(INITIAL_STATE, { type: "setResolution", resolution: "1m" });
    state = analyticsReducer(state, { type: "setRange", range: { kind: "preset", preset: "30D" }, resolutionAvailable: false });
    expect(state.draft.resolution).toBe("auto");
    expect(state.resolutionNotice).toBe(MESSAGES.resolutionChangedToAuto);
    // The notice goes away on the next range or resolution change.
    state = analyticsReducer(state, { type: "setResolution", resolution: "1h" });
    expect(state.resolutionNotice).toBeNull();
  });

  it("no switch and no notice when the resolution stays available, or is already Auto", () => {
    let state = analyticsReducer(INITIAL_STATE, { type: "setResolution", resolution: "1h" });
    state = analyticsReducer(state, { type: "setRange", range: { kind: "preset", preset: "7D" }, resolutionAvailable: true });
    expect(state.draft.resolution).toBe("1h");
    expect(state.resolutionNotice).toBeNull();
    const auto = analyticsReducer(INITIAL_STATE, { type: "setRange", range: { kind: "preset", preset: "1Y" }, resolutionAvailable: false });
    expect(auto.resolutionNotice).toBeNull();
  });
});

describe("useAnalyticsState", () => {
  it("starts fresh: nothing selected, no unapplied changes, no request", () => {
    const mock = stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    expect(result.current.state).toEqual(INITIAL_STATE);
    expect(result.current.hasUnappliedChanges).toBe(false);
    expect(mock).not.toHaveBeenCalled();
  });

  it("any change marks unapplied changes (D46, D47)", () => {
    stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    act(() => result.current.toggleAsset("a1"));
    expect(result.current.hasUnappliedChanges).toBe(true);
    act(() => result.current.toggleAsset("a1"));
    expect(result.current.hasUnappliedChanges).toBe(false);
  });

  it("validation happens before any request and keeps the selections (D48, D49)", () => {
    const mock = stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    act(() => result.current.toggleAsset("a1"));
    act(() => result.current.update());
    expect(result.current.state.validationMessage).toBe(MESSAGES.selectDataPoint);
    expect(result.current.state.draft.assetIds).toEqual(["a1"]);
    expect(mock).not.toHaveBeenCalled();
    // A draft change clears the stale message.
    act(() => result.current.toggleDataPoint("ENERGY_IMPORT"));
    expect(result.current.state.validationMessage).toBeNull();
  });

  it("more than 25 rendered series is rejected with the approved message and no request (D45, D78)", () => {
    const mock = stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    // Every asset has per-phase Energy: 10 assets x 3 phases = 30 rendered series.
    const phased = catalogFixture();
    for (const asset of phased.assets) for (const point of asset.data_points) point.phases.three_phase = true;
    const { result } = renderHook(() =>
      useAnalyticsState({ siteId: "site-1", timeZone: "Asia/Kolkata", catalog: phased, now }),
    );
    act(() => result.current.setAssets(["a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9", "a10"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.setPhase("three_phase"));
    act(() => result.current.update());
    expect(result.current.state.validationMessage).toBe(MESSAGES.tooManySeries);
    expect(result.current.state.draft.assetIds).toHaveLength(10); // selections kept (D49)
    expect(mock).not.toHaveBeenCalled();
    // Under System the same selection is 10 series and goes through.
    act(() => result.current.setPhase("system"));
    act(() => result.current.update());
    expect(result.current.state.validationMessage).toBeNull();
    expect(mock).toHaveBeenCalledTimes(1);
  });

  it("Update requests the site-local Today range, the served pairs in order, Auto and System", async () => {
    const mock = stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    act(() => result.current.setAssets(["a2", "x1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT", "ENERGY_EXPORT"]));
    act(() => result.current.update());
    await waitFor(() => expect(result.current.state.applied).not.toBeNull());

    const url = new URL(mock.mock.calls[0]![0] as string, "http://localhost");
    expect(url.pathname).toBe("/api/v1/sites/site-1/analytics/series");
    expect(url.searchParams.get("from")).toBe("2026-06-14T18:30:00.000Z");
    expect(url.searchParams.get("to")).toBe("2026-06-15T18:30:00.000Z");
    expect(url.searchParams.get("resolution")).toBe("auto");
    expect(url.searchParams.get("phase")).toBe("system");
    expect(url.searchParams.getAll("selection")).toEqual(["a2:ENERGY_IMPORT", "a2:ENERGY_EXPORT", "x1:ENERGY_EXPORT"]);

    const applied = result.current.state.applied!;
    expect(applied.unavailable).toEqual([{ assetId: "x1", dataPoint: "ENERGY_IMPORT" }]);
    expect(applied.response).toEqual(seriesResponseFixture());
    expect(result.current.hasUnappliedChanges).toBe(false);
    expect(result.current.state.loading).toBe(false);
  });

  it("keeps the previous result while a new one loads, then replaces it (D7)", async () => {
    const { pending } = deferredSeriesFetch();
    const { result } = renderState();
    act(() => result.current.setAssets(["a1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.update());
    await act(async () => pending[0]!.resolve(seriesResponseFixture({ resolution: "15m" })));
    const first = result.current.state.applied;
    expect(first?.response?.resolution).toBe("15m");

    act(() => result.current.setRange({ kind: "preset", preset: "7D" }));
    act(() => result.current.update());
    expect(result.current.state.loading).toBe(true);
    expect(result.current.state.applied).toBe(first); // still showing the previous result

    await act(async () => pending[1]!.resolve(seriesResponseFixture({ resolution: "1h" })));
    expect(result.current.state.loading).toBe(false);
    expect(result.current.state.applied?.response?.resolution).toBe("1h");
  });

  it("a failed request keeps the previous result and the selections, with the approved message (D50, D80)", async () => {
    const { pending } = deferredSeriesFetch();
    const { result } = renderState();
    act(() => result.current.setAssets(["a1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.update());
    await act(async () => pending[0]!.resolve(seriesResponseFixture()));
    const first = result.current.state.applied;

    act(() => result.current.toggleAsset("a2"));
    act(() => result.current.update());
    await act(async () => pending[1]!.reject());

    expect(result.current.state.errorMessage).toBe(MESSAGES.updateFailed);
    expect(result.current.state.applied).toBe(first);
    expect(result.current.state.draft.assetIds).toEqual(["a1", "a2"]);
    expect(result.current.hasUnappliedChanges).toBe(true); // Update stays available
    expect(result.current.state.loading).toBe(false);
  });

  it("the next Update clears a previous failure message", async () => {
    const { pending } = deferredSeriesFetch();
    const { result } = renderState();
    act(() => result.current.setAssets(["a1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.update());
    await act(async () => pending[0]!.reject());
    expect(result.current.state.errorMessage).toBe(MESSAGES.updateFailed);
    act(() => result.current.update());
    expect(result.current.state.errorMessage).toBeNull();
  });

  it("a site change resets everything, and a request still in flight never lands (D35, D69)", async () => {
    const { pending } = deferredSeriesFetch();
    const { result, rerender } = renderState();
    act(() => result.current.setAssets(["a1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.setPhase("three_phase"));
    act(() => result.current.update());

    rerender({ siteId: "site-2" });
    expect(result.current.state).toEqual(INITIAL_STATE);

    await act(async () => pending[0]!.resolve(seriesResponseFixture()));
    expect(result.current.state).toEqual(INITIAL_STATE);
    expect(result.current.state.draft).toEqual(INITIAL_DRAFT);
  });

  it("when no selected combination can be served, nothing is requested and all are reported unavailable", async () => {
    const mock = stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    act(() => result.current.setAssets(["x1"]));
    act(() => result.current.setDataPoints(["ENERGY_IMPORT"]));
    act(() => result.current.update());
    await waitFor(() => expect(result.current.state.applied).not.toBeNull());
    expect(mock).not.toHaveBeenCalled();
    expect(result.current.state.applied).toMatchObject({
      selections: [],
      unavailable: [{ assetId: "x1", dataPoint: "ENERGY_IMPORT" }],
      response: null,
    });
  });

  it("setRange switches an unavailable manual resolution to Auto using the catalogue windows", () => {
    stubFetch(() => ({ jsonBody: seriesResponseFixture() }));
    const { result } = renderState();
    act(() => result.current.setResolution("1m"));
    act(() => result.current.setRange({ kind: "preset", preset: "7D" })); // 1m maximum is 3 days
    expect(result.current.state.draft.resolution).toBe("auto");
    expect(result.current.state.resolutionNotice).toBe(MESSAGES.resolutionChangedToAuto);
  });

  it("hasUnappliedChanges compares with the last applied draft", () => {
    const state = { ...INITIAL_STATE, draft: { ...INITIAL_DRAFT, assetIds: ["a1"] } };
    expect(hasUnappliedChanges(state)).toBe(true);
    const applied = { draft: state.draft, range: { from: "", to: "" }, selections: [], unavailable: [], response: null };
    expect(hasUnappliedChanges({ ...state, applied })).toBe(false);
  });
});

