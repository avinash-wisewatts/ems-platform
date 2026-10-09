import { describe, expect, it } from "vitest";
import type { AnalyticsSeries } from "../../api/types";
import {
  DQ_TEXT,
  bucketQualityNotes,
  buildDataQuality,
  formatDuration,
  notShownReason,
  periodRange,
  type DataQualityInput,
} from "./analyticsDataQualityModel";
import {
  SERIES_FROM,
  catalogFixture,
  notShownFixture,
  pointFixture,
  seriesFixture,
  seriesResponseFixture,
} from "./analyticsTestFixtures";

const TZ = "Asia/Kolkata";
const catalog = catalogFixture();

function input(series: AnalyticsSeries[], extra: Partial<DataQualityInput> = {}, phase: "system" | "three_phase" = "system"): DataQualityInput {
  const order = series.map((s) => ({ assetId: s.asset_id, dataPoint: s.data_point }));
  return {
    unavailable: [],
    order,
    response: seriesResponseFixture({ from: SERIES_FROM, as_of: "2026-10-05T06:30:00Z", phase, series }),
    ...extra,
  };
}

describe("formatDuration -- two largest units", () => {
  it.each([
    [0, "0 min"],
    [45, "45 s"],
    [60, "1 min"],
    [8100, "2 h 15 min"],
    [7200, "2 h"],
    [97_200, "1 d 3 h"],
    [86_400 + 300, "1 d"],
    [2700, "45 min"],
  ])("%s s -> %s", (seconds, text) => {
    expect(formatDuration(seconds)).toBe(text);
  });
});

describe("periodRange -- site-local, first and last affected period", () => {
  it("one period", () => {
    expect(periodRange([pointFixture(0, 1)], TZ)).toBe("00:00 · 05 Oct 2026 · 1 period");
  });
  it("several periods", () => {
    expect(periodRange([pointFixture(1, 1), pointFixture(4, 1), pointFixture(9, 1)], TZ)).toBe(
      "00:15 · 05 Oct 2026 – 02:15 · 05 Oct 2026 · 3 periods",
    );
  });
});

describe("notShownReason -- one approved line per status / reason, never a code", () => {
  it.each<[AnalyticsSeries["status"], AnalyticsSeries["status_reasons"], string]>([
    ["NO_DATA", ["NOT_ASSIGNED_IN_RANGE"], DQ_TEXT.reasonNotAssigned],
    ["NO_DATA", ["RANGE_IN_FUTURE"], DQ_TEXT.reasonFuture],
    ["NO_DATA", ["NO_DATA_EVER"], DQ_TEXT.reasonNoData],
    ["NO_DATA", ["RANGE_BEFORE_DATA"], DQ_TEXT.reasonNoData],
    ["NO_DATA", ["RANGE_AFTER_LATEST_DATA"], DQ_TEXT.reasonNoData],
    ["NO_DATA", ["NO_DATA_IN_RANGE"], DQ_TEXT.reasonNoData],
    ["NOT_AVAILABLE", [], DQ_TEXT.reasonNotAvailable],
    ["RESOLUTION_UNAVAILABLE", ["CAPTURE_INTERVAL_TOO_COARSE"], DQ_TEXT.reasonResolutionCoarse],
    ["DATA_UNAVAILABLE", ["CAPTURE_POLICY_GAP"], DQ_TEXT.reasonPolicyGap],
    ["DATA_UNAVAILABLE", ["CAPTURE_POLICY_CHANGE"], DQ_TEXT.reasonPolicyChange],
    ["DATA_UNAVAILABLE", ["TIMEZONE_MISMATCH"], DQ_TEXT.reasonTimezone],
  ])("%s / %s", (status, reasons, line) => {
    expect(notShownReason(notShownFixture("a1", status, reasons), TZ)).toBe(line);
  });

  it("before the retention floor names the site-local date data is available from", () => {
    const s = notShownFixture("a1", "RESOLUTION_UNAVAILABLE", ["BEFORE_RETENTION_FLOOR"], {
      resolution_available_from: "2026-06-30T18:30:00Z",
    });
    expect(notShownReason(s, TZ)).toBe(
      "Data is not available at this resolution for the full selected range. Data is available from 01 Jul 2026.",
    );
  });
});

