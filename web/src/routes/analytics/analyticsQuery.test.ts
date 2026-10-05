import { describe, expect, it } from "vitest";
import {
  DEFAULT_LIMITS,
  INITIAL_DRAFT,
  MESSAGES,
  RESOLUTION_OPTIONS,
  draftsEqual,
  isResolutionAvailable,
  isValidCustomRange,
  rangesEqual,
  limitsFrom,
  planSelections,
  renderedSeriesCount,
  resolveDraftRange,
  validateForUpdate,
  type AnalyticsDraft,
} from "./analyticsQuery";
import { catalogFixture } from "./analyticsTestFixtures";

const catalog = catalogFixture();
const draft = (overrides: Partial<AnalyticsDraft>): AnalyticsDraft => ({ ...INITIAL_DRAFT, ...overrides });

describe("approved wording (canonical docs)", () => {
  it("uses the exact approved texts", () => {
    expect(MESSAGES).toEqual({
      selectAssetAndDataPoint: "Select at least one asset and one data point to update the chart.",
      selectDataPoint: "Select at least one data point to update the chart.",
      selectAsset: "Select at least one asset to update the chart.",
      tooManySeries: "You can display up to 25 series at a time. Reduce your selections and try again.",
      updateFailed: "Unable to load selected data. Please try again.",
      changesNotApplied: "Changes not applied",
      resolutionChangedToAuto:
        "Resolution changed to Auto because the selected resolution is not available for this range.",
      emptyStateTitle: "Select data to explore",
      emptyStateDetail: "Choose an asset and data point to get started.",
      assetLimitReached: "You can select up to 10 assets.",
      dataPointLimitReached: "You can select up to 5 data points.",
      comparisonComingSoon: "Coming soon",
    });
  });

  it("offers the resolutions in display order (EMS-REQ-134)", () => {
    expect(RESOLUTION_OPTIONS.map((o) => o.label)).toEqual(["Auto", "1 minute", "15 minutes", "30 minutes", "1 hour", "1 day"]);
  });
});

describe("custom date ranges (D8, D15, D60)", () => {
  const custom = (fromDate: string, toDate: string, fromTime: string | null = null, toTime: string | null = null) => ({
    kind: "custom" as const,
    fromDate,
    toDate,
    fromTime,
    toTime,
  });

  it("whole local days, the end date inclusive", () => {
    expect(resolveDraftRange(custom("2026-09-01", "2026-09-03"), "Asia/Kolkata")).toEqual({
      from: "2026-08-31T18:30:00.000Z",
      to: "2026-09-03T18:30:00.000Z",
    });
  });

  it("a single day", () => {
    expect(resolveDraftRange(custom("2026-09-01", "2026-09-01"), "Asia/Kolkata")).toEqual({
      from: "2026-08-31T18:30:00.000Z",
      to: "2026-09-01T18:30:00.000Z",
    });
  });

  it("time-of-day refinement to any minute; an omitted time keeps the day boundary", () => {
    expect(resolveDraftRange(custom("2026-09-01", "2026-09-01", "08:17", "17:45"), "Asia/Kolkata")).toEqual({
      from: "2026-09-01T02:47:00.000Z",
      to: "2026-09-01T12:15:00.000Z",
    });
    expect(resolveDraftRange(custom("2026-09-01", "2026-09-02", "08:00"), "Asia/Kolkata")).toEqual({
      from: "2026-09-01T02:30:00.000Z",
      to: "2026-09-02T18:30:00.000Z",
    });
  });

  it("DST: a London day across the autumn change is 25 hours", () => {
    const { from, to } = resolveDraftRange(custom("2026-10-25", "2026-10-25"), "Europe/London");
    expect((Date.parse(to) - Date.parse(from)) / 3_600_000).toBe(25);
  });

  it("valid only with a positive length", () => {
    expect(isValidCustomRange(custom("2026-09-01", "2026-09-01"), "Asia/Kolkata")).toBe(true);
    expect(isValidCustomRange(custom("2026-09-02", "2026-09-01"), "Asia/Kolkata")).toBe(false);
    expect(isValidCustomRange(custom("2026-09-01", "2026-09-01", "10:00", "10:00"), "Asia/Kolkata")).toBe(false);
    expect(isValidCustomRange(custom("2026-09-01", "2026-09-01", "10:00", "09:59"), "Asia/Kolkata")).toBe(false);
    expect(isValidCustomRange(custom("2026-09-01", "2026-09-01", "10:00", "10:01"), "Asia/Kolkata")).toBe(true);
  });

  it("rangesEqual compares kind, dates and times", () => {
    expect(rangesEqual({ kind: "preset", preset: "TODAY" }, { kind: "preset", preset: "TODAY" })).toBe(true);
    expect(rangesEqual({ kind: "preset", preset: "TODAY" }, { kind: "preset", preset: "7D" })).toBe(false);
    expect(rangesEqual({ kind: "preset", preset: "TODAY" }, custom("2026-09-01", "2026-09-01"))).toBe(false);
    expect(rangesEqual(custom("2026-09-01", "2026-09-02"), custom("2026-09-01", "2026-09-02"))).toBe(true);
    expect(rangesEqual(custom("2026-09-01", "2026-09-02"), custom("2026-09-01", "2026-09-02", "08:00"))).toBe(false);
  });

  it("a custom range is a draft change", () => {
    expect(draftsEqual(INITIAL_DRAFT, draft({ range: custom("2026-09-01", "2026-09-01") }))).toBe(false);
  });
});

