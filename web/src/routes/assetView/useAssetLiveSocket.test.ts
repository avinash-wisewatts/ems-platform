import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { renderHook, act } from "@testing-library/react";
import { shouldApplyRestSnapshot, useAssetLiveSocket } from "./useAssetLiveSocket";
import type { AssetLivePoint } from "../../api/types";

const SITE_ID = "site-1";
const ASSET_ID = "asset-1";
const OTHER_ASSET_ID = "asset-2";
const EXPECTED_WS_ORIGIN = `ws://${window.location.host}`;

function point(overrides: Partial<AssetLivePoint> = {}): AssetLivePoint {
  return {
    device_id: "d1",
    device_name: "Meter 1",
    relationship_type: "PRIMARY_METER",
    logical_point: "ACTIVE_POWER_TOTAL",
    unit_symbol: "kW",
    numeric_value: 10,
    text_value: null,
    event_time: "2026-09-16T12:00:00Z",
    received_at: "2026-09-16T12:00:00Z",
    freshness_state: "LIVE",
    quality_code: "GOOD",
    ...overrides,
  };
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

  simulateClose(code = 1006, reason = ""): void {
    this.readyState = MockWebSocket.CLOSED;
    this.onclose?.({ code, reason } as CloseEvent);
  }

  close(code?: number, reason?: string): void {
    this.closeCalls.push({ code, reason });
    this.readyState = MockWebSocket.CLOSED;
  }

  send(_data: string): void {}
}

beforeEach(() => {
  MockWebSocket.instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("useAssetLiveSocket", () => {
  it("does nothing when no site or asset is selected", () => {
    const { result } = renderHook(() => useAssetLiveSocket(null, null));
    expect(MockWebSocket.instances).toHaveLength(0);
    expect(result.current.connectionState).toBe("closed");
    expect(result.current.points).toBeNull();
  });

  it("opens a WebSocket to the same-origin proxy path for the selected asset", () => {
    renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    expect(MockWebSocket.instances).toHaveLength(1);
    expect(MockWebSocket.instances[0]!.url).toBe(`${EXPECTED_WS_ORIGIN}/api/live/assets/${ASSET_ID}/ws`);
  });

  it("reports 'connecting' then 'open', and applies the initial snapshot", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    expect(result.current.connectionState).toBe("connecting");

    act(() => MockWebSocket.instances[0]!.simulateOpen());
    expect(result.current.connectionState).toBe("open");

    const snapshotPoints = [point({ logical_point: "VOLTAGE_L1", numeric_value: 231 })];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "snapshot", asset_id: ASSET_ID, points: snapshotPoints }),
      ),
    );
    expect(result.current.points).toEqual(snapshotPoints);
  });

  it("updates points when a telemetry message arrives, immediately", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    const telemetryPoints = [point({ logical_point: "CURRENT_TOTAL", numeric_value: 12.4 })];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "telemetry", asset_id: ASSET_ID, points: telemetryPoints }),
      ),
    );
    expect(result.current.points).toEqual(telemetryPoints);
  });

  it("ignores malformed (non-JSON) and unsupported-shape messages without throwing or changing points", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    const goodPoints = [point()];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "snapshot", asset_id: ASSET_ID, points: goodPoints }),
      ),
    );
    expect(result.current.points).toEqual(goodPoints);

    expect(() => {
      act(() => MockWebSocket.instances[0]!.simulateMessage("not valid json {{{"));
      act(() => MockWebSocket.instances[0]!.simulateMessage(JSON.stringify({ type: "ping" })));
      act(() => MockWebSocket.instances[0]!.simulateMessage(JSON.stringify({ type: "telemetry" })));
      act(() => MockWebSocket.instances[0]!.simulateMessage(JSON.stringify(null)));
    }).not.toThrow();

    // None of the above were recognized -- the last good value is unchanged.
    expect(result.current.points).toEqual(goodPoints);
  });

  it("retains the last known good points during a transient disconnect, while surfacing 'reconnecting'", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    const goodPoints = [point()];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "snapshot", asset_id: ASSET_ID, points: goodPoints }),
      ),
    );
    expect(result.current.points).toEqual(goodPoints);

    act(() => MockWebSocket.instances[0]!.simulateClose(1006, "abnormal closure"));
    expect(result.current.connectionState).toBe("reconnecting");
    expect(result.current.points).toEqual(goodPoints);
  });

  it("reconnects with bounded exponential backoff after a transient close", () => {
    renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    act(() => MockWebSocket.instances[0]!.simulateClose(1006));
    expect(MockWebSocket.instances).toHaveLength(1);

    // First retry at ~1s.
    act(() => vi.advanceTimersByTime(999));
    expect(MockWebSocket.instances).toHaveLength(1);
    act(() => vi.advanceTimersByTime(2));
    expect(MockWebSocket.instances).toHaveLength(2);

    // Second retry backs off further (~2s), not immediately.
    act(() => MockWebSocket.instances[1]!.simulateClose(1006));
    act(() => vi.advanceTimersByTime(1999));
    expect(MockWebSocket.instances).toHaveLength(2);
    act(() => vi.advanceTimersByTime(2));
    expect(MockWebSocket.instances).toHaveLength(3);
  });

  it("caps the backoff delay rather than growing it unbounded", () => {
    renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    // Force many consecutive transient failures without ever reopening --
    // the delay must stop growing once it hits the cap.
    for (let i = 0; i < 8; i++) {
      const current = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
      act(() => current.simulateClose(1006));
      act(() => vi.advanceTimersByTime(60_000));
    }
    const countAfterEight = MockWebSocket.instances.length;

    const last = MockWebSocket.instances[MockWebSocket.instances.length - 1]!;
    act(() => last.simulateClose(1006));
    // Capped backoff (30s) must have fired well within another 60s tick.
    act(() => vi.advanceTimersByTime(60_000));
    expect(MockWebSocket.instances.length).toBe(countAfterEight + 1);
  });

  it("does not retry after an authentication rejection (close code 4401)", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateClose(4401, "unauthenticated"));
    expect(result.current.connectionState).toBe("closed");

    act(() => vi.advanceTimersByTime(60_000));
    expect(MockWebSocket.instances).toHaveLength(1);
  });

  it("does not retry after an authorization rejection (close code 4404)", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateClose(4404, "not accessible"));
    expect(result.current.connectionState).toBe("closed");

    act(() => vi.advanceTimersByTime(60_000));
    expect(MockWebSocket.instances).toHaveLength(1);
  });

  it("closes the previous socket and starts fresh (points reset to null) when the asset changes", () => {
    const { result, rerender } = renderHook(
      ({ assetId }: { assetId: string }) => useAssetLiveSocket(SITE_ID, assetId),
      { initialProps: { assetId: ASSET_ID } },
    );
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    const firstAssetPoints = [point({ numeric_value: 1 })];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "snapshot", asset_id: ASSET_ID, points: firstAssetPoints }),
      ),
    );
    expect(result.current.points).toEqual(firstAssetPoints);

    const firstSocket = MockWebSocket.instances[0]!;
    act(() => rerender({ assetId: OTHER_ASSET_ID }));

    expect(firstSocket.closeCalls.length).toBeGreaterThan(0);
    expect(result.current.points).toBeNull();
    expect(MockWebSocket.instances).toHaveLength(2);
    expect(MockWebSocket.instances[1]!.url).toBe(`${EXPECTED_WS_ORIGIN}/api/live/assets/${OTHER_ASSET_ID}/ws`);
  });

  it("stops reconnect attempts (no new socket) once unmounted, even mid-backoff", () => {
    const { unmount } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    const socket = MockWebSocket.instances[0]!;

    // Server-initiated close schedules a reconnect (server closes don't
    // themselves call the client's .close()) -- unmounting before that
    // timer fires must cancel it.
    act(() => socket.simulateClose(1006));
    unmount();

    act(() => vi.advanceTimersByTime(60_000));
    expect(MockWebSocket.instances).toHaveLength(1);
  });

  it("closes the live socket on unmount while it is open", () => {
    const { unmount } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());
    const socket = MockWebSocket.instances[0]!;

    unmount();

    expect(socket.closeCalls.length).toBeGreaterThan(0);
  });
});

