/**
 * Slice B -- Power Quality Overview.
 *
 *   Current Value -- latest point's Power Factor (with trend) and the
 *                     three current-THD phase values (L1/L2/L3), each
 *                     explicitly labelled by phase -- no fabricated total
 *                     or cross-phase average (see migration 234's header:
 *                     no total-THD column exists in the source data).
 *   Comparison / Status -- OMITTED. No PF/THD threshold, target, or
 *                     deviation rule exists anywhere in the schema; none
 *                     is invented here (StatusBadge is not used on this
 *                     screen for that reason).
 *   Trend          -- Power Factor only (one ChartFrame). Per-phase THD
 *                     trend charts are not built in this increment --
 *                     current per-phase values are shown instead, keeping
 *                     the screen additive and minimal.
 *   Evidence/Data Quality -- OMITTED. telemetry.ca_energy_* carries no
 *                     quality/freshness column; nothing is fabricated to
 *                     fill that gap. A short note says so explicitly,
 *                     mirroring the Energy screen's honest treatment.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../../tenant/TenantProvider";
import { getSitePowerQuality, getSiteTelemetryFreshness } from "../../api/endpoints";
import type { PowerQualityPoint, PowerQualityResponse, SiteTelemetryFreshnessResponse } from "../../api/types";
import { planPowerQualityRequest, type TimeRangePreset } from "../../time/ranges";
import { HierarchyCrumb } from "../../components/HierarchyCrumb";
import { TimeRangePicker } from "../../components/TimeRangePicker";
import { ChartFrame, type ChartPoint } from "../../components/ChartFrame";
import { FreshnessIndicator } from "../../components/FreshnessIndicator";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { EmptyState } from "../../components/states/EmptyState";

type LoadStatus = "loading" | "ready" | "error";

function toPowerFactorChartPoints(series: PowerQualityPoint[]): ChartPoint[] {
  return series.map((point) => ({ t: Date.parse(point.bucket_start), value: point.power_factor_avg }));
}

/** Exported (MVP-3) so SiteOverview's Power Quality summary reuses this
 *  exact "current = latest point" convention instead of duplicating it. */
export function latestPowerQualityPoint(series: PowerQualityPoint[]): PowerQualityPoint | null {
  return series.length ? series[series.length - 1]! : null;
}

export function PowerQualityOverview() {
  const { selectedSite, sites } = useTenant();
  const [preset, setPreset] = useState<TimeRangePreset>("7D");
  const [status, setStatus] = useState<LoadStatus>("loading");
  const [error, setError] = useState<unknown>(null);
  const [unsupportedReason, setUnsupportedReason] = useState<string | null>(null);
  const [data, setData] = useState<PowerQualityResponse | null>(null);
  const [nonce, setNonce] = useState(0);
  // MVP-4 -- device freshness: the first trust signal this screen has ever
  // had (decision pack Sec 3). Still no reading-level PF/THD quality
  // concept -- this is device-level only, not a replacement for one.
  const [freshness, setFreshness] = useState<SiteTelemetryFreshnessResponse | null>(null);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setStatus("loading");
    setError(null);
    setUnsupportedReason(null);

    const plan = planPowerQualityRequest(preset);
    if (!plan.supported) {
      setUnsupportedReason(plan.reason);
      setStatus("ready");
      setData(null);
      return;
    }

    getSitePowerQuality(selectedSite.site_id, { resolution: plan.resolution, ...plan.range })
      .then((res) => {
        if (!active) return;
        setData(res);
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
      .then((res) => {
        if (active) setFreshness(res);
      })
      .catch(() => {
        if (active) setFreshness(null);
      });
    return () => {
      active = false;
    };
  }, [selectedSite]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  const current = data ? latestPowerQualityPoint(data.series) : null;

  return (
    <div className="page page--power-quality-overview" data-testid="page-power-quality-overview">
      <HierarchyCrumb
        siteName={selectedSite.site_name}
        multiSite={sites.length > 1}
        leaf={{ label: "Power Quality" }}
      />
      <h1>Power quality</h1>
      <p className="hint">
        Power Factor measures how efficiently electrical power is used. Total Harmonic Distortion (THD)
        measures waveform distortion on each supply phase.
      </p>

      <TimeRangePicker value={preset} onChange={setPreset} dataKind="power-quality" />

      {status === "loading" ? <Loading label="Loading power quality…" /> : null}
      {status === "error" ? <ErrorState error={error} onRetry={() => setNonce((n) => n + 1)} /> : null}
      {unsupportedReason ? <ErrorState title="Range not available" error={new Error(unsupportedReason)} /> : null}

      {status === "ready" && data ? (
        <>
          {/* Current Value -- PF */}
          <section className="pq-current-pf" data-testid="pq-current-pf">
            <h2>Power Factor</h2>
            {data.no_data || !current || current.power_factor_avg === null ? (
              <NoDataYet />
            ) : (
              <p className="value">{current.power_factor_avg.toFixed(2)}</p>
            )}
          </section>

          {/* Trend -- PF only */}
          <section className="pq-trend-pf" data-testid="pq-trend-pf">
            <h2>Power Factor trend</h2>
            {data.no_data ? (
              <NoDataYet />
            ) : (
              <ChartFrame points={toPowerFactorChartPoints(data.series)} valueLabel="Power Factor" />
            )}
          </section>

          {/* Current Value -- THD, explicitly per phase */}
          <section className="pq-current-thd" data-testid="pq-current-thd">
            <h2>Current THD by phase</h2>
            {data.no_data || !current ? (
              <NoDataYet />
            ) : (
              <ul>
                <li data-testid="pq-thd-l1">
                  L1: {current.current_thd_l1_avg !== null ? `${current.current_thd_l1_avg.toFixed(1)}%` : "—"}
                </li>
                <li data-testid="pq-thd-l2">
                  L2: {current.current_thd_l2_avg !== null ? `${current.current_thd_l2_avg.toFixed(1)}%` : "—"}
                </li>
                <li data-testid="pq-thd-l3">
                  L3: {current.current_thd_l3_avg !== null ? `${current.current_thd_l3_avg.toFixed(1)}%` : "—"}
                </li>
              </ul>
            )}
          </section>

          {/* Evidence / Data Quality -- reading-level PF/THD quality is
              still honestly absent, not fabricated (unchanged). MVP-4 adds
              the first real signal this screen has ever had: device
              connectivity/freshness -- a separate, device-level question,
              not a reading-level quality verdict. */}
          <section className="pq-evidence" data-testid="pq-evidence">
            <h2>Data quality</h2>
            <p className="hint">Reading-level power quality data quality indicators are not yet available.</p>
            <p className="pq-freshness" data-testid="pq-freshness">
              <FreshnessIndicator state={freshness?.power_quality.state} />
            </p>
          </section>
        </>
      ) : null}
    </div>
  );
}
