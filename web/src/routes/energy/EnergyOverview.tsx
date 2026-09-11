/**
 * Slice A/C -- Energy Performance. The core customer-facing analytical
 * screen, composing the shared grammar:
 *
 *   Current Value -> Comparison -> Trend -> Status -> Evidence
 *
 * Answers: "How is my energy performing, and what evidence do I have for
 * that conclusion?" (Q97), and -- for the Slice C basis specifically --
 * "how is my energy consumption performing compared with what is normally
 * seen for this site and this type of period?" (approved Slice C
 * Historical Comparison decision pack). Built almost entirely on the
 * existing, UNMODIFIED GET /sites/{id}/energy/consumption endpoint (Slice
 * A: called twice for PREVIOUS_PERIOD/SAME_PERIOD_PREVIOUSLY; Slice C:
 * called once, alongside one call to the new, additive GET .../typical-
 * reference endpoint) plus GET .../energy/consumption/evidence (migration
 * 235) for the current period's own Evidence section. No call in this file
 * touches or changes the existing consumption contract.
 *
 * Historical comparison only (Q54/Q55/Q56/Q97): PREVIOUS_PERIOD,
 * SAME_PERIOD_PREVIOUSLY (Slice A), and TYPICAL_HISTORICAL_REFERENCE
 * (Slice C -- the median of up to 8 coverage-eligible comparable historical
 * periods, computed server-side by migration 236). NOT present, by design:
 * configured expectation (Q54-B -- no schema/shape/owner decided yet) and
 * any predictive/adaptive/fitted baseline (Phase 13 -- explicitly deferred,
 * gated on Phase 11). "Typical historical consumption" is a deterministic
 * historical statistic, never presented as a prediction or expectation.
 *
 * Evidence / Data Quality (Slice C): the CURRENT period's own evidence
 * reads GET .../energy/consumption/evidence (migration 235's parallel read
 * of the same two historians) and renders via EnergyEvidencePanel. The
 * TYPICAL_HISTORICAL_REFERENCE basis additionally surfaces evidence for
 * its own comparable historical windows (gap/reset/rollover/invalid counts
 * returned directly by migration 236 -- no dependency on migration 235).
 * Both are independent, possibly-overlapping counters, deliberately NOT
 * forced through QualityIndicator's unrelated five-value lattice (see
 * web/src/energy/evidence.ts).
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import {
  getSiteEnergyConsumption,
  getSiteEnergyConsumptionEvidence,
  getSiteEnergyTypicalReference,
} from "../../api/endpoints";
import type {
  EnergyConsumptionEvidenceResponse,
  EnergyConsumptionResponse,
  EnergyTypicalReferenceResponse,
} from "../../api/types";
import {
  planEnergyComparisonRequest,
  planEnergyRequest,
  planEnergyTypicalReferenceRequest,
  type ComparisonBasis,
  type TimeRangePreset,
  COMPARISON_BASIS_LABELS,
} from "../../time/ranges";
import {
  buildComparisonResult,
  buildTypicalReferenceResult,
  type ComparisonResult,
  type TypicalReferenceResult,
} from "../../energy/comparison";
import { summarizeEnergyEvidence } from "../../energy/evidence";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { TimeRangePicker } from "../../components/TimeRangePicker";
import { StatusBadge } from "../../components/StatusBadge";
import { EnergyEvidencePanel } from "../../components/EnergyEvidencePanel";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

const COMPARISON_BASES: readonly ComparisonBasis[] = [
  "PREVIOUS_PERIOD",
  "SAME_PERIOD_PREVIOUSLY",
  "TYPICAL_HISTORICAL_REFERENCE",
];

function toChartPoints(response: EnergyConsumptionResponse): ChartPoint[] {
  return response.series.map((point) => ({
    t: Date.parse(point.bucket_start),
    value: point.import_kwh,
  }));
}

/** Count of ELIGIBLE (included) comparable windows that carried a given
 *  evidence flag -- used only to word the "N of M included periods had a
 *  reset" note. Excluded windows are deliberately not counted here; they
 *  were excluded for coverage reasons, not because of these flags. */
function countEligibleWindowsWithFlag(
  windows: EnergyTypicalReferenceResponse["windows"],
  flag: "gap_interval_count" | "reset_interval_count" | "rollover_interval_count" | "invalid_interval_count",
): number {
  return windows.filter((w) => w.eligible && w[flag] > 0).length;
}

