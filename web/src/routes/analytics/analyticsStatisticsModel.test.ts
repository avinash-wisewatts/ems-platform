import { describe, expect, it } from "vitest";
import { buildStatistics } from "./analyticsStatisticsModel";
import { catalogFixture, notShownFixture, pointFixture, seriesFixture, seriesResponseFixture } from "./analyticsTestFixtures";

const summary = { total: 298.1, average: 12.4, min: 3.2, min_at: "2026-10-05T04:00:00Z", max: 20.9, max_at: "2026-10-05T08:45:00Z" };

describe("buildStatistics -- one row per charted series, the API's own summary", () => {
  it("non-OK series are left out; rows carry the API's summary and the series key", () => {
    const model = buildStatistics(
      seriesResponseFixture({
        series: [seriesFixture("a2", [1], { summary }), notShownFixture("a3", "NO_DATA", ["NO_DATA_IN_RANGE"]), seriesFixture("a1", [1], { summary })],
      }),
      catalogFixture(),
    );
    // Same data point: ordered by asset name, not by request order.
    expect(model.rows.map((r) => [r.key, r.name])).toEqual([
      ["a1:ENERGY_IMPORT:TOTAL", "Energy-Asset a1"],
      ["a2:ENERGY_IMPORT:TOTAL", "Energy-Asset a2"],
    ]);
    expect(model.rows[0]).toMatchObject({ total: 298.1, average: 12.4, min: 3.2, max: 20.9, unit: "kWh", kind: "bar" });
    // Minimum / Maximum times are not part of the model any more.
    expect(model.rows[0]).not.toHaveProperty("minAt");
    expect(model.rows[0]).not.toHaveProperty("maxAt");
  });

  it("Total is Energy only: undefined for other data points, and the column only when Energy is charted", () => {
    const power = seriesFixture("a1", [1], {
      data_point: "ACTIVE_POWER",
      label: "Active Power",
      aggregation: "mean",
      chart_kind: "line",
      unit: "kW",
      summary: { ...summary, total: null },
    });
    const onlyPower = buildStatistics(seriesResponseFixture({ series: [power] }));
    expect(onlyPower.showTotal).toBe(false);
    expect(onlyPower.rows[0]!.total).toBeUndefined();
    const mixed = buildStatistics(seriesResponseFixture({ series: [power, seriesFixture("a2", [1], { summary })] }));
    expect(mixed.showTotal).toBe(true);
    // Energy first, whatever the request order.
    expect(mixed.rows.map((r) => r.total)).toEqual([298.1, undefined]);
  });

  it("values the API does not return stay not available; nothing is computed from the points", () => {
    const s = seriesFixture("a1", [5, 7]);
    const [row] = buildStatistics(seriesResponseFixture({ series: [s] })).rows;
    expect(row).toMatchObject({ total: null, average: null, min: null, max: null });
  });

  it("no rows without a response or a charted series", () => {
    expect(buildStatistics(null).rows).toEqual([]);
    expect(buildStatistics(seriesResponseFixture({ series: [notShownFixture("a1", "NOT_AVAILABLE")] })).rows).toEqual([]);
  });

  it("discloses a Minimum or Maximum whose period follows missing readings -- from the API's evidence only (Amendment 7)", () => {
    // Bucket 1 (00:15) is the maximum and carries GAPS_DETECTED; bucket 0 is the minimum without it.
    const s = seriesFixture("a1", [1, 9], {
      summary: { total: 10, average: 5, min: 1, min_at: "2026-10-04T18:30:00.000Z", max: 9, max_at: "2026-10-04T18:45:00.000Z" },
    });
    s.points[1] = pointFixture(1, 9, { evidence_flags: ["GAPS_DETECTED"] });
    const [row] = buildStatistics(seriesResponseFixture({ series: [s] })).rows;
    expect(row).toMatchObject({ minAfterMissing: false, maxAfterMissing: true });
    // A large value alone is never treated as catch-up.
    const big = seriesFixture("a1", [1, 900], {
      summary: { total: 901, average: 450.5, min: 1, min_at: "2026-10-04T18:30:00.000Z", max: 900, max_at: "2026-10-04T18:45:00.000Z" },
    });
    expect(buildStatistics(seriesResponseFixture({ series: [big] })).rows[0]).toMatchObject({ maxAfterMissing: false });
  });

});

