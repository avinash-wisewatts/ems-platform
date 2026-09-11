/**
 * Slice C (C4) -- Energy evidence. Pure derivation from an already-fetched
 * GET /sites/{id}/energy/consumption/evidence response. No network, no
 * state -- same discipline as comparison.ts.
 *
 * Deliberately independent of web/src/components/QualityIndicator.tsx's
 * five-value lattice (GOOD/GAP/ESTIMATED/INVALID/PARTIAL) -- that lattice
 * is not used here, and no product decision has mapped one onto the other.
 *
 * Two different kinds of counter are summed below, and they behave
 * differently:
 *
 *  - validImportIntervals/invalidImportIntervals (and their export
 *    counterparts) ARE a genuine complementary pair: every interval is
 *    exactly one or the other, so coveragePercent below is a safe ratio.
 *
 *  - gapIntervalCount/resetIntervalCount/rolloverIntervalCount/
 *    invalidIntervalCount are INDEPENDENT EVIDENCE COUNTERS, each summed
 *    from its own boolean flag on the underlying rows (traced, by static
 *    reading of the migration/ddl files during the Slice C review -- NOT
 *    confirmed against a live catalog -- to
 *    analytics.v_energy_semantic_rollup_15min, postgres/ddl/
 *    147_combined_energy_quality_counters.sql). They are NOT a
 *    mutually-exclusive classification and are NOT guaranteed to sum to
 *    totalIntervals -- a single interval can be counted in more than one
 *    of the four simultaneously. Do not add them together and present the
 *    result as "all affected intervals"; render each independently (see
 *    EnergyEvidencePanel). No priority-resolved single status is derived
 *    here or anywhere in Slice C.
 */

import type { EnergyConsumptionEvidenceResponse } from "../api/types";

export type EnergyEvidenceSummary = {
  hasData: boolean;
  totalIntervals: number;
  validImportIntervals: number;
  invalidImportIntervals: number;
  validExportIntervals: number;
  invalidExportIntervals: number;
  /** Independent evidence counters -- see module docstring. Not a
   *  partition of totalIntervals; may overlap with each other. */
  gapIntervalCount: number;
  resetIntervalCount: number;
  rolloverIntervalCount: number;
  invalidIntervalCount: number;
  firstSourceBucket: string | null;
  lastSourceBucket: string | null;
  /** valid_import_intervals / source_interval_count, summed across the
   *  range, as a percentage. Null when there are zero total intervals to
   *  divide by (no basis for a percentage -- never rendered as 0%). */
  coveragePercent: number | null;
};

const EMPTY_SUMMARY: EnergyEvidenceSummary = {
  hasData: false,
  totalIntervals: 0,
  validImportIntervals: 0,
  invalidImportIntervals: 0,
  validExportIntervals: 0,
  invalidExportIntervals: 0,
  gapIntervalCount: 0,
  resetIntervalCount: 0,
  rolloverIntervalCount: 0,
  invalidIntervalCount: 0,
  firstSourceBucket: null,
  lastSourceBucket: null,
  coveragePercent: null,
};

export function summarizeEnergyEvidence(
  response: EnergyConsumptionEvidenceResponse,
): EnergyEvidenceSummary {
  if (response.no_data || response.series.length === 0) {
    return EMPTY_SUMMARY;
  }

  let totalIntervals = 0;
  let validImportIntervals = 0;
  let invalidImportIntervals = 0;
  let validExportIntervals = 0;
  let invalidExportIntervals = 0;
  let gapIntervalCount = 0;
  let resetIntervalCount = 0;
  let rolloverIntervalCount = 0;
  let invalidIntervalCount = 0;
  let firstSourceBucket: string | null = null;
  let lastSourceBucket: string | null = null;

  for (const point of response.series) {
    totalIntervals += point.source_interval_count;
    validImportIntervals += point.valid_import_intervals;
    invalidImportIntervals += point.invalid_import_intervals;
    validExportIntervals += point.valid_export_intervals;
    invalidExportIntervals += point.invalid_export_intervals;
    gapIntervalCount += point.gap_interval_count;
    resetIntervalCount += point.reset_interval_count;
    rolloverIntervalCount += point.rollover_interval_count;
    invalidIntervalCount += point.invalid_interval_count;

    if (
      point.first_source_bucket !== null &&
      (firstSourceBucket === null || point.first_source_bucket < firstSourceBucket)
    ) {
      firstSourceBucket = point.first_source_bucket;
    }
    if (
      point.last_source_bucket !== null &&
      (lastSourceBucket === null || point.last_source_bucket > lastSourceBucket)
    ) {
      lastSourceBucket = point.last_source_bucket;
    }
  }

  return {
    hasData: true,
    totalIntervals,
    validImportIntervals,
    invalidImportIntervals,
    validExportIntervals,
    invalidExportIntervals,
    gapIntervalCount,
    resetIntervalCount,
    rolloverIntervalCount,
    invalidIntervalCount,
    firstSourceBucket,
    lastSourceBucket,
    coveragePercent: totalIntervals > 0 ? (validImportIntervals / totalIntervals) * 100 : null,
  };
}