export function EnergyOverview() {
  const { selectedSite } = useTenant();
  const [preset, setPreset] = useState<TimeRangePreset>("7D");
  const [basis, setBasis] = useState<ComparisonBasis>("PREVIOUS_PERIOD");
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [unsupportedReason, setUnsupportedReason] = useState<string | null>(null);
  const [current, setCurrent] = useState<EnergyConsumptionResponse | null>(null);
  // PREVIOUS_PERIOD / SAME_PERIOD_PREVIOUSLY (Slice A): one comparison response.
  const [comparison, setComparison] = useState<EnergyConsumptionResponse | null>(null);
  // TYPICAL_HISTORICAL_REFERENCE (Slice C): the complete server-computed
  // reference -- one bounded call, no frontend N+1.
  const [typicalReference, setTypicalReference] = useState<EnergyTypicalReferenceResponse | null>(null);
  // Evidence (Slice C, C4): the current period's coverage/gap/reset/rollover
  // counters, from the additive GET .../energy/consumption/evidence endpoint.
  const [evidence, setEvidence] = useState<EnergyConsumptionEvidenceResponse | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    setUnsupportedReason(null);

    function fail(err: unknown) {
      if (!active) return;
      setError(err);
      setStatus("error");
    }

    function resetToUnsupported(reason: string) {
      setUnsupportedReason(reason);
      setStatus("ready");
      setCurrent(null);
      setComparison(null);
      setTypicalReference(null);
      setEvidence(null);
    }

    if (basis === "TYPICAL_HISTORICAL_REFERENCE") {
      const consumptionPlan = planEnergyRequest(preset);
      const referencePlan = planEnergyTypicalReferenceRequest(preset);
      if (!consumptionPlan.supported) {
        resetToUnsupported(consumptionPlan.reason);
        return;
      }
      if (!referencePlan.supported) {
        resetToUnsupported(referencePlan.reason);
        return;
      }

      Promise.all([
        getSiteEnergyConsumption(selectedSite.site_id, {
          resolution: consumptionPlan.resolution,
          ...consumptionPlan.range,
        }),
        getSiteEnergyTypicalReference(selectedSite.site_id, referencePlan.current),
        getSiteEnergyConsumptionEvidence(selectedSite.site_id, {
          resolution: consumptionPlan.resolution,
          ...consumptionPlan.range,
        }),
      ])
        .then(([currentRes, referenceRes, evidenceRes]) => {
          if (!active) return;
          setCurrent(currentRes);
          setTypicalReference(referenceRes);
          setComparison(null);
          setEvidence(evidenceRes);
          setStatus("ready");
        })
        .catch(fail);

      return () => {
        active = false;
      };
    }

    const plan = planEnergyComparisonRequest(preset, basis);
    if (!plan.supported) {
      resetToUnsupported(plan.reason);
      return;
    }

    Promise.all([
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: plan.resolution, ...plan.current }),
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: plan.resolution, ...plan.comparison }),
      getSiteEnergyConsumptionEvidence(selectedSite.site_id, { resolution: plan.resolution, ...plan.current }),
    ])
      .then(([currentRes, comparisonRes, evidenceRes]) => {
        if (!active) return;
        setCurrent(currentRes);
        setComparison(comparisonRes);
        setTypicalReference(null);
        setEvidence(evidenceRes);
        setStatus("ready");
      })
      .catch(fail);

    return () => {
      active = false;
    };
  }, [selectedSite, preset, basis, nonce]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  const result: ComparisonResult | TypicalReferenceResult | null =
    current === null
      ? null
      : basis === "TYPICAL_HISTORICAL_REFERENCE"
        ? typicalReference !== null
          ? buildTypicalReferenceResult(current, typicalReference)
          : null
        : comparison !== null
          ? buildComparisonResult(basis, current, comparison)
          : null;

  const referenceResult: TypicalReferenceResult | null =
    result !== null && basis === "TYPICAL_HISTORICAL_REFERENCE" ? (result as TypicalReferenceResult) : null;

  const evidenceSummary = evidence !== null ? summarizeEnergyEvidence(evidence) : null;

  return (
    <div className="page page--energy-overview" data-testid="page-energy-overview">
      <HierarchyCrumb siteName={selectedSite.site_name} leaf={{ label: "Energy" }} />
      <h1>Energy consumption</h1>

      <div className="energy-controls">
        <TimeRangePicker value={preset} onChange={setPreset} dataKind="energy" />
        <div role="group" aria-label="Compare to" className="comparison-basis-picker">
          {COMPARISON_BASES.map((b) => (
            <button
              key={b}
              type="button"
              aria-pressed={basis === b}
              onClick={() => setBasis(b)}
              data-testid={`comparison-basis-${b}`}
            >
              {COMPARISON_BASIS_LABELS[b]}
            </button>
          ))}
        </div>
      </div>

      {status === "loading" ? <Loading label="Loading energy consumption…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {unsupportedReason ? <ErrorState title="Range not available" error={new Error(unsupportedReason)} /> : null}

      {status === "ready" && current && result ? (
        <>
          {/* Current Value -- MEASURED: a direct sum of persisted historian
              rows, never calculated or predicted. */}
          <section className="energy-current-value" data-testid="energy-current-value">
            <h2>This period</h2>
            {current.no_data ? (
              <NoDataYet />
            ) : (
              <p className="value">{result.currentTotalKwh?.toFixed(1) ?? "—"} kWh</p>
            )}
          </section>

          {/* Comparison + Status -- CALCULATED: an arithmetic operation over
              measured history (a shifted-window total, or the median of up
              to 8 comparable historical periods). Never "expected",
              "predicted", or "normal". */}
          <section className="energy-comparison" data-testid="energy-comparison">
            <h2>Comparison</h2>
            {referenceResult && !referenceResult.sufficient ? (
              <NoDataYet
                message={`Not enough historical data yet for a typical-historical comparison (${referenceResult.eligiblePeriodCount} of ${referenceResult.requestedPeriodCount} comparable periods met the data-quality threshold; at least 5 are needed).`}
              />
            ) : result.comparisonHasData ? (
              <p>
                {result.comparisonTotalKwh?.toFixed(1)} kWh ({COMPARISON_BASIS_LABELS[basis]})
                {referenceResult ? (
                  <span className="hint" data-testid="energy-typical-reference-evidence">
                    {" "}
                    (based on {referenceResult.eligiblePeriodCount} of {referenceResult.requestedPeriodCount}{" "}
                    comparable historical periods)
                  </span>
                ) : null}
                {result.deltaKwh !== null ? (
                  <span data-testid="energy-delta">
                    {" "}
                    — {result.deltaKwh >= 0 ? "+" : ""}
                    {result.deltaKwh.toFixed(1)} kWh
                    {result.deltaPercent !== null
                      ? ` (${result.deltaPercent >= 0 ? "+" : ""}${result.deltaPercent.toFixed(1)}%)`
                      : ""}
                  </span>
                ) : null}
              </p>
            ) : (
              <NoDataYet message="No comparison data for that period yet." />
            )}
            <StatusBadge result={result} />

            {/* Included-period evidence: a reset/rollover/gap/invalid on an
                ELIGIBLE (included) comparable period never excludes it --
                communicated here explicitly, not hidden. Excluded periods
                are not counted in these notes; they were excluded for
                coverage reasons, independent of these flags. */}
            {referenceResult && referenceResult.sufficient ? (
              <ul className="energy-typical-reference-notes" data-testid="energy-typical-reference-notes">
                {countEligibleWindowsWithFlag(referenceResult.windows, "gap_interval_count") > 0 ? (
                  <li data-testid="energy-typical-reference-note-gap">
                    {countEligibleWindowsWithFlag(referenceResult.windows, "gap_interval_count")} of{" "}
                    {referenceResult.eligiblePeriodCount} included periods had a data gap -- still included.
                  </li>
                ) : null}
                {countEligibleWindowsWithFlag(referenceResult.windows, "reset_interval_count") > 0 ? (
                  <li data-testid="energy-typical-reference-note-reset">
                    {countEligibleWindowsWithFlag(referenceResult.windows, "reset_interval_count")} of{" "}
                    {referenceResult.eligiblePeriodCount} included periods had a meter reset -- still included.
                  </li>
                ) : null}
                {countEligibleWindowsWithFlag(referenceResult.windows, "rollover_interval_count") > 0 ? (
                  <li data-testid="energy-typical-reference-note-rollover">
                    {countEligibleWindowsWithFlag(referenceResult.windows, "rollover_interval_count")} of{" "}
                    {referenceResult.eligiblePeriodCount} included periods had a meter rollover -- still included.
                  </li>
                ) : null}
                {countEligibleWindowsWithFlag(referenceResult.windows, "invalid_interval_count") > 0 ? (
                  <li data-testid="energy-typical-reference-note-invalid">
                    {countEligibleWindowsWithFlag(referenceResult.windows, "invalid_interval_count")} of{" "}
                    {referenceResult.eligiblePeriodCount} included periods had some invalid intervals -- still
                    included.
                  </li>
                ) : null}
              </ul>
            ) : null}
          </section>

          {/* Trend */}
          <section className="energy-trend" data-testid="energy-trend">
            <h2>Trend</h2>
            {current.no_data ? (
              <NoDataYet />
            ) : (
              <ChartFrame points={toChartPoints(current)} valueLabel="Consumption" unit="kWh" />
            )}
          </section>

          {/* Evidence (Slice C, C4) -- real coverage/gap/reset/rollover
              counters from the additive evidence endpoint. Presented as
              coverage statistics, not a pass/fail quality verdict. */}
          <section className="energy-evidence-section" data-testid="energy-evidence-section">
            <h2>Evidence</h2>
            {evidenceSummary ? (
              <EnergyEvidencePanel summary={evidenceSummary} />
            ) : (
              <p className="hint" data-testid="energy-evidence-no-data">
                No evidence available for this period yet.
              </p>
            )}
          </section>
        </>
      ) : null}
    </div>
  );
}
