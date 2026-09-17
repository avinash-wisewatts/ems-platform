/**
 * WiseWatts dashboard redesign -- Main Dashboard. The new landing screen
 * (replaces `/home`'s SiteOverview as the post-login destination; SiteOverview
 * itself is untouched and stays reachable from the sidebar's Archive section).
 *
 * Every value on this page comes from an ALREADY-LIVE `/api/v1` endpoint,
 * fetched client-side -- no new backend endpoint, no invented business logic:
 *
 *   YTD / MTD Energy   -- GET /sites/{id}/energy/consumption, called twice per
 *                          card (the window itself + the comparison window),
 *                          reduced with the existing, unmodified
 *                          energy/comparison.ts#buildComparisonResult (the
 *                          same pure summation Slice A/C already use). The
 *                          YTD-vs-Previous-Year window reuses
 *                          time/ranges.ts#shiftRangeForComparison's approved
 *                          SAME_PERIOD_PREVIOUSLY calendar shift; MTD-vs-
 *                          Previous-Month has no equivalent in that approved
 *                          model (which only covers the TimeRangePicker
 *                          presets), so dateWindows.ts#previousMonthRange
 *                          does the equivalent one-calendar-month shift.
 *   Demand              -- GET /sites/{id}/demand/current (Current) and GET
 *                          /sites/{id}/demand (Peak Today / Max This Month),
 *                          reducing with DemandOverview.tsx's own exported
 *                          `findPeak` -- the exact same client-side peak
 *                          derivation SiteOverview already reuses.
 *   Load Trend           -- GET /sites/{id}/demand for the selected range,
 *                          rendered with the shared ChartFrame (area variant).
 *   Site Health           -- the exact same derivation SiteOverview already
 *                          uses (attention/siteHealth.ts#deriveSiteHealth +
 *                          attention/energyAttention.ts#evaluateEnergyAttention
 *                          over a 7-day window's typical-reference
 *                          comparison) -- not a second health mechanism.
 *   Last Data Update      -- GET /sites/{id}/telemetry-freshness, the most
 *                          recent non-null `as_of` across energy/demand/
 *                          power-quality. That field already exists on the
 *                          wire (api/types.ts) and is now shown per explicit
 *                          product direction for this dashboard; no other
 *                          screen's treatment of telemetry-freshness changes.
 *   Live Electrical
 *   Parameters           -- INTENTIONALLY NOT WIRED to a real value.
 *                          Voltage/Current/PF/Frequency have no site-level
 *                          source in the customer-facing /api/v1 API today:
 *                          the real data exists only per-ASSET on the
 *                          separate live-telemetry service (GET
 *                          /api/live/assets/{id}), and nothing in /api/v1
 *                          tells the frontend which asset is "the site
 *                          meter". Rather than guess an asset or fabricate
 *                          values, this card keeps the intended field
 *                          structure (Voltage/Current/PF/Frequency) visible
 *                          but marks every value "Not available yet" -- an
 *                          honest product placeholder for a capability that
 *                          doesn't exist yet, per explicit product
 *                          direction, distinct from "no data for this site".
 *
 * Per explicit product direction: every card above stays on the page and
 * keeps its titled tile even when its own data is unavailable -- a missing
 * site-level meter, an unassessable Site Health, or a missing freshness
 * reading never hides a tile; it only changes what renders *inside* it
 * (a value, a "No data available" state, or -- for Live Electrical
 * Parameters only -- a "not a built capability yet" placeholder). The
 * dashboard's structure is the same for every site; only the data state
 * changes.
 *
 * Each data section (YTD, MTD, Demand, Site Health, Freshness) loads and
 * fails independently, matching the established SiteOverview/DemandOverview
 * pattern -- one card's failure never blanks the others. Load Trend has its
 * own independent range control and fetch, again matching that pattern.
 */

