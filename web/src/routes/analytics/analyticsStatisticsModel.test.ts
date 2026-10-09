import { describe, expect, it } from "vitest";
import { buildStatistics } from "./analyticsStatisticsModel";
import { catalogFixture, notShownFixture, pointFixture, seriesFixture, seriesResponseFixture } from "./analyticsTestFixtures";

const summary = { total: 298.1, average: 12.4, min: 3.2, min_at: "2026-10-05T04:00:00Z", max: 20.9, max_at: "2026-10-05T08:45:00Z" };

describe("buildStatistics -- one row per charted series, the API's own summary", () => {
  it("rows in chart order; non-OK series are left out", () => {
    const model = buildStatistics(
      seriesResponseFixture({
        series: [seriesFixture("a2", [1], { summary }), notShownFixture("a3", "NO_DATA", ["NO_DATA_IN_RANGE"]), seriesFixture("a1", [1], { summary })],
      }),
      catalogFixture(),
    );
    expect(model.rows.map((r) => [r.name, r.index])).toEqual([
      ["Asset a2 · Energy", 0],
      ["Asset a1 · Energy", 1],
    ]);
    expect(model.rows[0]).toMatchObject({ total: 298.1, average: 12.4, min: 3.2, minAt: summary.min_at, max: 20.9, maxAt: summary.max_at, unit: "kWh" });
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
    expect(mixed.rows.map((r) => r.total)).toEqual([undefined, 298.1]);
  });

  it("values the API does not return stay not available; nothing is computed from the points", () => {
    const s = seriesFixture("a1", [5, 7]);
    const [row] = buildStatistics(seriesResponseFixture({ series: [s] })).rows;
    expect(row).toMatchObject({ total: null, average: null, min: null, minAt: null, max: null, maxAt: null });
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

  it("daily resolution is flagged for date-only times", () => {
    expect(buildStatistics(seriesResponseFixture({ resolution: "1d", series: [seriesFixture("a1", [1])] })).dateOnly).toBe(true);
    expect(buildStatistics(seriesResponseFixture({ resolution: "1h", series: [seriesFixture("a1", [1])] })).dateOnly).toBe(false);
  });
});