describe("fresh starting state (D1, D3)", () => {
  it("is Today, Auto, System, nothing selected", () => {
    expect(INITIAL_DRAFT).toEqual({
      range: { kind: "preset", preset: "TODAY" },
      resolution: "auto",
      phase: "system",
      assetIds: [],
      dataPoints: [],
    });
  });

  it("Today resolves to the whole local day in the site timezone (F1)", () => {
    expect(resolveDraftRange(INITIAL_DRAFT.range, "Asia/Kolkata", new Date("2026-06-15T12:00:00Z"))).toEqual({
      from: "2026-06-14T18:30:00.000Z",
      to: "2026-06-15T18:30:00.000Z",
    });
  });
});

describe("draftsEqual", () => {
  it("compares every field, including selection order", () => {
    expect(draftsEqual(INITIAL_DRAFT, { ...INITIAL_DRAFT })).toBe(true);
    expect(draftsEqual(draft({ assetIds: ["a1", "a2"] }), draft({ assetIds: ["a1", "a2"] }))).toBe(true);
    expect(draftsEqual(draft({ assetIds: ["a1", "a2"] }), draft({ assetIds: ["a2", "a1"] }))).toBe(false);
    expect(draftsEqual(INITIAL_DRAFT, draft({ phase: "three_phase" }))).toBe(false);
    expect(draftsEqual(INITIAL_DRAFT, draft({ resolution: "1h" }))).toBe(false);
    expect(draftsEqual(INITIAL_DRAFT, draft({ range: { kind: "preset", preset: "7D" } }))).toBe(false);
  });
});

describe("limits", () => {
  it("come from the catalogue, with the documented defaults until it loads", () => {
    expect(limitsFrom(null)).toEqual(DEFAULT_LIMITS);
    expect(DEFAULT_LIMITS).toEqual({ maxAssets: 10, maxDataPoints: 5, maxSeries: 25 });
    expect(limitsFrom(catalog)).toEqual({ maxAssets: 10, maxDataPoints: 5, maxSeries: 25 });
  });
});

describe("planSelections (D4, D42, D43)", () => {
  it("requests every served combination, assets then data points in selection order", () => {
    const plan = planSelections(draft({ assetIds: ["a2", "a1"], dataPoints: ["ENERGY_EXPORT", "ENERGY_IMPORT"] }), catalog);
    expect(plan.selections).toEqual([
      { assetId: "a2", dataPoint: "ENERGY_EXPORT" },
      { assetId: "a2", dataPoint: "ENERGY_IMPORT" },
      { assetId: "a1", dataPoint: "ENERGY_EXPORT" },
      { assetId: "a1", dataPoint: "ENERGY_IMPORT" },
    ]);
    expect(plan.unavailable).toEqual([]);
  });

  it("keeps combinations the catalogue cannot serve aside, never requesting them", () => {
    const plan = planSelections(draft({ assetIds: ["x1", "a1"], dataPoints: ["ENERGY_IMPORT"] }), catalog);
    expect(plan.selections).toEqual([{ assetId: "a1", dataPoint: "ENERGY_IMPORT" }]);
    expect(plan.unavailable).toEqual([{ assetId: "x1", dataPoint: "ENERGY_IMPORT" }]);
  });
});

