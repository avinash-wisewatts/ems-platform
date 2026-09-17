/**
 * Keeps an Asset View's live tiles current after the initial REST snapshot
 * (getAssetLiveState), via the portal-session WebSocket proxy --
 * main.py::proxy_asset_live_websocket, same-origin, which forwards to
 * live-telemetry's live_main.py::live_asset_websocket. See that route's own
 * docstring for the full architecture rationale (no MQTT/Grafana exposure,
 * no second auth mechanism -- the browser's existing session cookie is
 * reused as-is). Never polls: the only network activity between messages is
 * the WebSocket connection itself.
 *
 * Behavior:
 * - Reconnects with bounded exponential backoff (1s, 2s, 4s, ... capped at
 *   30s) on any transient close or error.
 * - Never retries after an application-level rejection (close code 4401
 *   "unauthenticated" / 4404 "not accessible") -- that is not a transient
 *   condition and retrying it would just hammer the server for a result
 *   that can never change without the user re-authenticating or being
 *   granted access.
 * - Never clears `points` on a disconnect -- the caller keeps rendering the
 *   last known good values; `connectionState` drives a separate, subtle
 *   "reconnecting" indicator instead of blanking the tiles.
 * - Opens a fresh connection (dropping any previous one) whenever
 *   `assetId`/`siteId` changes; closes on unmount or when either is null.
 * - Every incoming frame is parsed defensively: non-JSON text and any JSON
 *   shape that isn't {type: "snapshot"|"telemetry", points: [...]} is
 *   silently ignored, never thrown -- the proxy is a content-agnostic relay
 *   (see main.py), so this hook is the first place that actually validates
 *   message shape.
 *
 * REST-vs-WebSocket ordering contract for callers: a caller typically pairs
 * this hook with an initial REST snapshot fetch (e.g. getAssetLiveState) for
 * the very first paint, started alongside this hook rather than awaited
 * before it. That REST call and this hook's own first message race --
 * nothing guarantees the REST response resolves before the socket delivers
 * live data, and a slower REST response resolving AFTER live data has
 * already arrived would silently overwrite a fresher reading with a staler
 * one if applied unconditionally. Callers MUST gate their own
 * `setPoints(restResponse.points)` through `shouldApplyRestSnapshot` (below)
 * using this hook's current `points` -- never apply a REST snapshot once
 * `points` is non-null for the currently selected asset. See
 * useAssetLiveSocket.test.ts for the exact ordering this guards against.
 */

import { useEffect, useState } from "react";
import type { AssetLivePoint } from "../../api/types";

export type LiveConnectionState = "connecting" | "open" | "reconnecting" | "closed";

export type AssetLiveSocketState = {
  /** null until the first message (snapshot or telemetry) arrives over the
   *  socket; the last known good value list thereafter, retained across
   *  reconnects. */
  points: AssetLivePoint[] | null;
  connectionState: LiveConnectionState;
};

/**
 * Whether a REST snapshot response that has just resolved should still be
 * applied to the UI, given this hook's current state for the SAME asset.
 * A REST response that resolves after the WebSocket has already delivered
 * live data for this asset is, by definition, no fresher than what's
 * already showing -- applying it would silently regress the tiles to an
 * older reading (a value moving forward then visibly jumping backward).
 * An empty array counts as "already received" just as much as a populated
 * one -- it is still a real message, not the absence of one; only `null`
 * (nothing received yet for this asset) means the REST response is still
 * the freshest data available.
 */
export function shouldApplyRestSnapshot(liveState: Pick<AssetLiveSocketState, "points">): boolean {
  return liveState.points === null;
}

const INITIAL_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30_000;
const BACKOFF_MULTIPLIER = 2;

// main.py::proxy_asset_live_websocket / live_main.py::live_asset_websocket
// both close with these exact codes for a permanent, non-retryable
// rejection -- never a transient network condition.
const CLOSE_CODE_UNAUTHENTICATED = 4401;
const CLOSE_CODE_NOT_ACCESSIBLE = 4404;

function isRecognizedTelemetryMessage(
  value: unknown,
): value is { type: "snapshot" | "telemetry"; asset_id: string; points: AssetLivePoint[] } {
  if (typeof value !== "object" || value === null) return false;
  const record = value as Record<string, unknown>;
  return (record.type === "snapshot" || record.type === "telemetry") && Array.isArray(record.points);
}

function buildWebSocketUrl(assetId: string): string {
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${scheme}//${window.location.host}/api/live/assets/${encodeURIComponent(assetId)}/ws`;
}

export function useAssetLiveSocket(siteId: string | null, assetId: string | null): AssetLiveSocketState {
  const [points, setPoints] = useState<AssetLivePoint[] | null>(null);
  const [connectionState, setConnectionState] = useState<LiveConnectionState>("closed");

  useEffect(() => {
    setPoints(null);

    if (!siteId || !assetId) {
      setConnectionState("closed");
      return;
    }

    let active = true;
    let socket: WebSocket | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let backoffMs = INITIAL_BACKOFF_MS;
    let everConnected = false;

    function scheduleReconnect(): void {
      if (!active) return;
      setConnectionState("reconnecting");
      reconnectTimer = setTimeout(connect, backoffMs);
      backoffMs = Math.min(backoffMs * BACKOFF_MULTIPLIER, MAX_BACKOFF_MS);
    }

    function connect(): void {
      if (!active) return;
      setConnectionState(everConnected ? "reconnecting" : "connecting");

      const ws = new WebSocket(buildWebSocketUrl(assetId!));
      socket = ws;

      ws.onopen = () => {
        if (!active) return;
        everConnected = true;
        backoffMs = INITIAL_BACKOFF_MS;
        setConnectionState("open");
      };

      ws.onmessage = (event: MessageEvent) => {
        if (!active || typeof event.data !== "string") return;
        let parsed: unknown;
        try {
          parsed = JSON.parse(event.data);
        } catch {
          return;
        }
        if (!isRecognizedTelemetryMessage(parsed)) return;
        setPoints(parsed.points);
      };

      ws.onclose = (event: CloseEvent) => {
        if (!active) return;
        socket = null;
        if (event.code === CLOSE_CODE_UNAUTHENTICATED || event.code === CLOSE_CODE_NOT_ACCESSIBLE) {
          setConnectionState("closed");
          return;
        }
        scheduleReconnect();
      };

      // onclose always fires after onerror for a browser WebSocket --
      // reconnect scheduling lives there so it happens exactly once per
      // failed attempt, not twice.
      ws.onerror = () => {};
    }

    connect();

    return () => {
      active = false;
      if (reconnectTimer !== null) clearTimeout(reconnectTimer);
      if (socket !== null) {
        socket.onopen = null;
        socket.onmessage = null;
        socket.onclose = null;
        socket.onerror = null;
        socket.close();
      }
    };
  }, [siteId, assetId]);

  return { points, connectionState };
}