import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import {
  getSiteCurrentDemand,
  getSiteDemandSeries,
  getSiteEnergyConsumption,
  getSiteEnergyConsumptionEvidence,
  getSiteEnergyTypicalReference,
  getSiteTelemetryFreshness,
} from "../../api/endpoints";
import type { CurrentDemandResponse, DemandSeriesResponse, SiteTelemetryFreshnessResponse } from "../../api/types";
import {
  PRESET_LABELS,
  TIME_RANGE_PRESETS,
  isPresetSupported,
  planDemandRequest,
  planEnergyRequest,
  planEnergyTypicalReferenceRequest,
  resolveRange,
  shiftRangeForComparison,
  type TimeRangePreset,
} from "../../time/ranges";
import { buildComparisonResult, buildTypicalReferenceResult, type ComparisonResult } from "../../energy/comparison";
import { summarizeEnergyEvidence } from "../../energy/evidence";
import { evaluateEnergyAttention } from "../../attention/energyAttention";
import { deriveSiteHealth, siteHealthSummary, SITE_HEALTH_LABELS } from "../../attention/siteHealth";
import { MVP3_MATERIALITY_POLICY } from "../../attention/materiality-policy";
import type { AttentionItem, SiteHealthState } from "../../attention/types";
import { deriveStatusTone } from "../../components/StatusBadge";
import { findPeak } from "../demand/DemandOverview";
import { mtdRange, previousMonthRange, ytdRange } from "./dateWindows";
import { DATE_TIME_FORMAT } from "../../time/format";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

type EnergyWindowSection = {
  status: LoadStatus;
  error: unknown;
  result: ComparisonResult | null;
};

const ENERGY_WINDOW_INITIAL: EnergyWindowSection = { status: "loading", error: null, result: null };

type DemandSection = {
  status: LoadStatus;
  error: unknown;
  current: CurrentDemandResponse | null;
  peakToday: { kw: number; at: string } | null;
  maxThisMonth: { kw: number; at: string } | null;
};

const DEMAND_INITIAL: DemandSection = {
  status: "loading",
  error: null,
  current: null,
  peakToday: null,
  maxThisMonth: null,
};

type TrendSection = {
  status: LoadStatus;
  error: unknown;
  unsupportedReason: string | null;
  series: DemandSeriesResponse | null;
};

const TREND_INITIAL: TrendSection = { status: "loading", error: null, unsupportedReason: null, series: null };

type HealthSection = {
  status: LoadStatus;
  error: unknown;
  unsupportedReason: string | null;
  state: SiteHealthState | null;
  summary: string | null;
};

const HEALTH_INITIAL: HealthSection = {
  status: "loading",
  error: null,
  unsupportedReason: null,
  state: null,
  summary: null,
};

/** MVP-4's telemetry-freshness is a "right now" read with no time-range
 *  dependency -- a failure here leaves `data` null, rendered as an honest
 *  "not available" state, never blocking the rest of the page (same
 *  additive-only treatment SiteOverview already gives this endpoint). */
type FreshnessSection = {
  status: LoadStatus;
  error: unknown;
  data: SiteTelemetryFreshnessResponse | null;
};

const FRESHNESS_INITIAL: FreshnessSection = { status: "loading", error: null, data: null };

/** The most recent non-null `as_of` across the three telemetry-freshness
 *  domains -- "the freshest data we have from this site," not tied to any
 *  one metric. Null when every domain is null (or the fetch itself failed). */
function mostRecentAsOf(freshness: SiteTelemetryFreshnessResponse | null): string | null {
  if (!freshness) return null;
  const values = [freshness.energy.as_of, freshness.demand.as_of, freshness.power_quality.as_of].filter(
    (v): v is string => v !== null,
  );
  if (values.length === 0) return null;
  return values.reduce((latest, v) => (Date.parse(v) > Date.parse(latest) ? v : latest));
}

/** Demand's persisted series has no coarser-than-native tier and is capped
 *  at 31 days (see time/ranges.ts DEMAND_MAX_WINDOW_S) -- only offer presets
 *  the Load Trend chart can actually request, rather than a preset that
 *  always errors. */
const TREND_PRESETS = TIME_RANGE_PRESETS.filter((p) => isPresetSupported(p, "demand"));

