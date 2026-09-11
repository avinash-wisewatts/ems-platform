/**
 * Slice A -- Energy Foundation. Pure computation of a comparison result from
 * two already-fetched GET /sites/{id}/energy/consumption responses (current
 * period + comparison period). No network, no state -- easy to unit test and
 * reusable by later slices (Energy Performance formalizes this further).
 *
 * Historical comparison only (Q54/Q55/Q56/Q97): PREVIOUS_PERIOD and
 * SAME_PERIOD_PREVIOUSLY for this increment. No predictive/adaptive logic of
 * any kind.
 */

import type { ComparisonBasis } from "../time/ranges";
import type { EnergyConsumptionResponse } from "../api/types";

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
