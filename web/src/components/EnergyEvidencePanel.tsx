/**
 * Slice C (C4) -- customer-facing presentation of energy evidence.
 *
 * Deliberately independent of QualityIndicator.tsx's five-value lattice
 * (GOOD/GAP/ESTIMATED/INVALID/PARTIAL) -- see web/src/energy/evidence.ts's
 * docstring for why.
 *
 * Data coverage (valid vs. invalid import/export intervals) IS a clean,
 * complementary pair and is presented as a single percentage.
 *
 * Data gaps / meter resets detected / meter rollovers detected / invalid
 * intervals are INDEPENDENT EVIDENCE INDICATORS, not a partition of all
 * intervals -- the same interval can trigger more than one of them at
 * once (see evidence.ts's docstring for the traced source). They are
 * rendered as separate, independently-labelled indicators, each simply
 * "present" or "absent," never summed together or implied to cover all
 * affected intervals between them. No priority-resolved single status is
 * derived or shown.
 *
 * Never renders: device IDs, logical point IDs, raw field names, database
 * table/view/column names, migration numbers, SQL, Grafana identifiers,
 * or internal quality integers.
 */

import type { EnergyEvidenceSummary } from "../energy/evidence";

export function EnergyEvidencePanel({ summary }: { summary: EnergyEvidenceSummary }) {
  if (!summary.hasData) {
    return (
      <p className="hint" data-testid="energy-evidence-no-data">
        No evidence available for this period yet.
      </p>
    );
  }

  const hasAnyIndicator =
    summary.gapIntervalCount > 0 ||
    summary.resetIntervalCount > 0 ||
    summary.rolloverIntervalCount > 0 ||
    summary.invalidIntervalCount > 0;

  return (
    <dl className="energy-evidence" data-testid="energy-evidence-panel">
      <div className="energy-evidence__row">
        <dt>Data coverage</dt>
        <dd data-testid="energy-evidence-coverage">
          {summary.coveragePercent !== null ? `${summary.coveragePercent.toFixed(1)}%` : "—"} of intervals valid (
          {summary.validImportIntervals} of {summary.totalIntervals})
        </dd>
      </div>

      {hasAnyIndicator ? (
        <p className="hint" data-testid="energy-evidence-indicators-note">
          The indicators below are independent -- more than one can apply to the same interval.
        </p>
      ) : null}

      {summary.gapIntervalCount > 0 ? (
        <div className="energy-evidence__row" data-testid="energy-evidence-gaps">
          <dt>Data gaps</dt>
          <dd>
            {summary.gapIntervalCount} interval{summary.gapIntervalCount === 1 ? "" : "s"} with a missing reading
          </dd>
        </div>
      ) : null}

      {summary.resetIntervalCount > 0 ? (
        <div className="energy-evidence__row" data-testid="energy-evidence-resets">
          <dt>Meter resets detected</dt>
          <dd>
            {summary.resetIntervalCount} interval{summary.resetIntervalCount === 1 ? "" : "s"} affected by a meter
            reset
          </dd>
        </div>
      ) : null}

      {summary.rolloverIntervalCount > 0 ? (
        <div className="energy-evidence__row" data-testid="energy-evidence-rollovers">
          <dt>Meter rollovers detected</dt>
          <dd>
            {summary.rolloverIntervalCount} interval{summary.rolloverIntervalCount === 1 ? "" : "s"} affected by a
            meter rollover (handled automatically -- not a data-quality problem)
          </dd>
        </div>
      ) : null}

      {summary.invalidIntervalCount > 0 ? (
        <div className="energy-evidence__row" data-testid="energy-evidence-invalid">
          <dt>Invalid intervals</dt>
          <dd>
            {summary.invalidIntervalCount} interval{summary.invalidIntervalCount === 1 ? "" : "s"} flagged invalid
          </dd>
        </div>
      ) : null}

      {summary.lastSourceBucket !== null ? (
        <div className="energy-evidence__row" data-testid="energy-evidence-freshness">
          <dt>Latest data</dt>
          <dd>{new Date(summary.lastSourceBucket).toLocaleString()}</dd>
        </div>
      ) : null}
    </dl>
  );
}
