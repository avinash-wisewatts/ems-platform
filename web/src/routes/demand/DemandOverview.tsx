/**
 * Slice B -- Demand Overview. Adapts the shared grammar
 * (Current Value -> Comparison -> Trend -> Status -> Evidence/Data Quality)
 * to what Demand actually has:
 *
 *   Last Completed -- GET /demand/current -> last_completed_interval (the
 *                     newest analytics.demand_intervals row, any status):
 *                     value, site-local start-end and data-quality status.
 *                     T1.3a (revised run 11): no provisional or in-progress
 *                     value is shown (D-011), and only a VALID interval's
 *                     value is presented as demand. Presented together with
 *                     Peak Power under one "Demand (kW)"
 *                     heading (components/DemandLastCompletedAndPeak.tsx).
 *   Comparison     -- OMITTED. No historical-comparison or contract-demand
 *                     basis has been approved for Demand (unlike Energy's
 *                     Q54-56); inventing one here would be a product
 *                     decision, not an implementation task.
 *   Trend + Peak Power -- GET /demand (analytics.demand_intervals;
 *                     historical). Peak Power and its occurrence time are
 *                     derived client-side from the returned series (max of
 *                     peak_power_kw, via findPeak below -- the maximum
 *                     INSTANTANEOUS power sample seen in any interval in
 *                     the period, deliberately NOT demand_kw -- see
 *                     findPeak's own doc comment; Peak Power is never
 *                     labelled "Demand"), the same client-side-derivation
 *                     pattern Slice A uses for its comparison -- no new
 *                     backend aggregation. The occurrence time is shown in
 *                     the selected site's own configured timezone.
 *   Status         -- the last completed interval's quality_status,
 *                     translated to a customer label
 *                     (components/demandInterval.ts); no label for a
 *                     complete (VALID) interval. NOT a StatusBadge:
 *                     StatusBadge represents comparison direction, and
 *                     there is no comparison here.
 *   Evidence/Data Quality -- the last completed interval's
 *                     coverage_percent, a real, already-computed
 *                     demand_intervals field -- not invented, unlike
 *                     Energy's still-deferred equivalent.
 *
 * No contract-demand, target, threshold, or utilization figure is shown --
 * none is configured anywhere in the schema (verified in the Slice B
 * decision pack).
 *
 * MVP-5 -- Content & Metric Grammar: the raw quality_status value is
 * translated to a customer label in ONE place
 * (components/demandInterval.ts), never rendered raw.
 * NO_DATA/INVALID_SOURCE/SOURCE_BOUNDARY/INSUFFICIENT_SOURCE_RESOLUTION all
 * share "Data unavailable" -- Product decided a customer cannot act
 * differently on any of them. T1.3a (run 11) replaced the live
 * demand_state labels ("Calculating" for PROVISIONAL) with the
 * completed-interval wording, because no in-progress value is shown.
 */

import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSiteCurrentDemand, getSiteDemandSeries, getSiteTelemetryFreshness } from "../../api/endpoints";
import type {
  CurrentDemandResponse,
  DemandIntervalPoint,
  DemandSeriesResponse,
  SiteTelemetryFreshnessResponse,
} from "../../api/types";
import { planDemandRequest, type TimeRangePreset } from "../../time/ranges";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { TimeRangePicker } from "../../components/TimeRangePicker";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { DemandLastCompletedAndPeak } from "../../components/DemandLastCompletedAndPeak";
import {
  completedIntervalStatusExplanation,
  completedIntervalStatusLabel,
  reliableDemandKw,
} from "../../components/demandInterval";
import { FreshnessIndicator } from "../../components/FreshnessIndicator";
import { InfoDisclosure } from "../../components/InfoDisclosure";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

/** Exported for the same reason as findPeak below -- Asset View's Demand
 *  trend chart reuses this exact mapping (AssetDemandSeriesResponse.series
 *  is DemandIntervalPoint[], the identical shape). T1.3a: a non-VALID
 *  interval is a gap, never presented as reliable demand. */
export function toChartPoints(series: DemandIntervalPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.interval_start), value: reliableDemandKw(point) }));
}