function formatKwh(value: number | null): string {
  if (value === null) return "—";
  return Math.round(value).toLocaleString();
}

function formatKw(value: number | null): string {
  if (value === null) return "—";
  return value.toFixed(1);
}

function toChartPoints(series: DemandSeriesResponse["series"]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.interval_start), value: point.demand_kw }));
}

function EnergyDelta({ result, comparisonLabel }: { result: ComparisonResult; comparisonLabel: string }) {
  if (result.deltaPercent === null || result.comparisonTotalKwh === null) {
    return (
      <p className="kpi-card__delta kpi-card__delta--unknown" data-testid="kpi-delta-unknown">
        Comparison not available for this period.
      </p>
    );
  }
  const tone = deriveStatusTone(result.deltaPercent);
  const arrow = tone === "higher" ? "↑" : tone === "lower" ? "↓" : "→";
  return (
    <p className={`kpi-card__delta kpi-card__delta--${tone}`} data-testid="kpi-delta">
      <span className="kpi-card__delta-figure">
        <span aria-hidden="true">{arrow}</span> {result.deltaPercent >= 0 ? "+" : ""}
        {result.deltaPercent.toFixed(1)}%
      </span>
      <span className="kpi-card__delta-basis">
        vs. {formatKwh(result.comparisonTotalKwh)} kWh ({comparisonLabel})
      </span>
    </p>
  );
}

const SITE_HEALTH_TONE: Record<SiteHealthState, string> = {
  HEALTHY: "healthy",
  NEEDS_ATTENTION: "attention",
  INSUFFICIENT_DATA: "insufficient",
};

function SiteHealthPill({ health, onRetry }: { health: HealthSection; onRetry: () => void }) {
  if (health.status === "loading") {
    return (
      <span className="status-pill status-pill--loading" data-testid="dashboard-site-health">
        Assessing site health…
      </span>
    );
  }
  if (health.status === "error") {
    return (
      <button
        type="button"
        className="status-pill status-pill--error"
        onClick={onRetry}
        data-testid="dashboard-site-health"
      >
        Site health unavailable · Retry
      </button>
    );
  }
  if (health.unsupportedReason || !health.state) {
    return (
      <span
        className="status-pill status-pill--unknown"
        data-testid="dashboard-site-health"
        title={health.unsupportedReason ?? "Site health could not be assessed."}
      >
        Site health not available
      </span>
    );
  }
  return (
    <span
      className={`status-pill status-pill--${SITE_HEALTH_TONE[health.state]}`}
      data-testid="dashboard-site-health"
      data-state={health.state}
      title={health.summary ?? undefined}
    >
      <span className="status-pill__dot" aria-hidden="true" />
      {SITE_HEALTH_LABELS[health.state]}
    </span>
  );
}

function LastDataUpdate({ freshness, onRetry }: { freshness: FreshnessSection; onRetry: () => void }) {
  if (freshness.status === "loading") {
    return (
      <span className="status-pill status-pill--loading" data-testid="dashboard-last-update">
        Last data update: loading…
      </span>
    );
  }
  if (freshness.status === "error") {
    return (
      <button
        type="button"
        className="status-pill status-pill--error"
        onClick={onRetry}
        data-testid="dashboard-last-update"
      >
        Last data update: unavailable · Retry
      </button>
    );
  }
  const asOf = mostRecentAsOf(freshness.data);
  return (
    <span className="status-pill status-pill--muted" data-testid="dashboard-last-update">
      Last data update: {asOf ? DATE_TIME_FORMAT.format(new Date(asOf)) : "not available"}
    </span>
  );
}

