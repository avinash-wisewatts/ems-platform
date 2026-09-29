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
  /** "This period": everything recorded so far in the displayed range. */
  currentTotalKwh: number | null;
  /** The actual consumption the comparison is made on: the elapsed portion
   *  matched on both sides (Product Owner decision, 2026-09-29). Equal to
   *  currentTotalKwh when no cut applies. */
  basisCurrentKwh: number | null;
  /** End of that portion (ISO), or null when the whole response is compared. */
  comparedUntil: string | null;
  comparisonTotalKwh: number | null;
  /** basisCurrentKwh - comparisonTotalKwh. */
  deltaKwh: number | null;
  deltaPercent: number | null;
  currentHasData: boolean;
  comparisonHasData: boolean;
};

/** Sum of import_kwh across the series (optionally only buckets starting
 *  before `until`); null if no point carries a value. */
function sumImportKwh(response: EnergyConsumptionResponse, until?: string | null): number | null {
  if (response.no_data) return null;
  const limit = until ? Date.parse(until) : Number.POSITIVE_INFINITY;
  let total = 0;
  let any = false;
  for (const point of response.series) {
    if (point.import_kwh !== null && Date.parse(point.bucket_start) < limit) {
      total += point.import_kwh;
      any = true;
    }
  }
  return any ? total : null;
}

function delta(basisCurrentKwh: number | null, comparisonTotalKwh: number | null) {
  const deltaKwh =
    basisCurrentKwh !== null && comparisonTotalKwh !== null ? basisCurrentKwh - comparisonTotalKwh : null;
  const deltaPercent =
    deltaKwh !== null && comparisonTotalKwh !== null && comparisonTotalKwh !== 0
      ? (deltaKwh / comparisonTotalKwh) * 100
      : null;
  return { deltaKwh, deltaPercent };
}

/**
 * PREVIOUS_PERIOD / SAME_PERIOD_PREVIOUSLY. `comparison` is the historical
 * window covering the same elapsed portion as [current range start,
 * `comparedUntil`) (planEnergyComparisonRequest), or null when nothing has
 * elapsed yet. Unelapsed time never enters the delta.
 */
export function buildComparisonResult(
  basis: ComparisonBasis,
  current: EnergyConsumptionResponse,
  comparison: EnergyConsumptionResponse | null,
  comparedUntil: string | null = null,
): ComparisonResult {
  const currentTotalKwh = sumImportKwh(current);
  const basisCurrentKwh = sumImportKwh(current, comparedUntil);
  const comparisonTotalKwh = comparison ? sumImportKwh(comparison) : null;
  return {
    basis,
    currentTotalKwh,
    basisCurrentKwh,
    comparedUntil,
    comparisonTotalKwh,
    ...delta(basisCurrentKwh, comparisonTotalKwh),
    currentHasData: !current.no_data,
    comparisonHasData: comparison !== null && !comparison.no_data,
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
  /** Set when the compared days and the fixed reference window have
   *  different day counts, so the comparison was made per calendar day. */
  normalizedPerCalendarDay: boolean;
};

/** The complete elapsed local days compared against Typical
 *  (planEnergyTypicalReferenceRequest's basisRange / basisDays /
 *  referenceDays): their actual consumption, read at 1d, or null when no
 *  complete day has elapsed. */
export type TypicalReferenceBasis = {
  basisResponse: EnergyConsumptionResponse | null;
  basisUntil: string | null;
  basisDays: number;
  referenceDays: number;
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
  basis?: TypicalReferenceBasis,
): TypicalReferenceResult {
  const currentTotalKwh = sumImportKwh(current);
  const typicalKwh = reference.sufficient ? reference.typical_kwh : null;

  let basisCurrentKwh = currentTotalKwh;
  let comparisonTotalKwh = typicalKwh;
  let normalizedPerCalendarDay = false;
  if (basis !== undefined) {
    // Product Owner decisions (2026-09-29): only COMPLETE elapsed local days
    // are compared with Typical (the daily historian cannot represent part of
    // a day), and when their count differs from the reference window's,
    // average consumption per calendar day is compared -- the typical per day
    // is expressed for the compared days, so the delta and percentage equal
    // the per-day comparison. No complete day yet (Today): no comparison.
    const hasBasis = basis.basisResponse !== null && basis.basisDays > 0 && basis.referenceDays > 0;
    basisCurrentKwh = hasBasis && basis.basisResponse ? sumImportKwh(basis.basisResponse) : null;
    normalizedPerCalendarDay = hasBasis && basis.basisDays !== basis.referenceDays;
    comparisonTotalKwh =
      !hasBasis || typicalKwh === null
        ? null
        : normalizedPerCalendarDay
          ? (typicalKwh / basis.referenceDays) * basis.basisDays
          : typicalKwh;
  }

  return {
    basis: "TYPICAL_HISTORICAL_REFERENCE",
    currentTotalKwh,
    basisCurrentKwh,
    comparedUntil: basis?.basisUntil ?? null,
    comparisonTotalKwh,
    ...delta(basisCurrentKwh, comparisonTotalKwh),
    currentHasData: !current.no_data,
    comparisonHasData: reference.sufficient && comparisonTotalKwh !== null,
    requestedPeriodCount: reference.requested_period_count,
    windowsWithDataCount: reference.windows_with_data_count,
    eligiblePeriodCount: reference.eligible_period_count,
    sufficient: reference.sufficient,
    windows: reference.windows,
    normalizedPerCalendarDay,
  };
}
