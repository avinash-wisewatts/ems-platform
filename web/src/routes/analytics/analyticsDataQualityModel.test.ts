import { describe, expect, it } from "vitest";
import type { AnalyticsSeries } from "../../api/types";
import {
  DQ_TEXT,
  bucketQualityNotes,
  buildDataQuality,
  formatDuration,
  groupByReason,
  notShownReasons,
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
  it("several periods without a break", () => {
    expect(periodRange([pointFixture(1, 1), pointFixture(2, 1), pointFixture(3, 1)], TZ)).toBe(
      "00:15 · 05 Oct 2026 – 00:45 · 05 Oct 2026 · 3 periods",
    );
  });
  it("periods with unaffected periods between them never read as continuous (Amendment 7)", () => {
    expect(periodRange([pointFixture(1, 1), pointFixture(4, 1), pointFixture(9, 1)], TZ)).toBe(
      "3 periods between 00:15 · 05 Oct 2026 and 02:15 · 05 Oct 2026",
    );
  });
  it("daily periods show dates without a time (Amendment 7)", () => {
    const day = (i: number) =>
      pointFixture(0, 1, {
        bucket_start: new Date(Date.parse(SERIES_FROM) + i * 86_400_000).toISOString(),
        bucket_end: new Date(Date.parse(SERIES_FROM) + (i + 1) * 86_400_000).toISOString(),
      });
    expect(periodRange([day(0)], TZ, true)).toBe("05 Oct 2026 · 1 period");
    expect(periodRange([day(0), day(1)], TZ, true)).toBe("05 Oct 2026 – 06 Oct 2026 · 2 periods");
  });
});

