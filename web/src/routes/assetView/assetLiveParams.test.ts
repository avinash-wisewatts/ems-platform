import { describe, expect, it } from "vitest";
import { findLivePoint, mostRecentReceivedAt } from "./assetLiveParams";
import type { AssetLivePoint } from "../../api/types";

function point(overrides: Partial<AssetLivePoint> = {}): AssetLivePoint {
  return {
    device_id: "d1",
    device_name: "Meter 1",
    relationship_type: "PRIMARY_METER",
    logical_point: "ACTIVE_POWER_TOTAL",
    unit_symbol: "kW",
    numeric_value: 42.5,
    text_value: null,
    event_time: "2026-09-16T12:00:00Z",
    received_at: "2026-09-16T12:00:00Z",
    freshness_state: "LIVE",
    quality_code: "GOOD",
    ...overrides,
  };
}

describe("findLivePoint", () => {
  it("finds a point by logical_point name", () => {
    const points = [point({ logical_point: "VOLTAGE_L1", numeric_value: 229.8 })];
    expect(findLivePoint(points, "VOLTAGE_L1")?.numeric_value).toBe(229.8);
  });

  it("returns null when the point doesn't exist", () => {
    expect(findLivePoint([], "VOLTAGE_L1")).toBeNull();
  });
});

describe("mostRecentReceivedAt", () => {
  it("returns the latest received_at across all points", () => {
    const points = [
      point({ received_at: "2026-09-16T12:00:00Z" }),
      point({ received_at: "2026-09-16T12:05:00Z" }),
      point({ received_at: "2026-09-16T11:55:00Z" }),
    ];
    expect(mostRecentReceivedAt(points)).toBe("2026-09-16T12:05:00Z");
  });

  it("returns null when there are no points", () => {
    expect(mostRecentReceivedAt([])).toBeNull();
  });
});