describe("renderedSeriesCount (D70)", () => {
  it("counts one series per pair under System", () => {
    const { selections } = planSelections(draft({ assetIds: ["a1", "a3"], dataPoints: ["ENERGY_IMPORT"] }), catalog);
    expect(renderedSeriesCount(selections, "system", catalog)).toBe(2);
  });

  it("counts three per pair with per-phase values under 3 Phase, one otherwise (System value, D57)", () => {
    const { selections } = planSelections(
      draft({ assetIds: ["a1", "a3"], dataPoints: ["ENERGY_IMPORT", "ENERGY_EXPORT"] }),
      catalog,
    );
    // a1 Energy has phases (3); a1 Export, a3 Energy, a3 Export do not (1 each).
    expect(renderedSeriesCount(selections, "three_phase", catalog)).toBe(6);
  });
});

describe("validateForUpdate (D45, D46, D48, D78)", () => {
  it("nothing selected / no data point / no asset", () => {
    expect(validateForUpdate(INITIAL_DRAFT, catalog)).toBe(MESSAGES.selectAssetAndDataPoint);
    expect(validateForUpdate(draft({ assetIds: ["a1"] }), catalog)).toBe(MESSAGES.selectDataPoint);
    expect(validateForUpdate(draft({ dataPoints: ["ENERGY_IMPORT"] }), catalog)).toBe(MESSAGES.selectAsset);
  });

  it("allows rendered series up to the limit and rejects them above it", () => {
    // 10 assets x 2 data points = 20 under System.
    const ten = Array.from({ length: 10 }, (_, i) => `a${i + 3}`); // a3..a12, no phases
    expect(validateForUpdate(draft({ assetIds: ten, dataPoints: ["ENERGY_IMPORT", "ENERGY_EXPORT"] }), catalog)).toBeNull();
    // With a1 and a2 under 3 Phase: a1,a2 Energy (3 each) + 8 other assets' Energy (8) + 10 x Export (10) = 24.
    const withPhases = ["a1", "a2", ...Array.from({ length: 8 }, (_, i) => `a${i + 3}`)];
    const threePhase = draft({ assetIds: withPhases, dataPoints: ["ENERGY_IMPORT", "ENERGY_EXPORT"], phase: "three_phase" });
    expect(validateForUpdate(threePhase, catalog)).toBeNull();
    // A lower server limit (e.g. 23) rejects the same selection.
    expect(validateForUpdate(threePhase, catalogFixture({ limits: { max_data_points: 5, max_assets: 10, max_series: 23 } }))).toBe(
      MESSAGES.tooManySeries,
    );
  });

  it("combinations the catalogue cannot serve do not count toward the 25", () => {
    const d = draft({ assetIds: ["x1"], dataPoints: ["ENERGY_IMPORT", "ENERGY_EXPORT"] });
    expect(validateForUpdate(d, catalogFixture({ limits: { max_data_points: 5, max_assets: 10, max_series: 1 } }))).toBeNull();
  });
});

describe("isResolutionAvailable (EMS-REQ-134)", () => {
  const sevenDays = { from: "2026-06-08T18:30:00.000Z", to: "2026-06-15T18:30:00.000Z" };
  it("Auto is always available", () => {
    expect(isResolutionAvailable("auto", sevenDays, catalog)).toBe(true);
  });
  it("a resolution is available when the range fits its maximum window", () => {
    expect(isResolutionAvailable("15m", sevenDays, catalog)).toBe(true);
    expect(isResolutionAvailable("1m", sevenDays, catalog)).toBe(false); // 3-day maximum
  });
  it("without a catalogue nothing is ruled out", () => {
    expect(isResolutionAvailable("1m", sevenDays, null)).toBe(true);
  });
});
