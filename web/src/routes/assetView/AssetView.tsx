/**
 * Asset View -- per-asset detail screen. What is this asset (filters +
 * identity panel) -> how is it performing (Energy + Demand KPI tiles,
 * always "today", no selector) -> what is happening now (live electrical
 * parameter tiles) -> what happened over time (Power Trend + Demand
 * charts, EACH with its own independent time-range selector). No asset
 * selected -> nothing below the identity panel renders.
 *
 * Live tiles: GET .../live-state (initial snapshot) + useAssetLiveSocket's
 * WebSocket (every update after) -- see that hook's own header for the
 * REST-vs-socket race contract. Total + each parameter's own
 * customer-facing phase labels (assetLiveParams.ts). A tile is shown only
 * once evidence exists that this asset has ever reported it (row presence
 * in telemetry.device_live_point_state, an upsert-only cache -- see
 * migration 022) -- merely stale/offline still shows; never-reported hides.
 *
 * Energy tile: GET .../energy/consumption, fetched for "Today" (site-local
 * midnight through now) and for the SAME clock-time window exactly one day
 * earlier (timeRange.ts#shiftRangeByOneDay -- a fixed 24h shift, not
 * time/ranges.ts's own duration-equal PREVIOUS_PERIOD, which would be
 * wrong for a partial "today" window; see that function's own doc
 * comment). Summation/delta/evidence counting: assetEnergy.ts. The evidence
 * InfoDisclosure sits beside the "Energy (kWh)" heading itself, shown only
 * when the current window has a reset/gap interval.
 *
 * Demand tile: current_demand_kw (GET .../demand/current, analytics.
 * demand_state, continuously recalculated for the still-open interval) +
 * Max Demand = MAX(demand_kw) over TODAY's finalized 15-minute intervals
 * (assetDemand.ts#findMaxDemand -- demand_kw, deliberately NOT
 * peak_power_kw/DemandOverview.tsx's findPeak, which Site Demand's own
 * "Peak Power" presentation uses instead; the two screens' Demand
 * presentations are no longer the same by design). No quality_status line
 * -- an always-shown InfoDisclosure beside "Current Demand (kW)" explains
 * what the figure is instead.
 *
 * Power Trend / Demand charts: each owns its own local time-range preset
 * (Today/Yesterday/1 Week/1 Month, calendar-aligned in the site's
 * timezone -- see ./timeRange.ts), independent of the KPI tiles and of
 * each other. The Demand chart additionally appends the live, still-open
 * interval (assetDemand.ts#buildDemandChartPoints) when it falls inside
 * the chart's own requested window -- GET .../demand only returns
 * FINALIZED intervals (analytics.demand_intervals), which lag "now" by up
 * to the interval length plus a ~10-minute processing grace (traced in
 * migration 013); this closes that gap using data already fetched for the
 * KPI tile, no backend change. Both charts pass the site's timezone and
 * unit through to ChartFrame's timeZone/axisUnitLabel props, and every
 * plotted/hovered value is rounded to 2 decimals by ChartFrame itself
 * (formatValue) -- not reimplemented per chart.
 *
 * Intentionally not shown at all (not even as an "unavailable" placeholder):
 *   - Voltage THD: no logical point exists in the schema at all.
 *   - Historical PF/THD trend, asset-level Attention/health, contract-demand
 *     utilization, and full component-tree navigation: no read path exists
 *     for any of these yet and none is invented here.
 */

