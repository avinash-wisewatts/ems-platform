import { describe, expect, it } from "vitest";
import type { AnalyticsCatalogAsset } from "../../api/types";
import {
  DATA_POINT_GROUP_ORDER,
  dataPointVisualOrder,
  fillToLimit,
  groupAssets,
  groupDataPoints,
  siteDataPoints,
  visualOrder,
} from "./selectorGroups";
import { catalogFixture } from "./analyticsTestFixtures";

function asset(id: string, name: string, space?: [string, string], type?: [string, string]): AnalyticsCatalogAsset {
  return {
    asset_id: id,
    asset_name: name,
    asset_type_id: type?.[0] ?? null,
    asset_type_name: type?.[1] ?? null,
    building_name: null,
    floor_name: null,
    space_id: space?.[0] ?? null,
    space_name: space?.[1] ?? null,
    location_path: null,
    data_points: [],
  };
}

const ASSETS = [
  asset("c2", "Chiller 2", ["s-plant", "Plant Room"], ["t-chiller", "Chillers"]),
  asset("c10", "Chiller 10", ["s-plant", "Plant Room"], ["t-chiller", "Chillers"]),
  asset("ahu", "AHU 1", ["s-lobby", "Lobby"], ["t-ahu", "Air Handling Units"]),
  asset("pump", "Pump 3"), // no Space, no Asset Type
  asset("main", "Main Incomer", ["s-lobby", "Lobby"]), // Space but no Asset Type
];

describe("groupAssets (D38, D65, D71, D72)", () => {
  it("Group by Space: named groups by name, assets by name (numeric-aware), Unassigned at the bottom", () => {
    const groups = groupAssets(ASSETS, "space");
    expect(groups.map((g) => g.name)).toEqual(["Lobby", "Plant Room", "Unassigned"]);
    expect(groups[0]!.assets.map((a) => a.asset_name)).toEqual(["AHU 1", "Main Incomer"]);
    expect(groups[1]!.assets.map((a) => a.asset_name)).toEqual(["Chiller 2", "Chiller 10"]);
    expect(groups[2]!.assets.map((a) => a.asset_id)).toEqual(["pump"]);
  });

  it("Group by Asset Type: assets without a type are in Other, at the bottom (PO 2026-09-30)", () => {
    const groups = groupAssets(ASSETS, "assetType");
    expect(groups.map((g) => g.name)).toEqual(["Air Handling Units", "Chillers", "Other"]);
    expect(groups[2]!.assets.map((a) => a.asset_name)).toEqual(["Main Incomer", "Pump 3"]);
  });

  it("switching views regroups the same assets (the selection is kept by id)", () => {
    expect(visualOrder(groupAssets(ASSETS, "space")).sort()).toEqual(visualOrder(groupAssets(ASSETS, "assetType")).sort());
  });

  it("search keeps only matching assets and drops empty groups", () => {
    const groups = groupAssets(ASSETS, "space", "chiller");
    expect(groups.map((g) => g.name)).toEqual(["Plant Room"]);
  });

  it("visualOrder is top to bottom across groups", () => {
    expect(visualOrder(groupAssets(ASSETS, "space"))).toEqual(["ahu", "main", "c2", "c10", "pump"]);
  });
});

describe("fillToLimit (D44, D65)", () => {
  it("adds in visual order until the limit and reports that some were left out", () => {
    expect(fillToLimit(["x"], ["a", "b", "c"], 3)).toEqual({ selection: ["x", "a", "b"], limited: true });
  });
  it("keeps existing selections in place and skips duplicates", () => {
    expect(fillToLimit(["b"], ["a", "b", "c"], 10)).toEqual({ selection: ["b", "a", "c"], limited: false });
  });
});