describe("shouldApplyRestSnapshot", () => {
  it("allows a REST snapshot when the socket hasn't delivered anything yet for this asset", () => {
    expect(shouldApplyRestSnapshot({ points: null })).toBe(true);
  });

  it("rejects a REST snapshot once the socket has already delivered data for this asset", () => {
    expect(shouldApplyRestSnapshot({ points: [] })).toBe(false);
    expect(shouldApplyRestSnapshot({ points: [point()] })).toBe(false);
  });

  it("regression: a REST response resolving AFTER live telemetry must not overwrite it", () => {
    // Reproduces the exact ordering that caused the bug: the socket
    // delivers fresh telemetry first, then a slower, now-stale REST
    // response resolves. A caller following the documented contract
    // (checking shouldApplyRestSnapshot against the hook's live `points`
    // immediately before applying its own REST response) must skip it.
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));
    act(() => MockWebSocket.instances[0]!.simulateOpen());

    const freshTelemetry = [point({ numeric_value: 99 })];
    act(() =>
      MockWebSocket.instances[0]!.simulateMessage(
        JSON.stringify({ type: "telemetry", asset_id: ASSET_ID, points: freshTelemetry }),
      ),
    );
    expect(result.current.points).toEqual(freshTelemetry);

    // The REST call that started at asset-selection time only resolves now,
    // after the socket already delivered fresher data.
    const staleRestPoints = [point({ numeric_value: 1 })];
    const restShouldBeApplied = shouldApplyRestSnapshot(result.current);

    expect(restShouldBeApplied).toBe(false);
    // A caller respecting the contract never calls setPoints(staleRestPoints)
    // in this case -- the hook's own state remains the fresher value.
    expect(result.current.points).toEqual(freshTelemetry);
    expect(result.current.points).not.toEqual(staleRestPoints);
  });

  it("allows the REST snapshot when it resolves before any live telemetry has arrived", () => {
    const { result } = renderHook(() => useAssetLiveSocket(SITE_ID, ASSET_ID));

    // No message has arrived over the socket yet -- the REST response is
    // still the freshest (and only) data available.
    expect(shouldApplyRestSnapshot(result.current)).toBe(true);
  });
});