describe("buildDataQuality -- groups", () => {
  it("is empty when no condition applies (the section is absent)", () => {
    expect(buildDataQuality(input([seriesFixture("a1", [1, 2, 3])]), catalog, TZ)).toEqual([]);
  });

  it("all seven groups, in the fixed order, with the approved headings", () => {
    const incomplete = seriesFixture("a1", [1, 2]);
    incomplete.points[1] = pointFixture(1, 2, { valid_intervals: 10 });
    const reset = seriesFixture("a2", [1, 2]);
    reset.points[0] = pointFixture(0, 1, { evidence_flags: ["RESET_DETECTED"] });
    const stale = seriesFixture("a3", [1, null], { stale: true, last_data_at: "2026-10-04T18:45:00Z" });
    stale.points[1] = pointFixture(1, null, { data_state: "AFTER_LATEST_DATA", assigned_expected_intervals: 0 });
    const afterMissing = seriesFixture("a4", [1, 2]);
    afterMissing.points[1] = pointFixture(1, 2, { evidence_flags: ["GAPS_DETECTED"] });
    const reconstructed = seriesFixture("a5", [1, 2]);
    reconstructed.points[0] = pointFixture(0, 1, { valid_intervals: 10, reconstructed_intervals: 5, evidence_flags: ["RECONSTRUCTED_TIMING"] });
    const notShown = notShownFixture("a6", "NO_DATA", ["NO_DATA_IN_RANGE"]);

    const groups = buildDataQuality(
      input([incomplete, reset, stale, afterMissing, reconstructed, notShown], {}, "three_phase"),
      catalog,
      TZ,
    );
    expect(groups.map((g) => g.heading)).toEqual([
      "Series not shown in chart · 1",
      "Incomplete data · 1 series",
      "Meter resets and rollovers · 1 series",
      "No recent data · 1 series",
      "Values after missing readings · 1 series",
      "Reconstructed timing · 1 series",
      // Every charted series is System (TOTAL) under 3 Phase.
      "Shown as System values · 5 series",
    ]);
    // Everything a customer reads (React keys aside).
    const text = JSON.stringify(groups.map((g) => [g.heading, g.explanation, g.entries.map((e) => [e.name, e.lines])]));
    for (const code of ["NO_DATA", "RESET_DETECTED", "GAPS_DETECTED", "RECONSTRUCTED_TIMING", "TOTAL", "ENERGY_IMPORT"]) {
      expect(text).not.toContain(code);
    }
  });

  it("Series not shown: selection order, including selections the catalogue cannot serve (D4, D6)", () => {
    const groups = buildDataQuality(
      {
        unavailable: [{ assetId: "x1", dataPoint: "ENERGY_IMPORT" }],
        order: [
          { assetId: "a2", dataPoint: "ENERGY_IMPORT" },
          { assetId: "x1", dataPoint: "ENERGY_IMPORT" },
          { assetId: "a1", dataPoint: "ENERGY_IMPORT" },
        ],
        response: seriesResponseFixture({
          series: [notShownFixture("a2", "NO_DATA", ["NOT_ASSIGNED_IN_RANGE"]), seriesFixture("a1", [1])],
        }),
      },
      catalog,
      TZ,
    );
    expect(groups).toHaveLength(1);
    expect(groups[0]!.entries).toEqual([
      { key: "a2:ENERGY_IMPORT:TOTAL", name: "Asset a2 · Energy", lines: [DQ_TEXT.reasonNotAssigned] },
      { key: "unavailable:x1:ENERGY_IMPORT", name: "Asset x1 · Energy", lines: [DQ_TEXT.reasonNotAvailable] },
    ]);
  });

  it("a NOT_AVAILABLE series without a name or label is named from the catalogue, never by its code", () => {
    const s = notShownFixture("a3", "NOT_AVAILABLE", [], { asset_name: null, label: null });
    const groups = buildDataQuality(input([s]), catalog, TZ);
    expect(groups[0]!.entries[0]!.name).toBe("Asset a3 · Energy");
    const unknown = notShownFixture("gone", "NOT_AVAILABLE", [], { asset_name: null, label: null, data_point: "SOMETHING_NEW" });
    expect(buildDataQuality(input([unknown]), catalog, TZ)[0]!.entries[0]!.name).toBe("Asset · Data point");
  });

  it("Incomplete: not received and could not be used as durations at the capture interval, and the period range", () => {
    const s = seriesFixture("a1", [1, 2, 3, 4]);
    // 15 expected: 10 valid + 2 rejected -> 3 not received, 2 not usable.
    s.points[1] = pointFixture(1, 2, { valid_intervals: 10, invalid_intervals: 2, evidence_flags: ["INVALID_INTERVALS"] });
    // A whole period without readings.
    s.points[3] = pointFixture(3, null);
    const [group] = buildDataQuality(input([s]), catalog, TZ);
    expect(group!.id).toBe("incomplete");
    expect(group!.explanation).toEqual([DQ_TEXT.incompleteExplanation, DQ_TEXT.incompleteEnergyExplanation]);
    expect(group!.entries[0]!.lines).toEqual([
      "Not received: 18 min · Could not be used: 2 min",
      "00:15 · 05 Oct 2026 – 00:45 · 05 Oct 2026 · 2 periods",
    ]);
  });

  it("Incomplete: reconstructed intervals count as accounted for; unexpected intervals are not counted", () => {
    const s = seriesFixture("a1", [1, 2]);
    s.points[0] = pointFixture(0, 1, { valid_intervals: 10, reconstructed_intervals: 5 });
    // Unassigned / before data: nothing expected.
    s.points[1] = pointFixture(1, null, { data_state: "NOT_ASSIGNED", assigned_expected_intervals: 0 });
    expect(buildDataQuality(input([s]), catalog, TZ).map((g) => g.id)).toEqual(["reconstructed"]);
  });

  it("Incomplete: non-Energy series get no Energy-only sentence", () => {
    const s = seriesFixture("a1", [1, 2], { aggregation: "mean", chart_kind: "line", unit: "kW", data_point: "ACTIVE_POWER", label: "Active Power" });
    s.points[0] = pointFixture(0, 1, { valid_intervals: 14 });
    const [group] = buildDataQuality(input([s]), catalog, TZ);
    expect(group!.explanation).toEqual([DQ_TEXT.incompleteExplanation]);
  });

  it("Meter resets and rollovers: one line per event, in time order", () => {
    const s = seriesFixture("a1", [1, 2, 3]);
    s.points[0] = pointFixture(0, 1, { evidence_flags: ["ROLLOVER_DETECTED"] });
    s.points[2] = pointFixture(2, 3, { evidence_flags: ["RESET_DETECTED"] });
    const [group] = buildDataQuality(input([s]), catalog, TZ);
    expect(group!.entries[0]!.lines).toEqual(["Meter rollover · 00:00 · 05 Oct 2026", "Meter reset · 00:30 · 05 Oct 2026"]);
  });

  it("No recent data: latest data and the time before the chart was updated; only for stale series", () => {
    const stale = seriesFixture("a1", [1], { stale: true, last_data_at: "2026-10-05T04:15:00Z" });
    const [group] = buildDataQuality(input([stale]), catalog, TZ);
    expect(group!.entries[0]!.lines).toEqual(["Latest data: 09:45 · 05 Oct 2026 · 2 h 15 min before the chart was updated"]);
    // stale null (unverified capture path) or false: not reported.
    expect(buildDataQuality(input([seriesFixture("a1", [1], { stale: null, last_data_at: "2026-10-05T04:15:00Z" })]), catalog, TZ)).toEqual([]);
  });

  it("Shown as System values: only under 3 Phase, series name only", () => {
    const s = seriesFixture("a1", [1]);
    expect(buildDataQuality(input([s]), catalog, TZ)).toEqual([]);
    const [group] = buildDataQuality(input([s], {}, "three_phase"), catalog, TZ);
    expect(group!.entries).toEqual([{ key: "a1:ENERGY_IMPORT:TOTAL", name: "Asset a1 · Energy", lines: [] }]);
    // Per-phase series are not System values.
    const phase = seriesFixture("a2", [1], { qualifier: "L1" });
    expect(buildDataQuality(input([phase], {}, "three_phase"), catalog, TZ)).toEqual([]);
  });

  it("charted series follow the Statistics (response) order within a group", () => {
    const a = seriesFixture("a2", [1], { stale: true, last_data_at: "2026-10-05T06:00:00Z" });
    const b = seriesFixture("a1", [1], { stale: true, last_data_at: "2026-10-05T06:00:00Z" });
    const [group] = buildDataQuality(input([a, b]), catalog, TZ);
    expect(group!.entries.map((e) => e.name)).toEqual(["Asset a2 · Energy", "Asset a1 · Energy"]);
  });
});

