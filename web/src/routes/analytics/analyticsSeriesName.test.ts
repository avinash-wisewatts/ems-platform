import { describe, expect, it } from "vitest";
import type { AnalyticsSeries } from "../../api/types";
import { buildChartModel } from "./analyticsChartModel";
import { buildDataQuality } from "./analyticsDataQualityModel";
import { chartSeriesName, selectionName, seriesName } from "./analyticsSeriesName";
import { buildStatistics } from "./analyticsStatisticsModel";
import { catalogFixture, seriesFixture, seriesResponseFixture } from "./analyticsTestFixtures";

/** The naming convention (PO, 2026-10-09): chart "<Asset>-<code>",
 *  Statistics / Data quality "<Measurement>-<code><phase>". */
const POINTS: [code: string, label: string, system: string, phases: [string, string, string], qualifiers?: [string, string, string]][] = [
  ["ACTIVE_POWER", "Power", "P", ["P1", "P2", "P3"]],
  ["REACTIVE_POWER", "Reactive Power", "Q", ["Q1", "Q2", "Q3"]],
  ["VOLTAGE_LINE_NEUTRAL", "Voltage", "V", ["V1", "V2", "V3"]],
  ["CURRENT", "Current", "I", ["I1", "I2", "I3"]],
  ["POWER_FACTOR", "Power Factor", "PF", ["PF1", "PF2", "PF3"]],
  ["ENERGY_IMPORT", "Energy", "Energy", ["E1", "E2", "E3"]],
  ["ENERGY_EXPORT", "Energy Export", "Energy Export", ["Ex1", "Ex2", "Ex3"]],
  ["VOLTAGE_LINE_LINE", "Line to Line Voltage", "Line to Line Voltage", ["V12", "V23", "V31"], ["L12", "L23", "L31"]],
];

const named = (dataPoint: string, label: string | null, qualifier = "TOTAL", extra: Partial<AnalyticsSeries> = {}) =>
  seriesFixture("a1", [1], { asset_name: "Chiller 1", data_point: dataPoint, label, qualifier, ...extra });

describe("chart legend and tooltip: <Asset name>-<code>", () => {
  it.each(POINTS)("%s System and 3 Phase", (code, label, system, phases, qualifiers = ["L1", "L2", "L3"]) => {
    expect(chartSeriesName(named(code, label))).toBe(`Chiller 1-${system}`);
    expect(qualifiers.map((q) => chartSeriesName(named(code, label, q)))).toEqual(phases.map((p) => `Chiller 1-${p}`));
  });
  it("Frequency is System only: Chiller 1-F", () => {
    expect(chartSeriesName(named("FREQUENCY", "Frequency"))).toBe("Chiller 1-F");
  });
});

describe("Statistics and Data quality: <Measurement name>-<code><phase>", () => {
  it.each(POINTS)("%s System has no suffix; phases carry the code", (code, label, _system, phases, qualifiers = ["L1", "L2", "L3"]) => {
    expect(seriesName(named(code, label))).toBe(label);
    expect(qualifiers.map((q) => seriesName(named(code, label, q)))).toEqual(phases.map((p) => `${label}-${p}`));
  });
  it("Frequency is System only: Frequency", () => {
    expect(seriesName(named("FREQUENCY", "Frequency"))).toBe("Frequency");
  });
  it("a selection without a series reads as its measurement name", () => {
    expect(selectionName(catalogFixture(), "ENERGY_EXPORT")).toBe("Energy Export");
  });
});

describe("fallback labels: never a qualifier, registry code or internal identifier", () => {
  const catalog = catalogFixture();
  it("missing asset name and label come from the catalogue", () => {
    const s = named("ENERGY_IMPORT", null, "L2", { asset_name: null });
    expect(chartSeriesName(s, catalog)).toBe("Asset a1-E2");
    expect(seriesName(s, catalog)).toBe("Energy-E2");
  });
  it("neither the series nor the catalogue knows it: generic words", () => {
    const s = seriesFixture("zz", [1], { asset_name: null, data_point: "APPARENT_POWER", label: null });
    expect(chartSeriesName(s, catalog)).toBe("Asset-Data point");
    expect(seriesName(s, catalog)).toBe("Data point");
    expect(selectionName(catalog, "APPARENT_POWER")).toBe("Data point");
  });
  it("a future data point without a code reads by its label", () => {
    expect(chartSeriesName(named("APPARENT_POWER", "Apparent Power"))).toBe("Chiller 1-Apparent Power");
    expect(chartSeriesName(named("APPARENT_POWER", "Apparent Power", "L1"))).toBe("Chiller 1-Apparent Power 1");
    expect(seriesName(named("APPARENT_POWER", "Apparent Power", "L1"))).toBe("Apparent Power 1");
  });
  it("an unknown qualifier is never shown (treated as the series' System name)", () => {
    expect(chartSeriesName(named("CURRENT", "Current", "NEUTRAL"))).toBe("Chiller 1-I");
    expect(seriesName(named("CURRENT", "Current", "NEUTRAL"))).toBe("Current");
  });
});

describe("one response: every context names the same series by its own rule", () => {
  const phases = ["L1", "L2", "L3"].map((q) =>
    named("REACTIVE_POWER", "Reactive Power", q, { aggregation: "mean", chart_kind: "line", unit: "kvar" }),
  );
  phases[1]!.points[0]!.evidence_flags = ["GAPS_DETECTED"];
  const voltage = named("VOLTAGE_LINE_NEUTRAL", "Voltage", "TOTAL", { aggregation: "mean", chart_kind: "line", unit: "V" });
  const response = seriesResponseFixture({ series: [...phases, voltage] });
  const range = { from: response.from, to: response.to };

  it("chart legend / tooltip use the asset name", () => {
    expect(buildChartModel(response, range).series.map((s) => s.name)).toEqual([
      "Chiller 1-Q1",
      "Chiller 1-Q2",
      "Chiller 1-Q3",
      "Chiller 1-V",
    ]);
  });
  it("Statistics uses the measurement name", () => {
    expect(buildStatistics(response).rows.map((r) => r.name)).toEqual([
      "Reactive Power-Q1",
      "Reactive Power-Q2",
      "Reactive Power-Q3",
      "Voltage",
    ]);
  });
  it("Data quality uses the measurement name", () => {
    const groups = buildDataQuality({ unavailable: [], order: [], response: { ...response, phase: "three_phase" } }, null, "Asia/Kolkata");
    expect(groups.find((g) => g.id === "after-missing")!.entries.map((e) => e.name)).toEqual(["Reactive Power-Q2"]);
    expect(groups.find((g) => g.id === "system-values")!.entries.map((e) => e.name)).toEqual(["Voltage"]);
  });
});