describe("data point groups (D39-D41, D66, D67, D75)", () => {
  const catalog = catalogFixture();

  it("the site catalogue's data points, each once", () => {
    expect(siteDataPoints(catalog)).toEqual([
      { code: "ENERGY_IMPORT", label: "Energy" },
      { code: "ENERGY_EXPORT", label: "Energy Export" },
    ]);
  });

  it("Energy is in Frequently Used and Power; Energy Export in Power; empty groups are not shown", () => {
    const groups = groupDataPoints(siteDataPoints(catalog));
    expect(groups.map((g) => [g.name, g.points.map((p) => p.label)])).toEqual([
      ["Frequently Used", ["Energy"]],
      ["Power", ["Energy", "Energy Export"]],
    ]);
  });

  it("groups keep the recorded order", () => {
    expect(DATA_POINT_GROUP_ORDER).toEqual(["Frequently Used", "Power", "Input/Output", "Environmental", "Conversion", "Misc/Other"]);
  });

  it("a registry code not yet mapped is listed under Misc/Other", () => {
    const groups = groupDataPoints([{ code: "NEW_POINT", label: "New point" }]);
    expect(groups).toEqual([{ name: "Misc/Other", points: [{ code: "NEW_POINT", label: "New point" }] }]);
  });

  it("visual order lists each data point once, Frequently Used first", () => {
    expect(dataPointVisualOrder(groupDataPoints(siteDataPoints(catalog)))).toEqual(["ENERGY_IMPORT", "ENERGY_EXPORT"]);
  });

  it("search filters by label", () => {
    expect(groupDataPoints(siteDataPoints(catalog), "export").map((g) => g.name)).toEqual(["Power"]);
  });
});

describe("D67 placement of every platform parameter", () => {
  // Every config.parameters code (migrations 223, 229, 254), with the label the catalogue returns
  // (the registry label for B3 points, otherwise the parameter name).
  const ALL = [
    ["ACTIVE_POWER", "Power"],
    ["APPARENT_ENERGY", "Apparent Energy"],
    ["APPARENT_POWER", "Apparent Power"],
    ["BATTERY_VOLTAGE", "Battery Voltage"],
    ["CURRENT", "Current"],
    ["CURRENT_THD", "Current Total Harmonic Distortion"],
    ["DEW_POINT", "Dew Point"],
    ["ENERGY_EXPORT", "Energy Export"],
    ["ENERGY_IMPORT", "Energy"],
    ["FREQUENCY", "Frequency"],
    ["HUMIDITY", "Relative Humidity"],
    ["ILLUMINANCE", "Illuminance"],
    ["OCCUPANCY_ACTIVITY", "Occupancy Activity"],
    ["OCCUPANCY_TIME_SINCE_LAST_EVENT", "Time Since Last Occupancy Event"],
    ["PHASE_ANGLE", "Phase Angle"],
    ["POWER_FACTOR", "Power Factor"],
    ["REACTIVE_POWER", "Reactive Power"],
    ["TEMPERATURE", "Temperature"],
    ["VOLTAGE_LINE_LINE", "Voltage (Line-Line)"],
    ["VOLTAGE_LINE_NEUTRAL", "Voltage (Line-Neutral)"],
  ].map(([code, label]) => ({ code: code!, label: label! }));

  it("lists every catalogue point in its D67 group; none is dropped", () => {
    const groups = groupDataPoints(ALL);
    expect(groups.map((g) => [g.name, g.points.map((p) => p.code)])).toEqual([
      ["Frequently Used", ["CURRENT", "ENERGY_IMPORT", "ACTIVE_POWER", "POWER_FACTOR", "VOLTAGE_LINE_NEUTRAL"]],
      ["Power", ["APPARENT_ENERGY", "APPARENT_POWER", "ENERGY_IMPORT", "ENERGY_EXPORT", "FREQUENCY", "REACTIVE_POWER", "VOLTAGE_LINE_LINE"]],
      ["Environmental", ["ILLUMINANCE", "HUMIDITY", "TEMPERATURE"]],
      [
        "Misc/Other",
        ["BATTERY_VOLTAGE", "CURRENT_THD", "DEW_POINT", "OCCUPANCY_ACTIVITY", "PHASE_ANGLE", "OCCUPANCY_TIME_SINCE_LAST_EVENT"],
      ],
    ]);
    expect(dataPointVisualOrder(groups)).toHaveLength(ALL.length);
    expect(new Set(dataPointVisualOrder(groups))).toEqual(new Set(ALL.map((p) => p.code)));
  });

  it("Frequently Used is the fixed D67 list: Current, Energy, Power, Power Factor, Voltage", () => {
    const frequentlyUsed = groupDataPoints(ALL).find((g) => g.name === "Frequently Used")!;
    expect(frequentlyUsed.points.map((p) => p.label)).toEqual([
      "Current",
      "Energy",
      "Power",
      "Power Factor",
      "Voltage (Line-Neutral)",
    ]);
  });

  it("Temperature is not in Frequently Used (D67)", () => {
    const frequentlyUsed = groupDataPoints(ALL).find((g) => g.name === "Frequently Used")!;
    expect(frequentlyUsed.points.map((p) => p.label)).not.toContain("Temperature");
  });
});
