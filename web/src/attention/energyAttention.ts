/**
 * MVP-3 -- the single approved Attention rule: Energy Consumption deviation
 * from Slice C's typical historical reference, per the approved MVP-3
 * decision pack. Pure function -- no network, no state; consumes results
 * that EnergyOverview's own TYPICAL_HISTORICAL_REFERENCE path already
 * computes (buildTypicalReferenceResult, energy/comparison.ts) and already
 * fetches (energy/evidence.ts's summarizeEnergyEvidence). Introduces NO
 * second historical-baseline mechanism -- migration 236 / Slice C remain
 * the only source of the reference value.
 *
 * Rule (exact, per the approved decision pack):
 *   - No Attention when `!result.sufficient` (insufficient historical
 *     reference) or `!result.currentHasData` (missing current value) or
 *     `result.deltaPercent === null` (covers the zero/near-zero-reference
 *     case too -- buildTypicalReferenceResult already returns null there).
 *   - deltaPercent >= +threshold  -> HIGH ("unusually high consumption").
 *   - deltaPercent <= -threshold  -> LOW  ("unusually low consumption").
 *   - Strictly between -threshold and +threshold -> no Attention.
 *   - Exactly +/-threshold triggers (>=/<=, per the approved wording).
 *
 * Gap/reset/rollover/invalid counters on the CURRENT period never suppress
 * or alter this calculation -- they are attached to the item's dataQuality
 * field only, mirroring how Slice C's own comparable-window evidence is
 * "still included, never hidden."
 */

import type { EnergyEvidenceSummary } from "../energy/evidence";
import type { TypicalReferenceResult } from "../energy/comparison";
import type { EnergyMaterialityPolicy } from "./materiality-policy";
import type { AttentionItem } from "./types";

export type EnergyAttentionInput = {
  result: TypicalReferenceResult;
  /** null when the evidence endpoint's own call hasn't resolved / had no
   *  data -- the Attention item is still produced (evidence is descriptive,
   *  never gating); dataQuality fields fall back to "not reported". */
  evidence: EnergyEvidenceSummary | null;
  policy: EnergyMaterialityPolicy;
  siteName: string;
  /** The evaluated period -- MUST be the same window passed to both the
   *  consumption and typical-reference requests (see ranges.ts). */
  window: { from: string; to: string };
  /** In-app path to the full Energy screen, for "Investigate". */
  investigatePath: string;
};

function formatDeltaPercent(deltaPercent: number): string {
  const sign = deltaPercent >= 0 ? "+" : "";
  return `${sign}${deltaPercent.toFixed(1)}%`;
}

export function evaluateEnergyAttention({
  result,
  evidence,
  policy,
  siteName,
  window,
  investigatePath,
}: EnergyAttentionInput): AttentionItem | null {
  if (!result.sufficient || !result.currentHasData || result.deltaPercent === null) {
    return null;
  }

  const deltaPercent = result.deltaPercent;
  const threshold = policy.thresholdPercent;

  let direction: "HIGH" | "LOW";
  if (deltaPercent >= threshold) {
    direction = "HIGH";
  } else if (deltaPercent <= -threshold) {
    direction = "LOW";
  } else {
    return null;
  }

  return {
    metric: "ENERGY_CONSUMPTION",
    direction,
    what: direction === "HIGH" ? "Unusually high consumption" : "Unusually low consumption",
    where: siteName,
    when: window,
    trigger: `${formatDeltaPercent(deltaPercent)} vs. typical historical consumption (threshold: ${threshold}%)`,
    evidence: {
      eligiblePeriodCount: result.eligiblePeriodCount,
      requestedPeriodCount: result.requestedPeriodCount,
    },
    dataQuality: {
      coveragePercent: evidence?.coveragePercent ?? null,
      gapIntervalCount: evidence?.gapIntervalCount ?? 0,
      resetIntervalCount: evidence?.resetIntervalCount ?? 0,
      rolloverIntervalCount: evidence?.rolloverIntervalCount ?? 0,
      invalidIntervalCount: evidence?.invalidIntervalCount ?? 0,
    },
    investigatePath,
  };
}