describe("notShownReasons -- the approved line per status / reason, never a code", () => {
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
    expect(notShownReasons(notShownFixture("a1", status, reasons), TZ)).toEqual([line]);
  });

  it("before the retention floor names the site-local date data is available from", () => {
    const s = notShownFixture("a1", "RESOLUTION_UNAVAILABLE", ["BEFORE_RETENTION_FLOOR"], {
      resolution_available_from: "2026-06-30T18:30:00Z",
    });
    expect(notShownReasons(s, TZ)).toEqual([
      "Data is not available at this resolution for the full selected range. Data is available from 01 Jul 2026.",
    ]);
  });

  it("several reasons: each approved line, in the table's order (Amendment 7)", () => {
    const s = notShownFixture("a1", "DATA_UNAVAILABLE", ["TIMEZONE_MISMATCH", "CAPTURE_POLICY_GAP"]);
    expect(notShownReasons(s, TZ)).toEqual([DQ_TEXT.reasonPolicyGap, DQ_TEXT.reasonTimezone]);
  });

  it("a retention-floor reason without its date makes no site-wide claim", () => {
    const s = notShownFixture("a1", "RESOLUTION_UNAVAILABLE", ["BEFORE_RETENTION_FLOOR"]);
    expect(notShownReasons(s, TZ)).toEqual([DQ_TEXT.reasonNotAvailable]);
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
      "2 periods between 00:15 · 05 Oct 2026 and 00:45 · 05 Oct 2026",
    ]);
  });

  it("Incomplete: reconstructed intervals count as accounted for; unexpected intervals are not counted", () => {
    const s = seriesFixture("a1", [1, 2]);
    s.points[0] = pointFixture(0, 1, { valid_intervals: 10, reconstructed_intervals: 5, evidence_flags: ["RECONSTRUCTED_TIMING"] });
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

  it("Incomplete: no duration is shown when the interval length is unknown (Amendment 7)", () => {
    const s = seriesFixture("a1", [1]);
    s.points[0] = pointFixture(0, 1, { valid_intervals: 10, expected_intervals: null });
    const [group] = buildDataQuality(input([s]), catalog, TZ);
    expect(group!.entries[0]!.lines).toEqual(["00:00 · 05 Oct 2026 · 1 period"]);
  });

  it("Reconstructed timing follows the evidence flag only (Amendment 6 mapping)", () => {
    const s = seriesFixture("a1", [1]);
    s.points[0] = pointFixture(0, 1, { valid_intervals: 10, reconstructed_intervals: 5 });
    expect(buildDataQuality(input([s]), catalog, TZ)).toEqual([]);
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

  it("measurements: missing samples are Incomplete data without the Energy-only explanation", () => {
    const voltage = seriesFixture("a1", [230, 231], {
      data_point: "VOLTAGE_LINE_NEUTRAL",
      label: "Voltage",
      unit: "V",
      chart_kind: "line",
      aggregation: "mean",
      points: [
        pointFixture(0, 230, { quality: "GOOD", evidence_status: null }),
        pointFixture(1, 231, { valid_intervals: 10, quality: "PARTIAL", evidence_status: null }),
      ],
    });
    const groups = buildDataQuality(input([voltage]), catalog, TZ);
    const incomplete = groups.find((g) => g.id === "incomplete")!;
    expect(incomplete.explanation).toEqual([DQ_TEXT.incompleteExplanation]);
    expect(incomplete.entries[0]!.lines[0]).toBe("Not received: 5 min");
    expect(bucketQualityNotes(voltage, voltage.points[1]!, TZ)).toEqual([DQ_TEXT.tipNotReceived]);
  });

  it("a data point without phases (Frequency) is disclosed as System values under 3 Phase", () => {
    const frequency = seriesFixture("a1", [50], {
      data_point: "FREQUENCY",
      label: "Frequency",
      unit: "Hz",
      chart_kind: "line",
      aggregation: "mean",
    });
    const phase = seriesFixture("a2", [1], { data_point: "ACTIVE_POWER", label: "Power", qualifier: "L1" });
    const groups = buildDataQuality(input([frequency, phase], {}, "three_phase"), catalog, TZ);
    expect(groups.find((g) => g.id === "system-values")!.entries.map((e) => e.name)).toEqual(["Asset a1 · Frequency"]);
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

describe("groupByReason -- repeated identical reasons with a count (Amendment 7)", () => {
  it("groups by identical reason lines, first occurrence first, selections in selection order", () => {
    const groups = buildDataQuality(
      {
        unavailable: [
          { assetId: "x1", dataPoint: "ENERGY_IMPORT" },
          { assetId: "a5", dataPoint: "SOMETHING_NEW" },
        ],
        order: [
          { assetId: "a2", dataPoint: "ENERGY_IMPORT" },
          { assetId: "x1", dataPoint: "ENERGY_IMPORT" },
          { assetId: "a3", dataPoint: "ENERGY_IMPORT" },
          { assetId: "a5", dataPoint: "SOMETHING_NEW" },
          { assetId: "a4", dataPoint: "ENERGY_IMPORT" },
        ],
        response: seriesResponseFixture({
          series: [
            notShownFixture("a2", "NO_DATA", ["NO_DATA_IN_RANGE"]),
            notShownFixture("a3", "NO_DATA", ["NOT_ASSIGNED_IN_RANGE"]),
            notShownFixture("a4", "NO_DATA", ["RANGE_BEFORE_DATA"]),
          ],
        }),
      },
      catalog,
      TZ,
    );
    const [notShown] = groups;
    expect(notShown!.heading).toBe("Series not shown in chart · 5");
    expect(notShown!.reasonGroups!.map((r) => [r.lines, r.entries.map((e) => e.name)])).toEqual([
      [[DQ_TEXT.reasonNoData], ["Asset a2 · Energy", "Asset a4 · Energy"]],
      [[DQ_TEXT.reasonNotAvailable], ["Asset x1 · Energy", "Asset a5 · Data point"]],
      [[DQ_TEXT.reasonNotAssigned], ["Asset a3 · Energy"]],
    ]);
  });

  it("a series with several reasons groups only with identical sets", () => {
    const entries = [
      { key: "1", name: "A", lines: ["x", "y"] },
      { key: "2", name: "B", lines: ["x"] },
      { key: "3", name: "C", lines: ["x", "y"] },
    ];
    expect(groupByReason(entries).map((g) => g.entries.map((e) => e.name))).toEqual([["A", "C"], ["B"]]);
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