describe("buildStatistics -- grouped by data point (Product Owner, 2026-10-10)", () => {
  const line = (assetId: string, dataPoint: string, label: string, overrides: Parameters<typeof seriesFixture>[2] = {}) =>
    seriesFixture(assetId, [1], { data_point: dataPoint, label, aggregation: "mean", chart_kind: "line", unit: "x", ...overrides });

  it("Energy first, then the other data points alphabetically by label", () => {
    const model = buildStatistics(
      seriesResponseFixture({
        series: [
          line("a1", "VOLTAGE_LINE_NEUTRAL", "Voltage"),
          line("a1", "ACTIVE_POWER", "Power"),
          seriesFixture("a1", [1], { data_point: "ENERGY_EXPORT", label: "Energy Export" }),
          line("a1", "CURRENT", "Current"),
          seriesFixture("a1", [1]),
          line("a1", "FREQUENCY", "Frequency"),
        ],
      }),
      catalogFixture(),
    );
    expect(model.groups.map((g) => g.label)).toEqual(["Energy", "Current", "Energy Export", "Frequency", "Power", "Voltage"]);
    expect(model.rows.map((r) => r.name)).toEqual([
      "Energy-Asset a1",
      "Current-Asset a1",
      "Energy Export-Asset a1",
      "Frequency-Asset a1",
      "Power-Asset a1",
      "Voltage-Asset a1",
    ]);
  });

  it("within a data point: asset name in natural order, then phase System, L1, L2, L3", () => {
    const model = buildStatistics(
      seriesResponseFixture({
        phase: "three_phase",
        series: [
          line("a10", "ACTIVE_POWER", "Power", { asset_name: "Chiller 10", qualifier: "L2" }),
          line("a2", "ACTIVE_POWER", "Power", { asset_name: "Chiller 2", qualifier: "L3" }),
          line("a10", "ACTIVE_POWER", "Power", { asset_name: "Chiller 10", qualifier: "L1" }),
          line("a2", "ACTIVE_POWER", "Power", { asset_name: "Chiller 2", qualifier: "L1" }),
          line("ahu", "ACTIVE_POWER", "Power", { asset_name: "ahu 1", qualifier: "TOTAL" }),
        ],
      }),
    );
    expect(model.rows.map((r) => r.key)).toEqual([
      "ahu:ACTIVE_POWER:TOTAL",
      "a2:ACTIVE_POWER:L1",
      "a2:ACTIVE_POWER:L3",
      "a10:ACTIVE_POWER:L1",
      "a10:ACTIVE_POWER:L2",
    ]);
  });

  it("the order does not depend on the request order", () => {
    const series = [
      line("a2", "ACTIVE_POWER", "Power", { asset_name: "B" }),
      seriesFixture("a1", [1], { asset_name: "A" }),
      line("a1", "ACTIVE_POWER", "Power", { asset_name: "A" }),
    ];
    const forward = buildStatistics(seriesResponseFixture({ series })).rows.map((r) => r.key);
    const backward = buildStatistics(seriesResponseFixture({ series: [...series].reverse() })).rows.map((r) => r.key);
    expect(forward).toEqual(backward);
    expect(forward).toEqual(["a1:ENERGY_IMPORT:TOTAL", "a1:ACTIVE_POWER:TOTAL", "a2:ACTIVE_POWER:TOTAL"]);
  });
});

describe("buildStatistics -- group heading fallback (D83)", () => {
  it("a data point without a label in the series or the catalogue reads 'Data point', never its code", () => {
    const unlabeled = seriesFixture("a1", [1], { data_point: "ACTIVE_POWER", label: null, aggregation: "mean", chart_kind: "line", unit: "kW" });
    const model = buildStatistics(seriesResponseFixture({ series: [unlabeled] }), null);
    expect(model.groups.map((g) => g.label)).toEqual(["Data point"]);
    expect(JSON.stringify(model.groups.map((g) => g.label))).not.toContain("ACTIVE_POWER");
  });

  it("the catalogue's label is used before the fallback", () => {
    const unlabeled = seriesFixture("a1", [1], { label: null });
    expect(buildStatistics(seriesResponseFixture({ series: [unlabeled] }), catalogFixture()).groups[0]!.label).toBe("Energy");
  });
});