import { useEffect, useMemo, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import {
  getAssetCurrentDemand,
  getAssetDemandSeries,
  getAssetEnergyConsumption,
  getAssetLiveState,
  getAssetPowerTrend,
  getSiteAssets,
} from "../../api/endpoints";
import type {
  AssetCurrentDemandResponse,
  AssetDemandSeriesResponse,
  AssetLivePoint,
  AssetPowerTrendResponse,
  AssetSummary,
} from "../../api/types";
import { deriveStatusTone } from "../../components/StatusBadge";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { ChartFrame } from "../../components/ChartFrame";
import { InfoDisclosure } from "../../components/InfoDisclosure";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { EmptyState } from "../../components/states/EmptyState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { formatInTimeZone, formatTime12hInTimeZone } from "../../time/format";
import {
  ASSET_TIME_RANGE_LABELS,
  ASSET_TIME_RANGE_PRESETS,
  resolveAssetTimeRange,
  shiftRangeByOneDay,
  type AssetTimeRangePreset,
} from "./timeRange";
import { LIVE_PARAM_DEFS, findLivePoint, mostRecentReceivedAt, type LiveParamDef } from "./assetLiveParams";
import { buildAssetEnergyComparison, type AssetEnergyComparison } from "./assetEnergy";
import { buildDemandChartPoints, findMaxDemand } from "./assetDemand";
import { hasEstimatedSamples, toPowerTrendChartPoints } from "./assetPowerTrend";
import { shouldApplyRestSnapshot, useAssetLiveSocket } from "./useAssetLiveSocket";

type LoadStatus = "loading" | "ready" | "error";

// No unit suffix -- the unit is already stated once in the tile heading
// (LIVE_PARAM_DEFS' label, e.g. "Power (kW)"), not repeated beside every
// individual Total/P1/P2/P3 reading.
function formatLiveValue(point: AssetLivePoint | null): string {
  if (!point) return "—";
  if (point.numeric_value === null) return point.text_value ?? "—";
  return point.numeric_value.toFixed(2);
}

function locationLabel(asset: AssetSummary): string {
  return [asset.building_name, asset.floor_name, asset.space_name].filter(Boolean).join(" / ") || "Unplaced";
}

function formatKwh(value: number | null): string {
  if (value === null) return "—";
  return Math.round(value).toLocaleString();
}

function EnergyTile({
  hasAsset,
  status,
  error,
  comparison,
  onRetry,
}: {
  hasAsset: boolean;
  status: LoadStatus;
  error: unknown;
  comparison: AssetEnergyComparison | null;
  onRetry: () => void;
}) {
  const hasEvidence =
    hasAsset &&
    status === "ready" &&
    comparison !== null &&
    (comparison.resetIntervalCount > 0 || comparison.gapIntervalCount > 0);

  return (
    <article className="kpi-card kpi-card--primary" data-testid="asset-energy-tile">
      <h2>
        Energy (kWh)
        {hasEvidence ? (
          <InfoDisclosure
            label="Energy (kWh)"
            explanation={energyEvidenceExplanation(comparison!)}
            testId="asset-energy-evidence"
          />
        ) : null}
      </h2>
      {!hasAsset ? <p className="hint">Select an asset to view this.</p> : null}
      {hasAsset && status === "loading" ? <Loading label="Loading…" /> : null}
      {hasAsset && status === "error" ? (
        <ErrorState title="Energy data unavailable" error={error} onRetry={onRetry} />
      ) : null}
      {hasAsset && status === "ready" && comparison ? (
        comparison.currentHasData ? (
          <>
            <p className="kpi-card__value">{formatKwh(comparison.currentTotalKwh)}</p>
            {comparison.deltaPercent !== null && comparison.comparisonTotalKwh !== null ? (
              (() => {
                const tone = deriveStatusTone(comparison.deltaPercent);
                const arrow = tone === "higher" ? "↑" : tone === "lower" ? "↓" : "→";
                return (
                  <p className={`kpi-card__delta kpi-card__delta--${tone}`} data-testid="asset-energy-delta">
                    <span className="kpi-card__delta-figure">
                      <span aria-hidden="true">{arrow}</span> {comparison.deltaPercent >= 0 ? "+" : ""}
                      {comparison.deltaPercent.toFixed(1)}%
                    </span>
                    <span className="kpi-card__delta-basis">
                      vs. {formatKwh(comparison.comparisonTotalKwh)} kWh (Yesterday)
                    </span>
                  </p>
                );
              })()
            ) : (
              <p className="kpi-card__delta kpi-card__delta--unknown" data-testid="asset-energy-delta-unknown">
                Comparison not available for this period.
              </p>
            )}
          </>
        ) : (
          <NoDataYet />
        )
      ) : null}
    </article>
  );
}

function energyEvidenceExplanation(comparison: AssetEnergyComparison): string {
  const parts: string[] = [];
  if (comparison.gapIntervalCount > 0) {
    parts.push(
      `${comparison.gapIntervalCount} interval${comparison.gapIntervalCount === 1 ? "" : "s"} in this period had a missing reading`,
    );
  }
  if (comparison.resetIntervalCount > 0) {
    parts.push(
      `${comparison.resetIntervalCount} interval${comparison.resetIntervalCount === 1 ? "" : "s"} were affected by a meter reset`,
    );
  }
  return `${parts.join(", and ")}. The total shown may be incomplete for those intervals.`;
}

function LiveParamTile({
  def,
  points,
  status,
  error,
  hasAsset,
  onRetry,
}: {
  def: LiveParamDef;
  points: AssetLivePoint[];
  status: LoadStatus;
  error: unknown;
  hasAsset: boolean;
  onRetry: () => void;
}) {
  const total = findLivePoint(points, def.totalPoint);
  const phases = def.phasePoints.map((p) => findLivePoint(points, p));
  const anyReading = total !== null || phases.some((p) => p !== null);

  return (
    <article className="kpi-card live-param-card" data-testid={`live-param-${def.key}`}>
      <h2>{def.label}</h2>
      {!hasAsset ? <p className="hint">Select an asset to view this.</p> : null}
      {hasAsset && status === "loading" ? <Loading label="Loading…" /> : null}
      {hasAsset && status === "error" ? (
        <ErrorState title="Live reading unavailable" error={error} onRetry={onRetry} />
      ) : null}
      {hasAsset && status === "ready" ? (
        anyReading ? (
          <>
            <p className="kpi-card__value live-param-card__total">{formatLiveValue(total)}</p>
            <dl className="live-param-card__phases">
              {def.phasePoints.map((name, i) => (
                <div key={name}>
                  <dt>{def.phaseLabels[i]}</dt>
                  <dd>{formatLiveValue(phases[i]!)}</dd>
                </div>
              ))}
            </dl>
          </>
        ) : (
          <NoDataYet message="No live reading yet." />
        )
      ) : null}
    </article>
  );
}

function DemandTile({
  hasAsset,
  status,
  error,
  current,
  maxDemand,
  siteTimezone,
  onRetry,
}: {
  hasAsset: boolean;
  status: LoadStatus;
  error: unknown;
  current: AssetCurrentDemandResponse | null;
  maxDemand: { kw: number; at: string } | null;
  siteTimezone: string | null;
  onRetry: () => void;
}) {
  return (
    <article className="kpi-card kpi-card--primary" data-testid="asset-demand-tile">
      <h2>
        Current Demand (kW)
        <InfoDisclosure
          label="Current Demand"
          explanation="This is the latest available calculated demand value for this asset."
          testId="asset-demand-current"
        />
      </h2>
      {!hasAsset ? <p className="hint">Select an asset to view this.</p> : null}
      {hasAsset && status === "loading" ? <Loading label="Loading…" /> : null}
      {hasAsset && status === "error" ? (
        <ErrorState title="Demand data unavailable" error={error} onRetry={onRetry} />
      ) : null}
      {hasAsset && status === "ready" && current ? (
        current.has_data ? (
          <>
            <p className="kpi-card__value" data-testid="asset-demand-current-value">
              {current.current_demand_kw?.toFixed(1) ?? "—"}
            </p>
            <div className="demand-peak" data-testid="asset-demand-max">
              <span className="demand-peak__label">Max Demand</span>
              <span className="demand-peak__value">
                {maxDemand
                  ? `${maxDemand.kw.toFixed(1)} kW (${formatTime12hInTimeZone(maxDemand.at, siteTimezone)})`
                  : "Not recorded for today yet."}
              </span>
            </div>
          </>
        ) : (
          <NoDataYet message="No current demand reading yet for this asset." />
        )
      ) : null}
    </article>
  );
}

export function AssetView() {
  const { selectedSite } = useTenant();

  const [assetsStatus, setAssetsStatus] = useState<LoadStatus>("loading");
  const [assetsError, setAssetsError] = useState<unknown>(null);
  const [assets, setAssets] = useState<AssetSummary[]>([]);
  const [assetsNonce, setAssetsNonce] = useState(0);

  const [locationFilter, setLocationFilter] = useState("");
  const [typeFilter, setTypeFilter] = useState("");
  const [selectedAssetId, setSelectedAssetId] = useState("");

  const [restSnapshotStatus, setRestSnapshotStatus] = useState<LoadStatus>("ready");
  const [restSnapshotError, setRestSnapshotError] = useState<unknown>(null);
  const [restSnapshotPoints, setRestSnapshotPoints] = useState<AssetLivePoint[] | null>(null);
  const [liveNonce, setLiveNonce] = useState(0);

  // Energy + Demand KPI tiles always show "today" -- no selector; see this
  // file's own header.
  const [energyStatus, setEnergyStatus] = useState<LoadStatus>("ready");
  const [energyError, setEnergyError] = useState<unknown>(null);
  const [energyComparison, setEnergyComparison] = useState<AssetEnergyComparison | null>(null);
  const [energyNonce, setEnergyNonce] = useState(0);

  const [demandStatus, setDemandStatus] = useState<LoadStatus>("ready");
  const [demandError, setDemandError] = useState<unknown>(null);
  const [demandCurrent, setDemandCurrent] = useState<AssetCurrentDemandResponse | null>(null);
  const [demandTodaySeries, setDemandTodaySeries] = useState<AssetDemandSeriesResponse | null>(null);
  const [demandNonce, setDemandNonce] = useState(0);

  // Power Trend and Demand charts each own an independent time-range
  // selector, decoupled from the KPI tiles above and from each other.
  const [powerTrendPreset, setPowerTrendPreset] = useState<AssetTimeRangePreset>("TODAY");
  const [powerTrendStatus, setPowerTrendStatus] = useState<LoadStatus>("ready");
  const [powerTrendError, setPowerTrendError] = useState<unknown>(null);
  const [powerTrend, setPowerTrend] = useState<AssetPowerTrendResponse | null>(null);
  const [powerTrendNonce, setPowerTrendNonce] = useState(0);

  const [demandChartPreset, setDemandChartPreset] = useState<AssetTimeRangePreset>("TODAY");
  const [demandChartStatus, setDemandChartStatus] = useState<LoadStatus>("ready");
  const [demandChartError, setDemandChartError] = useState<unknown>(null);
  const [demandChartSeries, setDemandChartSeries] = useState<AssetDemandSeriesResponse | null>(null);
  const [demandChartNonce, setDemandChartNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setAssetsStatus("loading");
    setAssetsError(null);
    getSiteAssets(selectedSite.site_id)
      .then((res) => {
        if (!active) return;
        setAssets(res.assets);
        setAssetsStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setAssetsError(err);
        setAssetsStatus("error");
      });
    return () => {
      active = false;
    };
  }, [selectedSite, assetsNonce]);

  useEffect(() => {
    setLocationFilter("");
    setTypeFilter("");
    setSelectedAssetId("");
  }, [selectedSite?.site_id]);

  const locationOptions = useMemo(() => {
    const set = new Set<string>();
    for (const a of assets) set.add(locationLabel(a));
    return [...set].sort();
  }, [assets]);

  const assetsAfterLocation = useMemo(
    () => (locationFilter ? assets.filter((a) => locationLabel(a) === locationFilter) : assets),
    [assets, locationFilter],
  );

  const typeOptions = useMemo(() => {
    const set = new Set<string>();
    for (const a of assetsAfterLocation) if (a.asset_type_name) set.add(a.asset_type_name);
    return [...set].sort();
  }, [assetsAfterLocation]);

  const assetsAfterType = useMemo(
    () => (typeFilter ? assetsAfterLocation.filter((a) => a.asset_type_name === typeFilter) : assetsAfterLocation),
    [assetsAfterLocation, typeFilter],
  );

  // Dynamic filtering: an earlier filter narrowing the list clears a later
  // selection that's no longer in scope, rather than silently keeping a
  // stale, now-hidden selection.
  useEffect(() => {
    if (typeFilter && !typeOptions.includes(typeFilter)) setTypeFilter("");
  }, [typeOptions, typeFilter]);

  useEffect(() => {
    if (selectedAssetId && !assetsAfterType.some((a) => a.asset_id === selectedAssetId)) {
      setSelectedAssetId("");
    }
  }, [assetsAfterType, selectedAssetId]);

  const selectedAsset = useMemo(
    () => assets.find((a) => a.asset_id === selectedAssetId) ?? null,
    [assets, selectedAssetId],
  );

  const parentAsset = useMemo(
    () =>
      selectedAsset?.parent_asset_id
        ? (assets.find((a) => a.asset_id === selectedAsset.parent_asset_id) ?? null)
        : null,
    [assets, selectedAsset],
  );

  // Live updates after the initial snapshot come from the portal-session
  // WebSocket, not polling -- see useAssetLiveSocket.ts.
  const liveSocket = useAssetLiveSocket(selectedSite?.site_id ?? null, selectedAssetId || null);

  // Mirrors liveSocket.points for the REST effect below to read synchronously
  // at resolution time, without retriggering that effect on every socket
  // message (it must only re-run on asset/site change, per the hook's own
  // "no polling" contract).
  const liveSocketPointsRef = useRef(liveSocket.points);
  useEffect(() => {
    liveSocketPointsRef.current = liveSocket.points;
  }, [liveSocket.points]);

  useEffect(() => {
    setRestSnapshotPoints(null);

    if (!selectedSite || !selectedAssetId) {
      setRestSnapshotStatus("ready");
      setRestSnapshotError(null);
      return;
    }
    let active = true;
    setRestSnapshotStatus("loading");
    setRestSnapshotError(null);
    getAssetLiveState(selectedSite.site_id, selectedAssetId)
      .then((res) => {
        if (!active) return;
        if (shouldApplyRestSnapshot({ points: liveSocketPointsRef.current })) {
          setRestSnapshotPoints(res.points);
        }
        setRestSnapshotStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setRestSnapshotError(err);
        setRestSnapshotStatus("error");
      });
    return () => {
      active = false;
    };
  }, [selectedSite, selectedAssetId, liveNonce]);

  // The socket's own retained points (once it has delivered anything for
  // this asset) always win over the REST snapshot -- that's the same
  // "no regressing a fresher reading" rule shouldApplyRestSnapshot enforces
  // on write; this is its read-side mirror.
  const livePoints = useMemo(
    () => liveSocket.points ?? restSnapshotPoints ?? [],
    [liveSocket.points, restSnapshotPoints],
  );
  // A live socket delivery counts as "ready" even if the initial REST
  // snapshot itself failed -- the asset has current data either way, and an
  // error banner would be dishonest once real readings are on screen.
  const liveStatus: LoadStatus = liveSocket.points !== null ? "ready" : restSnapshotStatus;
  const liveError = liveSocket.points !== null ? null : restSnapshotError;

  // Energy KPI tile -- always "Today" vs. the SAME clock-time window
  // exactly one day earlier (shiftRangeByOneDay); see this file's header.
  useEffect(() => {
    if (!selectedSite || !selectedAssetId) {
      setEnergyComparison(null);
      setEnergyStatus("ready");
      return;
    }
    let active = true;
    setEnergyStatus("loading");
    setEnergyError(null);

    const current = resolveAssetTimeRange("TODAY", selectedSite.timezone);
    const previous = shiftRangeByOneDay(current);

    Promise.all([
      getAssetEnergyConsumption(selectedSite.site_id, selectedAssetId, current),
      getAssetEnergyConsumption(selectedSite.site_id, selectedAssetId, previous),
    ])
      .then(([currentRes, previousRes]) => {
        if (!active) return;
        setEnergyComparison(buildAssetEnergyComparison(currentRes, previousRes));
        setEnergyStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setEnergyError(err);
        setEnergyStatus("error");
      });

    return () => {
      active = false;
    };
  }, [selectedSite, selectedAssetId, energyNonce]);

  // Demand KPI tile -- current value + today's series (for Max Demand),
  // always "Today", independent of either chart's own selector below.
  useEffect(() => {
    if (!selectedSite || !selectedAssetId) {
      setDemandCurrent(null);
      setDemandTodaySeries(null);
      setDemandStatus("ready");
      return;
    }
    let active = true;
    setDemandStatus("loading");
    setDemandError(null);

    const range = resolveAssetTimeRange("TODAY", selectedSite.timezone);

    Promise.all([
      getAssetCurrentDemand(selectedSite.site_id, selectedAssetId),
      getAssetDemandSeries(selectedSite.site_id, selectedAssetId, range),
    ])
      .then(([currentRes, seriesRes]) => {
        if (!active) return;
        setDemandCurrent(currentRes);
        setDemandTodaySeries(seriesRes);
        setDemandStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setDemandError(err);
        setDemandStatus("error");
      });

    return () => {
      active = false;
    };
  }, [selectedSite, selectedAssetId, demandNonce]);

  // Power Trend chart -- its own independent time-range selector.
  useEffect(() => {
    if (!selectedSite || !selectedAssetId) {
      setPowerTrend(null);
      setPowerTrendStatus("ready");
      return;
    }
    let active = true;
    setPowerTrendStatus("loading");
    setPowerTrendError(null);

    const range = resolveAssetTimeRange(powerTrendPreset, selectedSite.timezone);

    getAssetPowerTrend(selectedSite.site_id, selectedAssetId, range)
      .then((res) => {
        if (!active) return;
        setPowerTrend(res);
        setPowerTrendStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setPowerTrendError(err);
        setPowerTrendStatus("error");
      });

    return () => {
      active = false;
    };
  }, [selectedSite, selectedAssetId, powerTrendPreset, powerTrendNonce]);

  // Demand chart -- its own independent time-range selector, decoupled
  // from the KPI tile's own fixed-Today fetch above.
  useEffect(() => {
    if (!selectedSite || !selectedAssetId) {
      setDemandChartSeries(null);
      setDemandChartStatus("ready");
      return;
    }
    let active = true;
    setDemandChartStatus("loading");
    setDemandChartError(null);

    const range = resolveAssetTimeRange(demandChartPreset, selectedSite.timezone);

    getAssetDemandSeries(selectedSite.site_id, selectedAssetId, range)
      .then((res) => {
        if (!active) return;
        setDemandChartSeries(res);
        setDemandChartStatus("ready");
      })
      .catch((err: unknown) => {
        if (!active) return;
        setDemandChartError(err);
        setDemandChartStatus("error");
      });

    return () => {
      active = false;
    };
  }, [selectedSite, selectedAssetId, demandChartPreset, demandChartNonce]);

  const demandMaxToday = useMemo(
    () => (demandTodaySeries ? findMaxDemand(demandTodaySeries.series) : null),
    [demandTodaySeries],
  );

  // Hide a live-parameter tile only once we have real evidence (from this
  // asset's own returned points, REST or socket) that it never once
  // reported that measurement -- never merely because its current reading
  // is null/stale. See this file's own header note for the full reasoning
  // and its one known limitation.
  const visibleLiveParamDefs = useMemo(() => {
    if (liveStatus !== "ready") return LIVE_PARAM_DEFS;
    return LIVE_PARAM_DEFS.filter((def) => {
      const total = findLivePoint(livePoints, def.totalPoint);
      const anyPhase = def.phasePoints.some((p) => findLivePoint(livePoints, p) !== null);
      return total !== null || anyPhase;
    });
  }, [liveStatus, livePoints]);

  const lastUpdated = mostRecentReceivedAt(livePoints);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  const hasAsset = selectedAsset !== null;

  return (
    <div className="page page--asset-view" data-testid="page-asset-view">
      {/* Organisation -> Site -> Asset. Unlike every other screen's
          multiSite={sites.length > 1} (a "Portfolio" segment gated on
          whether this user has more than one site), this leading segment
          always shows the site's real organization_name -- Organisation is
          identity context, not a portfolio-of-many indicator, so it's shown
          even for a single-site customer. Scoped to this screen only, per
          the Asset View product decision; HierarchyCrumb's own default
          "Sites"/multiSite behavior for every other caller is unchanged. */}
      <HierarchyCrumb
        siteName={selectedSite.site_name}
        multiSite
        leaf={selectedAsset ? { label: selectedAsset.asset_name } : { label: "Asset View" }}
        portfolioLabel={selectedSite.organization_name}
        siteHref="/dashboard"
      />

      <section className="asset-view-toolbar" data-testid="asset-view-toolbar">
        <div className="asset-view-filters">
          <label className="asset-view-filter">
            <span>Location</span>
            <select
              value={locationFilter}
              onChange={(e) => setLocationFilter(e.target.value)}
              disabled={assetsStatus !== "ready" || locationOptions.length === 0}
              data-testid="filter-location"
            >
              <option value="">All locations</option>
              {locationOptions.map((loc) => (
                <option key={loc} value={loc}>
                  {loc}
                </option>
              ))}
            </select>
          </label>
          <label className="asset-view-filter">
            <span>Asset Type</span>
            <select
              value={typeFilter}
              onChange={(e) => setTypeFilter(e.target.value)}
              disabled={assetsStatus !== "ready" || typeOptions.length === 0}
              data-testid="filter-type"
            >
              <option value="">All types</option>
              {typeOptions.map((t) => (
                <option key={t} value={t}>
                  {t}
                </option>
              ))}
            </select>
          </label>
          <label className="asset-view-filter">
            <span>Asset</span>
            <select
              value={selectedAssetId}
              onChange={(e) => setSelectedAssetId(e.target.value)}
              disabled={assetsStatus !== "ready" || assetsAfterType.length === 0}
              data-testid="filter-asset"
            >
              <option value="">Select an asset</option>
              {assetsAfterType.map((a) => (
                <option key={a.asset_id} value={a.asset_id}>
                  {a.asset_name}
                </option>
              ))}
            </select>
          </label>
        </div>

        <div className="asset-view-time">
          <p className="asset-view-last-updated" data-testid="asset-view-last-updated">
            Last updated:{" "}
            {hasAsset
              ? lastUpdated
                ? formatInTimeZone(lastUpdated, selectedSite.timezone, {
                    weekday: "short",
                    day: "2-digit",
                    month: "short",
                    year: "numeric",
                    hour: "2-digit",
                    minute: "2-digit",
                  })
                : "not available"
              : "—"}
          </p>
        </div>
      </section>

      <section className="asset-detail-panel" data-testid="asset-detail-panel">
        {assetsStatus === "loading" ? <Loading label="Loading assets…" /> : null}
        {assetsStatus === "error" ? (
          <ErrorState error={assetsError} onRetry={() => setAssetsNonce((n) => n + 1)} />
        ) : null}
        {assetsStatus === "ready" && assets.length === 0 ? <EmptyState title="No assets at this site yet" /> : null}
        {assetsStatus === "ready" && assets.length > 0 && !selectedAsset ? <h1>Select an asset</h1> : null}
        {selectedAsset ? (
          <>
            <h1>{selectedAsset.asset_name}</h1>
            <p className="asset-detail-panel__meta" data-testid="asset-detail-meta">
              Type: {selectedAsset.asset_type_name ?? "—"} | Location: {locationLabel(selectedAsset)}
              {parentAsset ? <> | Hierarchy: {parentAsset.asset_name}</> : null}
            </p>
          </>
        ) : null}
      </section>

      {/* No asset selected -- render nothing below the identity panel
          (which already shows its own calm "Select an asset" heading)
          rather than a grid of per-tile "Select an asset to view this."
          placeholders. */}
      {hasAsset ? (
        <>
          {/* How is it performing? + What is happening now? -- Energy and
              Demand (stronger visual weight via kpi-card--primary) and the
              individual electrical parameters share one row/grid now that
              the tiles are compact enough to sit together. Only
              measurements this asset has actual evidence of are shown --
              see visibleLiveParamDefs above and this file's own header
              note. Voltage THD is never shown at all (no logical point
              exists for it in the schema). */}
          <section className="dashboard-kpis asset-view-kpis" data-testid="asset-view-kpis">
            <EnergyTile
              hasAsset={hasAsset}
              status={energyStatus}
              error={energyError}
              comparison={energyComparison}
              onRetry={() => setEnergyNonce((n) => n + 1)}
            />
            <DemandTile
              hasAsset={hasAsset}
              status={demandStatus}
              error={demandError}
              current={demandCurrent}
              maxDemand={demandMaxToday}
              siteTimezone={selectedSite.timezone}
              onRetry={() => setDemandNonce((n) => n + 1)}
            />
            {visibleLiveParamDefs.map((def) => (
              <LiveParamTile
                key={def.key}
                def={def}
                points={livePoints}
                status={liveStatus}
                error={liveError}
                hasAsset={hasAsset}
                onRetry={() => setLiveNonce((n) => n + 1)}
              />
            ))}
          </section>

          {/* What happened over time? -- historical charts, each with its
              own independent time-range selector, in the site's own
              timezone with an explicit kW unit on the axis. */}
          <section className="dashboard-card" data-testid="asset-power-trend">
            <div className="dashboard-card__header">
              <h2>Power Trend</h2>
              <select
                value={powerTrendPreset}
                onChange={(e) => setPowerTrendPreset(e.target.value as AssetTimeRangePreset)}
                data-testid="asset-power-trend-range"
              >
                {ASSET_TIME_RANGE_PRESETS.map((preset) => (
                  <option key={preset} value={preset}>
                    {ASSET_TIME_RANGE_LABELS[preset]}
                  </option>
                ))}
              </select>
            </div>
            {powerTrendStatus === "loading" ? (
              <Loading label="Loading…" />
            ) : powerTrendStatus === "error" ? (
              <ErrorState
                title="Power trend unavailable"
                error={powerTrendError}
                onRetry={() => setPowerTrendNonce((n) => n + 1)}
              />
            ) : powerTrend && !powerTrend.no_data ? (
              <>
                <ChartFrame
                  points={toPowerTrendChartPoints(powerTrend.series)}
                  valueLabel="Power"
                  unit="kW"
                  timeZone={selectedSite.timezone}
                  axisUnitLabel
                />
                {hasEstimatedSamples(powerTrend.series) ? (
                  <p className="dashboard-card__note">Some readings in this period are estimated.</p>
                ) : null}
              </>
            ) : (
              <NoDataYet message="No power trend data for this period yet." />
            )}
          </section>

          <section className="dashboard-card" data-testid="asset-demand-chart">
            <div className="dashboard-card__header">
              <h2>Demand</h2>
              <select
                value={demandChartPreset}
                onChange={(e) => setDemandChartPreset(e.target.value as AssetTimeRangePreset)}
                data-testid="asset-demand-chart-range"
              >
                {ASSET_TIME_RANGE_PRESETS.map((preset) => (
                  <option key={preset} value={preset}>
                    {ASSET_TIME_RANGE_LABELS[preset]}
                  </option>
                ))}
              </select>
            </div>
            {demandChartStatus === "loading" ? (
              <Loading label="Loading…" />
            ) : demandChartStatus === "error" ? (
              <ErrorState
                title="Demand trend unavailable"
                error={demandChartError}
                onRetry={() => setDemandChartNonce((n) => n + 1)}
              />
            ) : demandChartSeries ? (
              (() => {
                // Appends the still-open interval's live value (already
                // fetched for the KPI tile) when it falls inside this
                // chart's own requested window -- see assetDemand.ts
                // #buildDemandChartPoints for why GET .../demand alone
                // lags "now" by up to ~30 minutes.
                const points = buildDemandChartPoints(
                  demandChartSeries.series,
                  demandCurrent,
                  resolveAssetTimeRange(demandChartPreset, selectedSite.timezone),
                );
                return points.length > 0 ? (
                  <ChartFrame
                    points={points}
                    valueLabel="Demand"
                    unit="kW"
                    timeZone={selectedSite.timezone}
                    axisUnitLabel
                  />
                ) : (
                  <NoDataYet message="No demand trend data for this period yet." />
                );
              })()
            ) : (
              <NoDataYet message="No demand trend data for this period yet." />
            )}
          </section>
        </>
      ) : null}
    </div>
  );
}
