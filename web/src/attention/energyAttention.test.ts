import { describe, expect, it } from "vitest";
import { evaluateEnergyAttention } from "./energyAttention";
import type { EnergyMaterialityPolicy } from "./materiality-policy";
import { MVP3_MATERIALITY_POLICY } from "./materiality-policy";
import type { TypicalReferenceResult } from "../energy/comparison";
import type { EnergyEvidenceSummary } from "../energy/evidence";

const WINDOW = { from: "2026-09-01T00:00:00Z", to: "2026-09-08T00:00:00Z" };
const INVESTIGATE_PATH = "/features/energy";
const SITE_NAME = "Alpha One";

const EVIDENCE: EnergyEvidenceSummary = {
  hasData: true,
  totalIntervals: 100,
  validImportIntervals: 100,
  invalidImportIntervals: 0,
  validExportIntervals: 100,
  invalidExportIntervals: 0,
  gapIntervalCount: 0,
  resetIntervalCount: 0,
  rolloverIntervalCount: 0,
  invalidIntervalCount: 0,
  firstSourceBucket: "2026-09-01T00:00:00Z",
  lastSourceBucket: "2026-09-07T23:00:00Z",
  coveragePercent: 100,
};

/** Builds a sufficient, current-having TypicalReferenceResult with the
 *  given current/typical totals -- deltaPercent/deltaKwh are computed the
 *  same way buildTypicalReferenceResult itself computes them, so these
 *  fixtures stay faithful to the real (unmodified) Slice C calculation. */
function referenceResult(
  overrides: Partial<TypicalReferenceResult> & { currentTotalKwh?: number | null; comparisonTotalKwh?: number | null } = {},
): TypicalReferenceResult {
  const currentTotalKwh = overrides.currentTotalKwh ?? 115;
  const comparisonTotalKwh = overrides.comparisonTotalKwh ?? 100;
  const deltaKwh =
    currentTotalKwh !== null && comparisonTotalKwh !== null ? currentTotalKwh - comparisonTotalKwh : null;
  const deltaPercent =
    deltaKwh !== null && comparisonTotalKwh !== null && comparisonTotalKwh !== 0
      ? (deltaKwh / comparisonTotalKwh) * 100
      : null;

  return {
    basis: "TYPICAL_HISTORICAL_REFERENCE",
    currentTotalKwh,
    comparisonTotalKwh,
    deltaKwh,
    deltaPercent,
    currentHasData: true,
    comparisonHasData: true,
    requestedPeriodCount: 8,
    windowsWithDataCount: 8,
    eligiblePeriodCount: 8,
    sufficient: true,
    windows: [],
    ...overrides,
  };
}

function evaluate(result: TypicalReferenceResult, policy: EnergyMaterialityPolicy = MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION) {
  return evaluateEnergyAttention({
    result,
    evidence: EVIDENCE,
    policy,
    siteName: SITE_NAME,
    window: WINDOW,
    investigatePath: INVESTIGATE_PATH,
  });
}

