/**
 * MVP-3 -- Site Overview & Attention. The real composite landing screen,
 * replacing the Phase-8 ShellHome placeholder at the existing `/home`
 * route. Composes, in the agreed order (Q70):
 *
 *   1. Overall Site Health / Status
 *   2. Attention / Exceptions
 *   3. Energy Performance summary
 *   4. Maximum Demand summary
 *   5. Power Quality summary
 *   6. Investigation paths into Space -> Asset
 *
 * "Tell the customer the story first; provide analytical depth afterwards"
 * (Q70): each summary card is compact (value + status + a link into the
 * existing, unmodified full screen for that metric) -- the trend charts and
 * full comparison-basis pickers stay on EnergyOverview/DemandOverview/
 * PowerQualityOverview, not duplicated here.
 *
 * Every data point comes from ALREADY-LIVE endpoints, fetched in parallel
 * (no new API surface, per the approved MVP-3 decision pack):
 *   GET /sites/{id}/energy/consumption (+ .../evidence, .../typical-reference)
 *   GET /sites/{id}/demand (+ .../demand/current)
 *   GET /sites/{id}/power-quality
 *
 * The three groups (Energy, Demand, Power Quality) load and fail
 * independently -- one card's failure never blanks the others (matching
 * ems-information-architecture.md 4.3's documented Site Overview error
 * behaviour).
 *
 * Energy Attention (the only approved Attention rule for MVP-3) and Site
 * Health are pure derivations over the SAME data this page already fetches
 * for the Energy summary card -- see attention/energyAttention.ts and
 * attention/siteHealth.ts. Demand and Power Quality remain informational:
 * no materiality rule exists for either (no contract-demand or PF/THD
 * threshold is configured anywhere in the schema), so neither card carries
 * a status/attention treatment.
 */

import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useTenant } from "../tenant/TenantProvider";
import {
  getSiteCurrentDemand,
  getSiteDemandSeries,
  getSiteEnergyConsumption,
  getSiteEnergyConsumptionEvidence,
  getSiteEnergyTypicalReference,
  getSitePowerQuality,
} from "../api/endpoints";
import type {
  CurrentDemandResponse,
  DemandSeriesResponse,
  EnergyConsumptionEvidenceResponse,
  EnergyConsumptionResponse,
  EnergyTypicalReferenceResponse,
  PowerQualityResponse,
} from "../api/types";
import {
  planDemandRequest,
  planEnergyRequest,
  planEnergyTypicalReferenceRequest,
  planPowerQualityRequest,
  type TimeRangePreset,
} from "../time/ranges";
import { buildTypicalReferenceResult } from "../energy/comparison";
import { summarizeEnergyEvidence } from "../energy/evidence";
import { evaluateEnergyAttention } from "../attention/energyAttention";
import { deriveSiteHealth, siteHealthSummary } from "../attention/siteHealth";
import { MVP3_MATERIALITY_POLICY } from "../attention/materiality-policy";
import type { AttentionItem } from "../attention/types";
import { findPeak } from "./demand/DemandOverview";
import { latestPowerQualityPoint } from "./power-quality/PowerQualityOverview";
import { HierarchyCrumb } from "../components/HierarchyCrumb";
import { TimeRangePicker } from "../components/TimeRangePicker";
import { SiteHealthBanner } from "../components/SiteHealthBanner";
import { AttentionList } from "../components/AttentionList";
import { Loading } from "../components/states/Loading";
import { ErrorState } from "../components/states/ErrorState";
import { NoDataYet } from "../components/states/NoDataYet";
import { EmptyState } from "../components/states/EmptyState";

type SectionStatus = "loading" | "ready" | "error";

type EnergySection = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  current: EnergyConsumptionResponse | null;
  reference: EnergyTypicalReferenceResponse | null;
  evidence: EnergyConsumptionEvidenceResponse | null;
  window: { from: string; to: string } | null;
};

type DemandSection = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  current: CurrentDemandResponse | null;
  series: DemandSeriesResponse | null;
};

type PowerQualitySection = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  data: PowerQualityResponse | null;
};

const ENERGY_INITIAL: EnergySection = {
  status: "loading",
  error: null,
  unsupportedReason: null,
  current: null,
  reference: null,
  evidence: null,
  window: null,
};
const DEMAND_INITIAL: DemandSection = {
  status: "loading",
  error: null,
  unsupportedReason: null,
  current: null,
  series: null,
};
const PQ_INITIAL: PowerQualitySection = { status: "loading", error: null, unsupportedReason: null, data: null };