export function MainDashboard() {
  const { selectedSite, sites } = useTenant();

  const [ytd, setYtd] = useState<EnergyWindowSection>(ENERGY_WINDOW_INITIAL);
  const [ytdNonce, setYtdNonce] = useState(0);
  const [mtd, setMtd] = useState<EnergyWindowSection>(ENERGY_WINDOW_INITIAL);
  const [mtdNonce, setMtdNonce] = useState(0);
  const [demand, setDemand] = useState<DemandSection>(DEMAND_INITIAL);
  const [demandNonce, setDemandNonce] = useState(0);
  const [trendPreset, setTrendPreset] = useState<TimeRangePreset>(TREND_PRESETS[0] ?? "TODAY");
  const [trend, setTrend] = useState<TrendSection>(TREND_INITIAL);
  const [trendNonce, setTrendNonce] = useState(0);
  const [health, setHealth] = useState<HealthSection>(HEALTH_INITIAL);
  const [healthNonce, setHealthNonce] = useState(0);
  const [freshness, setFreshness] = useState<FreshnessSection>(FRESHNESS_INITIAL);
  const [freshnessNonce, setFreshnessNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setYtd((s) => ({ ...s, status: "loading", error: null }));

    const current = ytdRange();
    const comparison = shiftRangeForComparison(current, "SAME_PERIOD_PREVIOUSLY");

    Promise.all([
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: "1d", ...current }),
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: "1d", ...comparison }),
    ])
      .then(([currentRes, comparisonRes]) => {
        if (!active) return;
        setYtd({
          status: "ready",
          error: null,
          result: buildComparisonResult("SAME_PERIOD_PREVIOUSLY", currentRes, comparisonRes),
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setYtd((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, ytdNonce]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setMtd((s) => ({ ...s, status: "loading", error: null }));

    const current = mtdRange();
    const comparison = previousMonthRange(current);

    Promise.all([
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: "1d", ...current }),
      getSiteEnergyConsumption(selectedSite.site_id, { resolution: "1d", ...comparison }),
    ])
      .then(([currentRes, comparisonRes]) => {
        if (!active) return;
        setMtd({
          status: "ready",
          error: null,
          result: buildComparisonResult("PREVIOUS_PERIOD", currentRes, comparisonRes),
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setMtd((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, mtdNonce]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setDemand((s) => ({ ...s, status: "loading", error: null }));

    Promise.all([
      getSiteCurrentDemand(selectedSite.site_id),
      getSiteDemandSeries(selectedSite.site_id, resolveRange("TODAY")),
      getSiteDemandSeries(selectedSite.site_id, mtdRange()),
    ])
      .then(([currentRes, todayRes, monthRes]) => {
        if (!active) return;
        setDemand({
          status: "ready",
          error: null,
          current: currentRes,
          peakToday: findPeak(todayRes.series),
          maxThisMonth: findPeak(monthRes.series),
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setDemand((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, demandNonce]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setTrend((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const plan = planDemandRequest(trendPreset);
    if (!plan.supported) {
      setTrend({ status: "ready", error: null, unsupportedReason: plan.reason, series: null });
      return;
    }

    getSiteDemandSeries(selectedSite.site_id, plan.range)
      .then((series) => {
        if (!active) return;
        setTrend({ status: "ready", error: null, unsupportedReason: null, series });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setTrend((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, trendPreset, trendNonce]);

  // Site Health -- the exact same derivation SiteOverview uses (7-day
  // typical-reference comparison + the single approved Energy Attention
  // rule), reused verbatim rather than a second health mechanism.
  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setHealth((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const consumptionPlan = planEnergyRequest("7D");
    const referencePlan = planEnergyTypicalReferenceRequest("7D");
    if (!consumptionPlan.supported) {
      setHealth({ ...HEALTH_INITIAL, status: "ready", unsupportedReason: consumptionPlan.reason });
      return;
    }
    if (!referencePlan.supported) {
      setHealth({ ...HEALTH_INITIAL, status: "ready", unsupportedReason: referencePlan.reason });
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
      .then(([current, reference, evidence]) => {
        if (!active) return;
        const comparisonResult = buildTypicalReferenceResult(current, reference);
        const evidenceSummary = summarizeEnergyEvidence(evidence);
        const attentionItems: AttentionItem[] = [];
        const item = evaluateEnergyAttention({
          result: comparisonResult,
          evidence: evidenceSummary,
          policy: MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION,
          siteName: selectedSite.site_name,
          window: consumptionPlan.range,
          investigatePath: "/features/energy",
        });
        if (item) attentionItems.push(item);
        const energyAssessable = comparisonResult.sufficient && comparisonResult.currentHasData;
        const state = deriveSiteHealth({ energyAssessable, attentionItems });
        setHealth({
          status: "ready",
          error: null,
          unsupportedReason: null,
          state,
          summary: siteHealthSummary(state, attentionItems.length),
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setHealth((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, healthNonce]);

  // Last Data Update -- a "right now" read, additive only: a failure leaves
  // `data` null, rendered as an honest "not available" state, never
  // blocking any other card on the page.
  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setFreshness((s) => ({ ...s, status: "loading", error: null }));

    getSiteTelemetryFreshness(selectedSite.site_id)
      .then((data) => {
        if (!active) return;
        setFreshness({ status: "ready", error: null, data });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setFreshness({ status: "error", error: err, data: null });
      });

    return () => {
      active = false;
    };
  }, [selectedSite, freshnessNonce]);

  const trendPoints = useMemo(() => (trend.series ? toChartPoints(trend.series.series) : []), [trend.series]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  return (
    <div className="page page--main-dashboard" data-testid="page-main-dashboard">
      <HierarchyCrumb
        siteName={selectedSite.site_name}
        multiSite={sites.length > 1}
        leaf={{ label: "Main Dashboard" }}
        portfolioLabel="Portfolio"
        siteHref="/dashboard"
      />

      <header className="dashboard-header">
        <span className="dashboard-header__icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" strokeWidth="1.6">
            <path d="M4 21V5a1 1 0 0 1 1-1h6v17M4 21h16M11 21V9h6a1 1 0 0 1 1 1v11" strokeLinejoin="round" />
            <path d="M7.5 7h1M7.5 10h1M7.5 13h1M7.5 16h1M14 12h1M14 15h1M14 18h1" strokeLinecap="round" />
          </svg>
        </span>
        <div className="dashboard-header__identity">
          <h1>{selectedSite.site_name}</h1>
          <p className="dashboard-header__subtitle">Main Dashboard · Overview of energy performance and site status</p>
        </div>
        <div className="dashboard-header__status">
          <SiteHealthPill health={health} onRetry={() => setHealthNonce((n) => n + 1)} />
          <LastDataUpdate freshness={freshness} onRetry={() => setFreshnessNonce((n) => n + 1)} />
        </div>
      </header>

      <section className="dashboard-kpis">
        <article className="kpi-card" data-testid="kpi-energy-ytd">
          <h2>Total Energy - YTD</h2>
          {ytd.status === "loading" ? <Loading label="Loading…" /> : null}
          {ytd.status === "error" ? <ErrorState error={ytd.error} onRetry={() => setYtdNonce((n) => n + 1)} /> : null}
          {ytd.status === "ready" && ytd.result ? (
            ytd.result.currentHasData ? (
              <>
                <p className="kpi-card__value">
                  {formatKwh(ytd.result.currentTotalKwh)} <span className="kpi-card__unit">kWh</span>
                </p>
                <EnergyDelta result={ytd.result} comparisonLabel="Previous Year" />
              </>
            ) : (
              <NoDataYet />
            )
          ) : null}
        </article>

        <article className="kpi-card" data-testid="kpi-energy-mtd">
          <h2>Total Energy - MTD</h2>
          {mtd.status === "loading" ? <Loading label="Loading…" /> : null}
          {mtd.status === "error" ? <ErrorState error={mtd.error} onRetry={() => setMtdNonce((n) => n + 1)} /> : null}
          {mtd.status === "ready" && mtd.result ? (
            mtd.result.currentHasData ? (
              <>
                <p className="kpi-card__value">
                  {formatKwh(mtd.result.currentTotalKwh)} <span className="kpi-card__unit">kWh</span>
                </p>
                <EnergyDelta result={mtd.result} comparisonLabel="Previous Month" />
              </>
            ) : (
              <NoDataYet />
            )
          ) : null}
        </article>

        <article className="kpi-card kpi-card--demand" data-testid="kpi-demand">
          <h2>
            Demand{" "}
            <Link to="/features/demand" className="kpi-card__link" aria-label="See Demand details">
              ›
            </Link>
          </h2>
          {demand.status === "loading" ? <Loading label="Loading…" /> : null}
          {demand.status === "error" ? (
            <ErrorState error={demand.error} onRetry={() => setDemandNonce((n) => n + 1)} />
          ) : null}
          {demand.status === "ready" ? (
            <dl className="kpi-card__stats">
              <div>
                <dt>Current</dt>
                {demand.current?.has_data ? (
                  <dd>{formatKw(demand.current.current_demand_kw)} kW</dd>
                ) : (
                  <dd className="kpi-card__stat-unavailable">No data available</dd>
                )}
              </div>
              <div>
                <dt>Peak (Today)</dt>
                {demand.peakToday ? (
                  <dd>{formatKw(demand.peakToday.kw)} kW</dd>
                ) : (
                  <dd className="kpi-card__stat-unavailable">No data available</dd>
                )}
              </div>
              <div>
                <dt>Max (This Month)</dt>
                {demand.maxThisMonth ? (
                  <dd>{formatKw(demand.maxThisMonth.kw)} kW</dd>
                ) : (
                  <dd className="kpi-card__stat-unavailable">No data available</dd>
                )}
              </div>
            </dl>
          ) : null}
        </article>
      </section>

      <section className="dashboard-card" data-testid="live-electrical-parameters">
        <h2>Live Electrical Parameters</h2>
        {/* Voltage / Current / Power Factor / Frequency have no site-level
            source in the customer /api/v1 API today (see file header). The
            intended field structure stays visible -- per product direction,
            an unbuilt capability is shown as a labelled placeholder, not
            hidden -- but every value is explicitly "Not available yet",
            never a guessed asset or a fabricated number. */}
        <dl className="kpi-card__stats live-params__stats">
          <div>
            <dt>Voltage</dt>
            <dd className="kpi-card__stat-unavailable">Not available yet</dd>
          </div>
          <div>
            <dt>Current</dt>
            <dd className="kpi-card__stat-unavailable">Not available yet</dd>
          </div>
          <div>
            <dt>Power Factor</dt>
            <dd className="kpi-card__stat-unavailable">Not available yet</dd>
          </div>
          <div>
            <dt>Frequency</dt>
            <dd className="kpi-card__stat-unavailable">Not available yet</dd>
          </div>
        </dl>
        <p className="dashboard-card__note">
          Live parameter streaming for this site isn't built yet -- this card is a placeholder for that planned
          capability, not a reading for this site.
        </p>
      </section>

      <section className="dashboard-card" data-testid="load-trend">
        <div className="dashboard-card__header">
          <h2>Load Trend</h2>
          <label className="load-trend__range">
            <span className="visually-hidden">Range</span>
            <select
              value={trendPreset}
              onChange={(e) => setTrendPreset(e.target.value as TimeRangePreset)}
              data-testid="load-trend-range"
            >
              {TREND_PRESETS.map((preset) => (
                <option key={preset} value={preset}>
                  {PRESET_LABELS[preset]}
                </option>
              ))}
            </select>
          </label>
        </div>
        {trend.status === "loading" ? <Loading label="Loading load trend…" /> : null}
        {trend.status === "error" ? <ErrorState error={trend.error} onRetry={() => setTrendNonce((n) => n + 1)} /> : null}
        {trend.unsupportedReason ? <NoDataYet message={trend.unsupportedReason} /> : null}
        {trend.status === "ready" && !trend.unsupportedReason && trend.series ? (
          trend.series.no_data ? (
            <NoDataYet />
          ) : (
            <ChartFrame points={trendPoints} valueLabel="Load" unit="kW" variant="area" height={260} />
          )
        ) : null}
      </section>
    </div>
  );
}