describe("evaluateEnergyAttention -- MVP-3 approved 15% rule", () => {
  it("triggers HIGH at exactly +15% (inclusive boundary)", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 115, comparisonTotalKwh: 100 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("HIGH");
    expect(item!.what).toBe("Unusually high consumption");
  });

  it("triggers HIGH above +15%", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 130, comparisonTotalKwh: 100 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("HIGH");
  });

  it("triggers LOW at exactly -15% (inclusive boundary)", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 85, comparisonTotalKwh: 100 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("LOW");
    expect(item!.what).toBe("Unusually low consumption");
  });

  it("triggers LOW below -15%", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 70, comparisonTotalKwh: 100 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("LOW");
  });

  it("does not trigger strictly within +/-15%", () => {
    expect(evaluate(referenceResult({ currentTotalKwh: 114.9, comparisonTotalKwh: 100 }))).toBeNull();
    expect(evaluate(referenceResult({ currentTotalKwh: 100, comparisonTotalKwh: 100 }))).toBeNull();
    expect(evaluate(referenceResult({ currentTotalKwh: 85.1, comparisonTotalKwh: 100 }))).toBeNull();
  });

  it("does not trigger when the historical reference is insufficient, regardless of the raw numbers", () => {
    const item = evaluate(
      referenceResult({
        sufficient: false,
        comparisonTotalKwh: null,
        deltaKwh: null,
        deltaPercent: null,
        currentTotalKwh: 999,
      }),
    );
    expect(item).toBeNull();
  });

  it("does not trigger when the current value is missing", () => {
    const item = evaluate(
      referenceResult({ currentHasData: false, currentTotalKwh: null, deltaKwh: null, deltaPercent: null }),
    );
    expect(item).toBeNull();
  });

  it("does not trigger when deltaPercent is null for any other reason", () => {
    const item = evaluate(referenceResult({ deltaPercent: null }));
    expect(item).toBeNull();
  });

  it("does not trigger, and does not throw, when the typical reference is zero/near-zero (already guarded upstream to null)", () => {
    // buildTypicalReferenceResult never divides by a zero comparisonTotalKwh --
    // it returns deltaPercent: null in that case. This fixture mirrors that.
    const item = evaluate(
      referenceResult({ comparisonTotalKwh: 0, currentTotalKwh: 50, deltaKwh: 50, deltaPercent: null }),
    );
    expect(item).toBeNull();
  });

  it("attaches evidence and data-quality fields without altering the trigger decision (invalid/gap/reset never suppress)", () => {
    const dirtyEvidence: EnergyEvidenceSummary = {
      ...EVIDENCE,
      coveragePercent: 40,
      gapIntervalCount: 3,
      resetIntervalCount: 1,
      rolloverIntervalCount: 1,
      invalidIntervalCount: 2,
    };
    const item = evaluateEnergyAttention({
      result: referenceResult({ currentTotalKwh: 130, comparisonTotalKwh: 100 }),
      evidence: dirtyEvidence,
      policy: MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION,
      siteName: SITE_NAME,
      window: WINDOW,
      investigatePath: INVESTIGATE_PATH,
    });
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("HIGH");
    expect(item!.dataQuality.coveragePercent).toBe(40);
    expect(item!.dataQuality.gapIntervalCount).toBe(3);
    expect(item!.dataQuality.resetIntervalCount).toBe(1);
    expect(item!.dataQuality.rolloverIntervalCount).toBe(1);
    expect(item!.dataQuality.invalidIntervalCount).toBe(2);
  });

  it("tolerates a null evidence summary (evidence call not yet resolved) without throwing", () => {
    const item = evaluateEnergyAttention({
      result: referenceResult({ currentTotalKwh: 130, comparisonTotalKwh: 100 }),
      evidence: null,
      policy: MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION,
      siteName: SITE_NAME,
      window: WINDOW,
      investigatePath: INVESTIGATE_PATH,
    });
    expect(item).not.toBeNull();
    expect(item!.dataQuality.coveragePercent).toBeNull();
  });

  it("the threshold is read from the policy argument, not hardcoded -- a looser policy triggers where the MVP-3 policy would not", () => {
    const loosePolicy: EnergyMaterialityPolicy = {
      metric: "ENERGY_CONSUMPTION",
      method: "PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE",
      thresholdPercent: 10,
    };
    const result = referenceResult({ currentTotalKwh: 112, comparisonTotalKwh: 100 }); // +12%
    expect(evaluate(result, MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION)).toBeNull(); // 15% policy: no
    expect(evaluate(result, loosePolicy)!.direction).toBe("HIGH"); // 10% policy: yes
  });

  it("the trigger text includes both the actual deviation and the configured threshold", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 118, comparisonTotalKwh: 100 }));
    expect(item!.trigger).toContain("+18.0%");
    expect(item!.trigger).toContain("15%");
  });
});

describe("evaluateEnergyAttention -- floating-point boundary regression (PR #50 review finding)", () => {
  // Round test totals (115 vs 100) happen to land on EXACTLY 15/-15 in
  // IEEE-754 arithmetic, which is why the tests above never exposed this.
  // Real measured kWh totals are essentially never round numbers -- these
  // fixtures use non-round totals whose TRUE mathematical deviation is
  // exactly +/-15%, but whose FLOATING-POINT computation lands a hair off
  // it (verified via `node -e`, not hand-picked to merely "look realistic"):
  //   (158.01 - 137.4) / 137.4 * 100  === 14.999999999999988  (not 15)
  //   (75.905 - 89.3)  / 89.3  * 100  === -14.999999999999996 (not -15)
  // Before the fix, both of these failed to trigger under a raw `>=`/`<=`
  // comparison -- a false negative at the exact boundary the product rule
  // requires to trigger.

  it("a mathematically exact +15% deviation triggers HIGH, even though it computes to 14.999999999999988", () => {
    const result = referenceResult({ currentTotalKwh: 158.01, comparisonTotalKwh: 137.4 });
    expect(result.deltaPercent).toBeCloseTo(15, 9);
    expect(result.deltaPercent).not.toBe(15); // proves this is the float-noise case, not a round number

    const item = evaluate(result);
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("HIGH");
  });

  it("a mathematically exact -15% deviation triggers LOW, even though it computes to -14.999999999999996", () => {
    const result = referenceResult({ currentTotalKwh: 75.905, comparisonTotalKwh: 89.3 });
    expect(result.deltaPercent).toBeCloseTo(-15, 9);
    expect(result.deltaPercent).not.toBe(-15); // proves this is the float-noise case, not a round number

    const item = evaluate(result);
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("LOW");
  });

  it("a genuine +14.9% deviation (100x larger than the float-noise margin) still does not trigger", () => {
    // 137.4 * 1.149 -- a REAL difference from +15%, not floating-point noise.
    const item = evaluate(referenceResult({ currentTotalKwh: 137.4 * 1.149, comparisonTotalKwh: 137.4 }));
    expect(item).toBeNull();
  });

  it("a genuine -14.9% deviation still does not trigger", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 89.3 * 0.851, comparisonTotalKwh: 89.3 }));
    expect(item).toBeNull();
  });

  it("a genuine +16% deviation (clearly outside the threshold) still triggers HIGH", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 137.4 * 1.16, comparisonTotalKwh: 137.4 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("HIGH");
  });

  it("a genuine -16% deviation still triggers LOW", () => {
    const item = evaluate(referenceResult({ currentTotalKwh: 89.3 * 0.84, comparisonTotalKwh: 89.3 }));
    expect(item).not.toBeNull();
    expect(item!.direction).toBe("LOW");
  });
});