export function SiteOverview() {
  const { selectedSite, sites } = useTenant();
  const [preset, setPreset] = useState<TimeRangePreset>("7D");

  const [energy, setEnergy] = useState<EnergySection>(ENERGY_INITIAL);
  const [energyNonce, setEnergyNonce] = useState(0);
  const [demand, setDemand] = useState<DemandSection>(DEMAND_INITIAL);
  const [demandNonce, setDemandNonce] = useState(0);
  const [pq, setPq] = useState<PowerQualitySection>(PQ_INITIAL);
  const [pqNonce, setPqNonce] = useState(0);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setEnergy((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const consumptionPlan = planEnergyRequest(preset);
    const referencePlan = planEnergyTypicalReferenceRequest(preset);
    if (!consumptionPlan.supported) {
      setEnergy({ ...ENERGY_INITIAL, status: "ready", unsupportedReason: consumptionPlan.reason });
      return;
    }
    if (!referencePlan.supported) {
      setEnergy({ ...ENERGY_INITIAL, status: "ready", unsupportedReason: referencePlan.reason });
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
        setEnergy({
          status: "ready",
          error: null,
          unsupportedReason: null,
          current,
          reference,
          evidence,
          window: consumptionPlan.range,
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setEnergy((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, preset, energyNonce]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setDemand((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const plan = planDemandRequest(preset);
    if (!plan.supported) {
      setDemand({ ...DEMAND_INITIAL, status: "ready", unsupportedReason: plan.reason });
      return;
    }

    Promise.all([getSiteCurrentDemand(selectedSite.site_id), getSiteDemandSeries(selectedSite.site_id, plan.range)])
      .then(([current, series]) => {
        if (!active) return;
        setDemand({ status: "ready", error: null, unsupportedReason: null, current, series });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setDemand((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, preset, demandNonce]);

  useEffect(() => {
    if (!selectedSite) return;
    let active = true;
    setPq((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const plan = planPowerQualityRequest(preset);
    if (!plan.supported) {
      setPq({ ...PQ_INITIAL, status: "ready", unsupportedReason: plan.reason });
      return;
    }

    getSitePowerQuality(selectedSite.site_id, { resolution: plan.resolution, ...plan.range })
      .then((data) => {
        if (!active) return;
        setPq({ status: "ready", error: null, unsupportedReason: null, data });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setPq((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
  }, [selectedSite, preset, pqNonce]);

  if (!selectedSite) {
    return (
      <EmptyState title="No site selected">
        <Link to="/select">Select a site</Link>
      </EmptyState>
    );
  }

  // -- Energy Attention + Site Health -- pure derivations over the Energy
  // section's own already-fetched data. No second baseline mechanism; Slice
  // C's typical-reference is the only comparison this reads.
  const comparisonResult =
    energy.current && energy.reference ? buildTypicalReferenceResult(energy.current, energy.reference) : null;
  const evidenceSummary = energy.evidence ? summarizeEnergyEvidence(energy.evidence) : null;

  const attentionItems: AttentionItem[] = [];
  if (comparisonResult && energy.window) {
    const item = evaluateEnergyAttention({
      result: comparisonResult,
      evidence: evidenceSummary,
      policy: MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION,
      siteName: selectedSite.site_name,
      window: energy.window,
      investigatePath: "/features/energy",
    });
    if (item) attentionItems.push(item);
  }

  const energyAssessable = comparisonResult ? comparisonResult.sufficient && comparisonResult.currentHasData : false;
  const siteHealthState = deriveSiteHealth({ energyAssessable, attentionItems });
  const siteHealthKnown = energy.status === "ready" && !energy.unsupportedReason;

  const demandPeak = demand.series ? findPeak(demand.series.series) : null;
  const pqCurrent = pq.data ? latestPowerQualityPoint(pq.data.series) : null;

  return (
    <div className="page page--home page--site-overview" data-testid="page-home">
      <HierarchyCrumb siteName={selectedSite.site_name} multiSite={sites.length > 1} />
      <h1>Site Overview</h1>

      <TimeRangePicker value={preset} onChange={setPreset} dataKind="energy" />

      {/* 1. Overall Site Health / Status */}
      {siteHealthKnown ? (
        <SiteHealthBanner
          state={siteHealthState}
          summary={siteHealthSummary(siteHealthState, attentionItems.length)}
        />
      ) : energy.status === "loading" ? (
        <Loading label="Assessing site health…" />
      ) : energy.status === "error" ? (
        <ErrorState
          title="Couldn't assess site health"
          error={energy.error}
          onRetry={() => setEnergyNonce((n) => n + 1)}
        />
      ) : (
        <NoDataYet message={energy.unsupportedReason ?? "Site health isn't available for this range."} />
      )}

      {/* 2. Attention / Exceptions */}
      <section className="site-overview-attention" data-testid="site-overview-attention">
        <h2>Attention</h2>
        {!siteHealthKnown ? (
          <p className="hint">Attention isn't available until site health can be assessed.</p>
        ) : !energyAssessable ? (
          <p className="hint" data-testid="attention-insufficient-data">
            Not enough valid data to assess Attention for the selected period.
          </p>
        ) : (
          <AttentionList items={attentionItems} />
        )}
      </section>

      {/* 3. Energy Performance summary */}
      <section className="site-overview-energy" data-testid="site-overview-energy">
        <h2>Energy</h2>
        {energy.status === "loading" ? <Loading label="Loading energy…" /> : null}
        {energy.status === "error" ? (
          <ErrorState error={energy.error} onRetry={() => setEnergyNonce((n) => n + 1)} />
        ) : null}
        {energy.unsupportedReason ? <NoDataYet message={energy.unsupportedReason} /> : null}
        {energy.status === "ready" && !energy.unsupportedReason && energy.current ? (
          energy.current.no_data ? (
            <NoDataYet />
          ) : (
            <p data-testid="site-overview-energy-value">
              {comparisonResult?.currentTotalKwh?.toFixed(1) ?? "—"} kWh
              {comparisonResult?.deltaPercent !== null && comparisonResult?.deltaPercent !== undefined ? (
                <span data-testid="site-overview-energy-delta">
                  {" "}
                  ({comparisonResult.deltaPercent >= 0 ? "+" : ""}
                  {comparisonResult.deltaPercent.toFixed(1)}% vs. typical)
                </span>
              ) : null}
            </p>
          )
        ) : null}
        <Link to="/features/energy">See Energy details →</Link>
      </section>

      {/* 4. Maximum Demand summary -- informational only, no status/attention */}
      <section className="site-overview-demand" data-testid="site-overview-demand">
        <h2>Demand</h2>
        {demand.status === "loading" ? <Loading label="Loading demand…" /> : null}
        {demand.status === "error" ? (
          <ErrorState error={demand.error} onRetry={() => setDemandNonce((n) => n + 1)} />
        ) : null}
        {demand.unsupportedReason ? <NoDataYet message={demand.unsupportedReason} /> : null}
        {demand.status === "ready" && !demand.unsupportedReason && demand.current ? (
          demand.current.has_data ? (
            <p data-testid="site-overview-demand-value">
              {demand.current.current_demand_kw?.toFixed(1) ?? "—"} kW
              {demandPeak ? (
                <span data-testid="site-overview-demand-peak"> — peak {demandPeak.kw.toFixed(1)} kW</span>
              ) : null}
            </p>
          ) : (
            <NoDataYet />
          )
        ) : null}
        <Link to="/features/demand">See Demand details →</Link>
      </section>

      {/* 5. Power Quality summary -- informational only, no status/attention */}
      <section className="site-overview-power-quality" data-testid="site-overview-power-quality">
        <h2>Power Quality</h2>
        {pq.status === "loading" ? <Loading label="Loading power quality…" /> : null}
        {pq.status === "error" ? <ErrorState error={pq.error} onRetry={() => setPqNonce((n) => n + 1)} /> : null}
        {pq.unsupportedReason ? <NoDataYet message={pq.unsupportedReason} /> : null}
        {pq.status === "ready" && !pq.unsupportedReason && pq.data ? (
          pq.data.no_data || !pqCurrent || pqCurrent.power_factor_avg === null ? (
            <NoDataYet />
          ) : (
            <p data-testid="site-overview-pq-value">PF {pqCurrent.power_factor_avg.toFixed(2)}</p>
          )
        ) : null}
        <Link to="/features/power-quality">See Power Quality details →</Link>
      </section>

      {/* 6. Investigation paths into Space -> Asset */}
      <section className="site-overview-hierarchy" data-testid="site-overview-hierarchy">
        <h2>Investigate</h2>
        <ul>
          <li>
            <Link to="/features/spaces">Spaces →</Link>
          </li>
          <li>
            <Link to="/features/assets">Assets →</Link>
          </li>
        </ul>
      </section>
    </div>
  );
}
