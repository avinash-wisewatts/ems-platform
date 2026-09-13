/**
 * Slice B -- Demand Overview. Adapts the shared grammar
 * (Current Value -> Comparison -> Trend -> Status -> Evidence/Data Quality)
 * to what Demand actually has:
 *
 *   Current Value  -- GET /demand/current (analytics.demand_state; live)
 *   Comparison     -- OMITTED. No historical-comparison or contract-demand
 *                     basis has been approved for Demand (unlike Energy's
 *                     Q54-56); inventing one here would be a product
 *                     decision, not an implementation task.
 *   Trend + Peak   -- GET /demand (analytics.demand_intervals; historical).
 *                     Peak demand and peak timing are derived client-side
 *                     from the returned series (max of peak_power_kw),
 *                     the same client-side-derivation pattern Slice A uses
 *                     for its comparison -- no new backend aggregation.
 *   Status         -- quality_status, shown as plain text. NOT a
 *                     StatusBadge: StatusBadge represents comparison
 *                     direction, and there is no comparison here.
 *   Evidence/Data Quality -- quality_status + coverage_percent, both real,
 *                     already-computed fields from demand_intervals/
 *                     demand_state -- not invented, unlike Energy's
 *                     still-deferred equivalent.
 *
 * No contract-demand, target, threshold, or utilization figure is shown --
 * none is configured anywhere in the schema (verified in the Slice B
 * decision pack).
 */

import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteCurrentDemand, getSiteDemandSeries } from "../../api/endpoints";
import type { CurrentDemandResponse, DemandIntervalPoint, DemandSeriesResponse } from "../../api/types";
import { planDemandRequest, type TimeRangePreset } from "../../time/ranges";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { TimeRangePicker } from "../../components/TimeRangePicker";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

function toChartPoints(series: DemandIntervalPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.interval_start), value: point.demand_kw }));
}

/** Peak demand + when it occurred, derived client-side -- no backend
 *  aggregation beyond the raw interval series. Exported (MVP-3) so
 *  SiteOverview's Demand summary reuses this exact calculation instead of
 *  duplicating it -- no change to its behavior or this screen's contract. */
export function findPeak(series: DemandIntervalPoint[]): { kw: number; at: string } | null {
  let best: { kw: number; at: string } | null = null;
  for (const point of series) {
    if (point.peak_power_kw !== null && (best === null || point.peak_power_kw > best.kw)) {
      best = { kw: point.peak_power_kw, at: point.interval_start };
    }
  }
  return best;
}

export function DemandOverview() {
  const { selectedSite, sites } = useTenant();
  const [preset, setPreset] = useState<TimeRangePreset>("7D");
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [unsupportedReason, setUnsupportedReason] = useState<string | null>(null);
  const [current, setCurrent] = useState<CurrentDemandResponse | null>(null);
  const [series, setSeries] = useState<DemandSeriesResponse | null>(null);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    setUnsupportedReason(null);

    const plan = planDemandRequest(preset);
    if (!plan.supported) {
      setUnsupportedReason(plan.reason);
      setStatus("ready");
      setCurrent(null);
      setSeries(null);
      return;
    }

    Promise.all([
      getSiteCurrentDemand(selectedSite.site_id),
      getSiteDemandSeries(selectedSite.site_id, plan.range),
    ])
      .then(([currentRes, seriesRes]) => {
        if (!active) return;
        setCurrent(currentRes);
        setSeries(seriesRes);
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
  }, [selectedSite, preset, nonce]);

  const peak = useMemo(() => (series ? findPeak(series.series) : null), [series]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  return (
    <div className="page page--demand-overview" data-testid="page-demand-overview">
      <HierarchyCrumb siteName={selectedSite.site_name} multiSite={sites.length > 1} leaf={{ label: "Demand" }} />
      <h1>Maximum demand</h1>

      <TimeRangePicker value={preset} onChange={setPreset} dataKind="demand" />

      {status === "loading" ? <Loading label="Loading demand…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {unsupportedReason ? <ErrorState title="Range not available" error={new Error(unsupportedReason)} /> : null}

      {status === "ready" && current && series ? (
        <>
          {/* Current Value */}
          <section className="demand-current-value" data-testid="demand-current-value">
            <h2>Current demand</h2>
            {current.has_data ? (
              <p className="value">{current.current_demand_kw?.toFixed(1) ?? "—"} kW</p>
            ) : (
              <NoDataYet message="No current demand reading yet." />
            )}
          </section>

          {/* Peak (part of Trend, per the product requirement) */}
          <section className="demand-peak" data-testid="demand-peak">
            <h2>Peak demand this period</h2>
            {peak ? (
              <p>
                {peak.kw.toFixed(1)} kW at {new Date(peak.at).toLocaleString()}
              </p>
            ) : (
              <NoDataYet />
            )}
          </section>

          {/* Trend */}
          <section className="demand-trend" data-testid="demand-trend">
            <h2>Trend</h2>
            {series.no_data ? (
              <NoDataYet />
            ) : (
              <ChartFrame points={toChartPoints(series.series)} valueLabel="Demand" unit="kW" />
            )}
          </section>

          {/* Status -- plain text, not StatusBadge (no comparison here) */}
          <section className="demand-status" data-testid="demand-status">
            <h2>Status</h2>
            <p>{current.has_data ? current.quality_status : "Unknown"}</p>
          </section>

          {/* Evidence / Data Quality -- real fields, not invented */}
          <section className="demand-evidence" data-testid="demand-evidence">
            <h2>Data quality</h2>
            {current.has_data && current.coverage_percent !== null ? (
              <p className="hint">Coverage: {current.coverage_percent.toFixed(0)}%</p>
            ) : (
              <p className="hint">No coverage information available yet.</p>
            )}
          </section>
        </>
      ) : null}
    </div>
  );
}
