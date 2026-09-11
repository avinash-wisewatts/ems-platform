/**
 * Slice A -- Energy Foundation. The first real customer-facing analytical
 * screen, composing the shared grammar:
 *
 *   Current Value -> Comparison -> Trend -> Status -> (Evidence, deferred)
 *
 * Built almost entirely on the existing, UNMODIFIED
 * GET /sites/{id}/energy/consumption endpoint -- called twice (current
 * range + comparison range) per docs/product/ems-product-roadmap.md v0.2
 * S:H. Historical comparison only (PREVIOUS_PERIOD / SAME_PERIOD_PREVIOUSLY
 * per Q54/Q56); no rolling average, no configured expectation, no
 * predictive/adaptive logic -- all explicitly deferred to a later increment.
 *
 * Evidence / Data Quality: EXPLICITLY DEFERRED in this increment.
 * EnergyConsumptionPoint carries no quality field (unlike space
 * measurements) -- adding one is a separate, decision-gated Phase 7 contract
 * change, not made here. `source_interval_count` is presented as plain "Data
 * coverage" context only -- it is NOT labelled or treated as evidence for an
 * analytical conclusion, and no quality/trust claim is rendered until the
 * quality/evidence contract is properly established.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteEnergyConsumption } from "../../api/endpoints";
import type { EnergyConsumptionResponse } from "../../api/types";
import {
  planEnergyComparisonRequest,
  type ComparisonBasis,
  type TimeRangePreset,
  COMPARISON_BASIS_LABELS,
} from "../../time/ranges";
import { buildComparisonResult, type ComparisonResult } from "../../energy/comparison";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { TimeRangePicker } from "../../components/TimeRangePicker";
import { StatusBadge } from "../../components/StatusBadge";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

const COMPARISON_BASES: readonly ComparisonBasis[] = ["PREVIOUS_PERIOD", "SAME_PERIOD_PREVIOUSLY"];

function toChartPoints(response: EnergyConsumptionResponse): ChartPoint[] {
  return response.series.map((point) => ({
    t: Date.parse(point.bucket_start),
    value: point.import_kwh,
  }));
}

function totalSourceIntervals(response: EnergyConsumptionResponse): number {
  return response.series.reduce((sum, point) => sum + point.source_interval_count, 0);
}

export function EnergyOverview() {
  const { selectedSite } = useTenant();
  const [preset, setPreset] = useState<TimeRangePreset>("7D");
  const [basis, setBasis] = useState<ComparisonBasis>("PREVIOUS_PERIOD");
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [unsupportedReason, setUnsupportedReason] = useState<string | null>(null);
  const [current, setCurrent] = useState<EnergyConsumptionResponse | null>(null);
  const [comparison, setComparison] = useState<EnergyConsumptionResponse | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    setUnsupportedReason(null);

    const plan = planEnergyComparisonRequest(preset, basis);
    if (!plan.supported) {
      setUnsupportedReason(plan.reason);
      setStatus("ready");
      setCurrent(null);
      setComparison(null);
      return;
    }

    Promise.all([
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: plan.resolution, ...plan.current }),
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: plan.resolution, ...plan.comparison }),
    ])
      .then(([currentRes, comparisonRes]) => {
        if (!active) return;
        setCurrent(currentRes);
        setComparison(comparisonRes);
        setStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setError(err);
        setStatus("error");
      });

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

  const result: ComparisonResult | null =
    current && comparison ? buildComparisonResult(basis, current, comparison) : null;

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

      {status === "ready" && current && comparison && result ? (
        <>
          {/* Current Value */}
          <section className="energy-current-value" data-testid="energy-current-value">
            <h2>This period</h2>
            {current.no_data ? (
              <NoDataYet />
            ) : (
              <p className="value">{result.currentTotalKwh?.toFixed(1) ?? "—"} kWh</p>
            )}
          </section>

          {/* Comparison + Status */}
          <section className="energy-comparison" data-testid="energy-comparison">
            <h2>Comparison</h2>
            {result.comparisonHasData ? (
              <p>
                {result.comparisonTotalKwh?.toFixed(1)} kWh ({COMPARISON_BASIS_LABELS[basis]})
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

          {/* Data coverage -- context only, NOT an evidence/quality claim.
              See module docstring: Evidence is explicitly deferred. */}
          <section className="energy-data-coverage" data-testid="energy-data-coverage">
            <h2>Data coverage</h2>
            {!current.no_data ? (
              <p className="hint">
                Based on {totalSourceIntervals(current)} source interval
                {totalSourceIntervals(current) === 1 ? "" : "s"} this period.
              </p>
            ) : null}
            <p className="hint">Data quality / evidence indicators are not yet available for energy.</p>
          </section>
        </>
      ) : null}
    </div>
  );
}
