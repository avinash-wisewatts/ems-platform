/**
 * Asset View -- Energy tile calculation. Pure computation over two
 * already-fetched GET .../assets/{id}/energy/consumption responses (the
 * selected window + the immediately preceding window of the same length),
 * mirroring energy/comparison.ts#buildComparisonResult's own summation
 * exactly (sum import_consumption_kwh, delta, delta percent) -- not reused
 * directly because that function's type is shaped for site responses
 * (site_id/resolution fields this asset-scoped response doesn't have), but
 * the arithmetic is identical, not reinvented.
 *
 * Evidence: reset_detected/gap_detected are per-interval booleans already
 * returned by this same response (unlike the site-level Slice C evidence
 * endpoint, energy/evidence.ts, this asset-scoped response has no separate
 * counters endpoint of its own) -- counted here, over the currently
 * displayed window only, so the Energy tile can disclose a plain-language
 * caveat rather than presenting a total as if it were unconditionally
 * complete.
 */

import type { AssetEnergyIntervalsResponse } from "../../api/types";

export type AssetEnergyComparison = {
  currentTotalKwh: number | null;
  comparisonTotalKwh: number | null;
  deltaKwh: number | null;
  deltaPercent: number | null;
  currentHasData: boolean;
  comparisonHasData: boolean;
  /** Count of intervals in the CURRENT window flagged reset_detected/
   *  gap_detected -- independent counters, not mutually exclusive, not a
   *  partition of currentTotalKwh's basis. */
  resetIntervalCount: number;
  gapIntervalCount: number;
};

function sumImportKwh(response: AssetEnergyIntervalsResponse): number | null {
  if (response.no_data) return null;
  let total = 0;
  let any = false;
  for (const point of response.series) {
    if (point.import_consumption_kwh !== null) {
      total += point.import_consumption_kwh;
      any = true;
    }
  }
  return any ? total : null;
}

export function buildAssetEnergyComparison(
  current: AssetEnergyIntervalsResponse,
  comparison: AssetEnergyIntervalsResponse,
): AssetEnergyComparison {
  const currentTotalKwh = sumImportKwh(current);
  const comparisonTotalKwh = sumImportKwh(comparison);

  const deltaKwh =
    currentTotalKwh !== null && comparisonTotalKwh !== null ? currentTotalKwh - comparisonTotalKwh : null;

  const deltaPercent =
    deltaKwh !== null && comparisonTotalKwh !== null && comparisonTotalKwh !== 0
      ? (deltaKwh / comparisonTotalKwh) * 100
      : null;

  let resetIntervalCount = 0;
  let gapIntervalCount = 0;
  for (const point of current.series) {
    if (point.reset_detected) resetIntervalCount += 1;
    if (point.gap_detected) gapIntervalCount += 1;
  }

  return {
    currentTotalKwh,
    comparisonTotalKwh,
    deltaKwh,
    deltaPercent,
    currentHasData: !current.no_data,
    comparisonHasData: !comparison.no_data,
    resetIntervalCount,
    gapIntervalCount,
  };
}
