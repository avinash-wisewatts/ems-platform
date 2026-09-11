/**
 * Slice A -- Energy Foundation. Pure computation of a comparison result from
 * two already-fetched GET /sites/{id}/energy/consumption responses (current
 * period + comparison period). No network, no state -- easy to unit test and
 * reusable by later slices (Energy Performance formalizes this further).
 *
 * Historical comparison only (Q54/Q55/Q56/Q97): PREVIOUS_PERIOD and
 * SAME_PERIOD_PREVIOUSLY for this increment. No predictive/adaptive logic of
 * any kind.
 *
 * Slice C adds buildTypicalReferenceResult below -- a third, still purely
 * historical/statistical comparison: "typical historical consumption," the
 * MEDIAN of up to 8 coverage-eligible comparable historical periods,
 * computed server-side (migration 236) and merely adapted into the shared
 * ComparisonResult shape here. It is CALCULATED, not predicted: no fitting,
 * no smoothing, no seasonality model -- see that function's docstring.
 */

import type { ComparisonBasis } from "../time/ranges";
import type { EnergyConsumptionResponse, EnergyTypicalReferenceResponse } from "../api/types";

export type ComparisonResult = {
  basis: ComparisonBasis;
  currentTotalKwh: number | null;
  comparisonTotalKwh: number | null;
  deltaKwh: number | null;
  deltaPercent: number | null;
  currentHasData: boolean;
  comparisonHasData: boolean;
};

/** Sum of import_kwh across the series; null if no point carries a value. */
function sumImportKwh(response: EnergyConsumptionResponse): number | null {
  if (response.no_data) return null;
  let total = 0;
  let any = false;
  for (const point of response.series) {
    if (point.import_kwh !== null) {
      total += point.import_kwh;
      any = true;
    }
  }
  return any ? total : null;
}

export function buildComparisonResult(
  basis: ComparisonBasis,
  current: EnergyConsumptionResponse,
  comparison: EnergyConsumptionResponse,
): ComparisonResult {
  const currentTotalKwh = sumImportKwh(current);
  const comparisonTotalKwh = sumImportKwh(comparison);

  const deltaKwh =
    currentTotalKwh !== null && comparisonTotalKwh !== null
      ? currentTotalKwh - comparisonTotalKwh
      : null;

  const deltaPercent =
    deltaKwh !== null && comparisonTotalKwh !== null && comparisonTotalKwh !== 0
      ? (deltaKwh / comparisonTotalKwh) * 100
      : null;

  return {
    basis,
    currentTotalKwh,
    comparisonTotalKwh,
    deltaKwh,
    deltaPercent,
    currentHasData: !current.no_data,
    comparisonHasData: !comparison.no_data,
  };
}

/**
 * Slice C -- Typical historical consumption (comparable-period reference).
 * Structurally extends ComparisonResult (basis:
 * "TYPICAL_HISTORICAL_REFERENCE") so the existing, unmodified StatusBadge
 * works unchanged, plus the extra fields the UI needs to explain an
 * "insufficient history" state, and the evidence, honestly -- see the
 * approved Slice C Historical Comparison specification.
 *
 * requestedPeriodCount / windowsWithDataCount / eligiblePeriodCount /
 * sufficient / windows are ALL computed server-side (migration 236 +
 * build_energy_typical_reference_response) and simply passed through here
 * unchanged -- this module does no eligibility, coverage, or median
 * computation of its own. That is a deliberate design choice: unlike the
 * two PREVIOUS_PERIOD/SAME_PERIOD_PREVIOUSLY bases above (which fetch raw
 * series and compute their own sums client-side), the comparable-period
 * selection depends on the site's own timezone and the daily historian's
 * evidence counters -- data the frontend does not have and must not
 * recompute.
 */
export type TypicalReferenceResult = ComparisonResult & {
  requestedPeriodCount: number;
  windowsWithDataCount: number;
  eligiblePeriodCount: number;
  sufficient: boolean;
  windows: EnergyTypicalReferenceResponse["windows"];
};

/**
 * Pure adaptation of an already-fetched current-period consumption response
 * plus an already-fetched typical-reference response (see
 * planEnergyTypicalReferenceRequest / GET .../typical-reference) into the
 * shared ComparisonResult shape. No network, no state, no re-computation of
 * anything the server already computed.
 *
 * comparisonTotalKwh is `reference.typical_kwh` verbatim -- null whenever
 * `reference.sufficient` is false, exactly matching the server's own
 * insufficient-history rule (never a partial or fabricated figure computed
 * here).
 */
export function buildTypicalReferenceResult(
  current: EnergyConsumptionResponse,
  reference: EnergyTypicalReferenceResponse,
): TypicalReferenceResult {
  const currentTotalKwh = sumImportKwh(current);
  const comparisonTotalKwh = reference.sufficient ? reference.typical_kwh : null;

  const deltaKwh =
    currentTotalKwh !== null && comparisonTotalKwh !== null
      ? currentTotalKwh - comparisonTotalKwh
      : null;

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
    currentHasData: !current.no_data,
    comparisonHasData: reference.sufficient,
    requestedPeriodCount: reference.requested_period_count,
    windowsWithDataCount: reference.windows_with_data_count,
    eligiblePeriodCount: reference.eligible_period_count,
    sufficient: reference.sufficient,
    windows: reference.windows,
  };
}