/**
 * Peak Power: the maximum INSTANTANEOUS power sample observed within any
 * interval in the series, and when it occurred -- derived client-side, no
 * backend aggregation beyond the raw interval series. Exported so Asset
 * View's Demand tile, SiteOverview's Demand summary, MainDashboard, and
 * SitePerformanceReportView all reuse this exact calculation instead of
 * duplicating it.
 *
 * Evidence this is genuinely a different figure from an interval's
 * demand_kw (read directly from the deployed schema/functions, not assumed
 * from field names -- postgres/migrations/013_demand_calculation_
 * processor.sql): `demand_kw` is the interval's own calculated demand
 * value (energy-delta-derived average kW, time-weighted average kW, or a
 * native meter register reading, depending on source method).
 * `peak_power_kw` is a DIFFERENT, independent column populated only for
 * ENERGY_COUNTER_DELTA/TIME_WEIGHTED_POWER sources
 * (`max(active_power_total_w)/1000` over raw sub-interval telemetry
 * samples within that interval) -- entirely NULL for METER_NATIVE-sourced
 * rows. This function maxes peak_power_kw specifically -- the customer-
 * facing "Peak Power" figure, deliberately never labelled "Demand"
 * (components/DemandLastCompletedAndPeak.tsx keeps the two distinct in both
 * label and value).
 */
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
  // MVP-4 -- device freshness. Independent of quality_status/coverage_percent
  // above (decision pack Sec 5); a failure here leaves this null, rendered
  // as nothing, never blocking the Current/Peak/Trend/Status sections.
  const [freshness, setFreshness] = useState<SiteTelemetryFreshnessResponse | null>(null);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    setUnsupportedReason(null);

    const plan = planDemandRequest(preset, selectedSite.timezone);
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

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    getSiteTelemetryFreshness(selectedSite.site_id)
      .then((data) => {
        if (active) setFreshness(data);
      })
      .catch(() => {
        if (active) setFreshness(null);
      });
    return () => {
      active = false;
    };
  }, [selectedSite]);

  const peak = useMemo(() => (series ? findPeak(series.series) : null), [series]);
  const lastCompleted = current?.last_completed_interval ?? null;
  const lastCompletedStatus = lastCompleted?.quality_status ?? null;

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

      <TimeRangePicker value={preset} onChange={setPreset} dataKind="demand" timeZone={selectedSite.timezone} />

      {status === "loading" ? <Loading label="Loading demand…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {unsupportedReason ? <ErrorState title="Range not available" error={new Error(unsupportedReason)} /> : null}

      {status === "ready" && current && series ? (
        <>
          {/* Last completed interval + Peak Power
              (components/DemandLastCompletedAndPeak.tsx). Peak Power uses
              peak_power_kw (findPeak) -- see its own doc comment for why
              that's deliberately not demand_kw. */}
          <section className="demand-current-value" data-testid="demand-current-value">
            <h2>Demand (kW)</h2>
            <DemandLastCompletedAndPeak
              lastCompleted={lastCompleted}
              peakPower={peak}
              siteTimezone={selectedSite.timezone}
              testIdPrefix="demand"
            />
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

          {/* Status of the last completed interval -- customer label, not
              StatusBadge (no comparison here). MVP-5: quality_status is
              translated, never rendered raw. A complete (VALID) interval
              needs no label: only incomplete / unavailable data is called
              out. */}
          <section className="demand-status" data-testid="demand-status">
            <h2>Status</h2>
            {lastCompletedStatus !== "VALID" ? (
              <p>
                {completedIntervalStatusLabel(lastCompletedStatus)}
                <InfoDisclosure
                  label={completedIntervalStatusLabel(lastCompletedStatus)}
                  explanation={completedIntervalStatusExplanation(lastCompletedStatus)}
                  testId="demand-status"
                />
              </p>
            ) : null}
          </section>

          {/* MVP-4 -- device freshness: a separate question ("is the meter
              communicating") from Status above ("was this calculation
              valid") -- kept visibly distinct, not merged into it. */}
          <section className="demand-freshness" data-testid="demand-freshness">
            <h2>Freshness</h2>
            <FreshnessIndicator state={freshness?.demand.state} />
          </section>

          {/* Evidence / Data Quality -- real fields, not invented */}
          <section className="demand-evidence" data-testid="demand-evidence">
            <h2>Data quality</h2>
            {lastCompleted && lastCompleted.coverage_percent !== null ? (
              <p className="hint" data-testid="demand-coverage">
                Coverage of the last completed interval: {lastCompleted.coverage_percent.toFixed(0)}%
              </p>
            ) : (
              <p className="hint">No coverage information available yet.</p>
            )}
          </section>
        </>
      ) : null}
    </div>
  );
}
