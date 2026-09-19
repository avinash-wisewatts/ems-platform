/**
 * Slice B -- Demand Overview. Adapts the shared grammar
 * (Current Value -> Comparison -> Trend -> Status -> Evidence/Data Quality)
 * to what Demand actually has:
 *
 *   Current Value  -- GET /demand/current (analytics.demand_state; live),
 *                     current_demand_kw -- the latest calculated 15-minute
 *                     demand interval, still updating. Presented together
 *                     with Peak Power under one "Current Demand (kW)"
 *                     heading (components/DemandCurrentAndMax.tsx, the same
 *                     shared presentation Asset View's Demand tile uses).
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
 *   Status         -- quality_status, translated to an approved MVP-5
 *                     customer label (see DEMAND_STATUS_LABELS below). NOT
 *                     a StatusBadge: StatusBadge represents comparison
 *                     direction, and there is no comparison here.
 *   Evidence/Data Quality -- quality_status + coverage_percent, both real,
 *                     already-computed fields from demand_intervals/
 *                     demand_state -- not invented, unlike Energy's
 *                     still-deferred equivalent.
 *
 * No contract-demand, target, threshold, or utilization figure is shown --
 * none is configured anywhere in the schema (verified in the Slice B
 * decision pack).
 *
 * MVP-5 -- Content & Metric Grammar (approved Product decision): the raw
 * quality_status value (PROVISIONAL/NO_DATA/INVALID_SOURCE/
 * INSUFFICIENT_SOURCE_RESOLUTION) is translated to a customer label here,
 * in ONE place. NO_DATA/INVALID_SOURCE/INSUFFICIENT_SOURCE_RESOLUTION all
 * share "Data unavailable" -- Product decided a customer cannot act
 * differently on any of the three, so no distinction is drawn for them.
 * The underlying six-value technical vocabulary and the API contract are
 * unchanged; only this screen's rendering of it changes. The pre-existing
 * "no current-demand row at all" case (previously hardcoded to the literal
 * word "Unknown") now also reads "Data unavailable", per the same Product
 * decision -- it was never one of the six technical values and is not a
 * new customer-facing state.
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
import { DemandCurrentAndMax } from "../../components/DemandCurrentAndMax";
import { FreshnessIndicator } from "../../components/FreshnessIndicator";
import { InfoDisclosure } from "../../components/InfoDisclosure";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

/** The four live values `analytics.demand_state` can actually produce
 *  (VALID/INCOMPLETE are interval-level-only -- see demand/README.md and
 *  the MVP-5 evidence trace; they never appear as the "current" value this
 *  screen renders here, so no label is defined for them). */
const DEMAND_STATUS_LABELS: Record<string, string> = {
  PROVISIONAL: "Calculating",
  NO_DATA: "Data unavailable",
  INVALID_SOURCE: "Data unavailable",
  INSUFFICIENT_SOURCE_RESOLUTION: "Data unavailable",
};

/** DRAFT wording -- Product approved the underlying meaning, not this exact
 *  copy. NO_DATA/INVALID_SOURCE/INSUFFICIENT_SOURCE_RESOLUTION deliberately
 *  share one explanation, matching their shared customer label. */
const DEMAND_STATUS_EXPLANATIONS: Record<string, string> = {
  PROVISIONAL: "This Demand value is still being calculated and hasn't been finalized yet.",
  NO_DATA: "We can't currently provide a usable Demand value for this metric.",
  INVALID_SOURCE: "We can't currently provide a usable Demand value for this metric.",
  INSUFFICIENT_SOURCE_RESOLUTION: "We can't currently provide a usable Demand value for this metric.",
};

const DEMAND_STATUS_FALLBACK_LABEL = "Data unavailable";
const DEMAND_STATUS_FALLBACK_EXPLANATION = "We can't currently provide a usable Demand value for this metric.";

/** Translates quality_status (or its absence -- no current-demand row at
 *  all) into the approved MVP-5 customer label. An unrecognized value
 *  defensively falls back to "Data unavailable" rather than ever leaking
 *  the raw technical string. Exported so Asset View's Demand section
 *  reuses this exact translation instead of duplicating it -- the Asset
 *  Demand API (migration 245) returns the identical quality_status
 *  vocabulary as Site Demand. */
export function demandStatusLabel(qualityStatus: string | null): string {
  if (qualityStatus === null) return DEMAND_STATUS_FALLBACK_LABEL;
  return DEMAND_STATUS_LABELS[qualityStatus] ?? DEMAND_STATUS_FALLBACK_LABEL;
}

export function demandStatusExplanation(qualityStatus: string | null): string {
  if (qualityStatus === null) return DEMAND_STATUS_FALLBACK_EXPLANATION;
  return DEMAND_STATUS_EXPLANATIONS[qualityStatus] ?? DEMAND_STATUS_FALLBACK_EXPLANATION;
}

/** Exported for the same reason as findPeak below -- Asset View's Demand
 *  trend chart reuses this exact mapping (AssetDemandSeriesResponse.series
 *  is DemandIntervalPoint[], the identical shape). */
export function toChartPoints(series: DemandIntervalPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.interval_start), value: point.demand_kw }));
}

/**
 * Peak Power: the maximum INSTANTANEOUS power sample observed within any
 * interval in the series, and when it occurred -- derived client-side, no
 * backend aggregation beyond the raw interval series. Exported so Asset
 * View's Demand tile, SiteOverview's Demand summary, MainDashboard, and
 * SitePerformanceReportView all reuse this exact calculation instead of
 * duplicating it.
 *
 * Evidence this is genuinely a different figure from Current Demand's
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
 * (components/DemandCurrentAndMax.tsx keeps the two distinct in both
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
  const demandQualityStatus = current?.has_data ? current.quality_status : null;

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
          {/* Current Value + Peak Power -- shared presentation with Asset
              View's Demand tile (components/DemandCurrentAndMax.tsx). Peak
              Power uses peak_power_kw (findPeak) -- see its own doc
              comment for why that's deliberately not demand_kw. */}
          <section className="demand-current-value" data-testid="demand-current-value">
            <h2>Current Demand (kW)</h2>
            {current.has_data ? (
              <DemandCurrentAndMax
                currentDemandKw={current.current_demand_kw}
                peakPower={peak}
                siteTimezone={selectedSite.timezone}
                testIdPrefix="demand"
              />
            ) : (
              <NoDataYet message="No current demand reading yet." />
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

          {/* Status -- customer label, not StatusBadge (no comparison here).
              MVP-5: quality_status is translated, never rendered raw. */}
          <section className="demand-status" data-testid="demand-status">
            <h2>Status</h2>
            <p>
              {demandStatusLabel(demandQualityStatus)}
              <InfoDisclosure
                label={demandStatusLabel(demandQualityStatus)}
                explanation={demandStatusExplanation(demandQualityStatus)}
                testId="demand-status"
              />
            </p>
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