describe("bucketQualityNotes -- the tooltip's lines for one period, in group order", () => {
  const s = seriesFixture("a1", [1], { stale: true, last_data_at: "2026-10-04T18:45:00Z" });

  it("none for a complete, measured period", () => {
    expect(bucketQualityNotes(s, pointFixture(0, 1), TZ)).toEqual([]);
  });

  it.each([
    [{ valid_intervals: 12 }, DQ_TEXT.tipNotReceived],
    [{ valid_intervals: 12, invalid_intervals: 3 }, DQ_TEXT.tipNotUsed],
    [{ valid_intervals: 10, invalid_intervals: 3 }, DQ_TEXT.tipNotReceivedOrNotUsed],
    [{ valid_intervals: 0 }, DQ_TEXT.tipNoneReceived],
    [{ valid_intervals: 0, invalid_intervals: 15 }, DQ_TEXT.tipNoneUsable],
  ])("incomplete %o -> %s", (counts, line) => {
    expect(bucketQualityNotes(s, pointFixture(0, 1, counts), TZ)).toEqual([line]);
  });

  it("every condition at once, in group order", () => {
    const p = pointFixture(1, null, {
      data_state: "AFTER_LATEST_DATA",
      valid_intervals: 0,
      assigned_expected_intervals: 15,
      evidence_flags: ["RECONSTRUCTED_TIMING", "GAPS_DETECTED", "ROLLOVER_DETECTED", "RESET_DETECTED"],
    });
    expect(bucketQualityNotes(s, p, TZ)).toEqual([
      DQ_TEXT.tipNoneReceived,
      DQ_TEXT.tipReset,
      DQ_TEXT.tipRollover,
      "No data available after 00:15 · 05 Oct 2026",
      DQ_TEXT.tipAfterMissing,
      DQ_TEXT.tipReconstructed,
    ]);
  });

  it("no 'No data available after' for future periods or series that are not stale", () => {
    const future = pointFixture(1, null, { data_state: "AFTER_LATEST_DATA", bucket_state: "FUTURE", assigned_expected_intervals: 0 });
    expect(bucketQualityNotes(s, future, TZ)).toEqual([]);
    const fresh = { ...s, stale: false };
    const after = pointFixture(1, null, { data_state: "AFTER_LATEST_DATA", assigned_expected_intervals: 0 });
    expect(bucketQualityNotes(fresh, after, TZ)).toEqual([]);
    // stale null: the capture path is unverified, so nothing is claimed.
    expect(bucketQualityNotes({ ...s, stale: null }, after, TZ)).toEqual([]);
  });
});
