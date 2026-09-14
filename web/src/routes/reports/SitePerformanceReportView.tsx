/**
 * MVP-6 -- Q76 Site Performance Report. The generated report itself
 * (EMS-REQ-112/113). Reuses the exact same API calls and pure derivation
 * functions `SiteOverview.tsx` already uses for its own six sections --
 * no second computation path, satisfying EMS-REQ-093's parity requirement
 * by construction (ADR-015 Rationale). SiteOverview.tsx itself is not
 * imported or modified; this is an independent screen built from the same
 * underlying, already-live building blocks.
 *
 * Per ADR-015 gap resolution 1: report content (Health/Attention/Energy/
 * Demand/Power-Quality) is always the configured Site's own data --
 * Space/Asset hierarchy selection changes only the title and the
 * Investigation section's link target, because no Space/Asset-scoped
 * equivalent of these analytics exists anywhere in the platform.
 *
 * Per ADR-015 gap resolution 6: Site Health/Attention require the Slice C
 * typical-reference endpoint's exact whole-day window (1/7/30/90/365 days)
 * -- calendar-to-date periods will usually not satisfy this, so those two
 * sections legitimately read "not available for this period" most of the
 * time. This is an existing API constraint, not a defect introduced here.
 *
 * Unlike the Demand/Power-Quality *screens* (DemandOverview/
 * PowerQualityOverview), which show a live "current" reading, a report
 * about a period shows the PEAK demand and the period's latest Power
 * Factor point *within that period* -- "current, right now" has no
 * meaning for a report about the past. Both still come from the same
 * existing findPeak/latestPowerQualityPoint functions, just applied to a
 * historical range instead of "now".
 */

import { useEffect, useMemo, useState } from "react";
import { Link } from "react-router-dom";
import {
  getSiteDemandSeries,
  getSiteEnergyConsumption,
  getSiteEnergyConsumptionEvidence,
  getSiteEnergyTypicalReference,
  getSitePowerQuality,
} from "../../api/endpoints";
import type {
  DemandSeriesResponse,
  EnergyConsumptionEvidenceResponse,
  EnergyConsumptionResponse,
  EnergyTypicalReferenceResponse,
  PowerQualityResponse,
} from "../../api/types";
import {
  planReportDemandRequest,
  planReportEnergyRequest,
  planReportEnergyTypicalReferenceRequest,
  planReportPowerQualityRequest,
  REPORT_PERIOD_LABELS,
} from "../../reports/sitePerformanceReportRanges";
import { reportTitle, type ReportConfig } from "../../reports/sitePerformanceReport";
import { shiftRangeForComparison } from "../../time/ranges";
import { buildComparisonResult, buildTypicalReferenceResult } from "../../energy/comparison";
import { summarizeEnergyEvidence } from "../../energy/evidence";
import { evaluateEnergyAttention } from "../../attention/energyAttention";
import { deriveSiteHealth, siteHealthSummary } from "../../attention/siteHealth";
import { MVP3_MATERIALITY_POLICY } from "../../attention/materiality-policy";
import type { AttentionItem } from "../../attention/types";
import { findPeak } from "../demand/DemandOverview";
import { latestPowerQualityPoint } from "../power-quality/PowerQualityOverview";
import { SiteHealthBanner } from "../../components/SiteHealthBanner";
import { AttentionList } from "../../components/AttentionList";
import { Loading } from "../../components/states/Loading";
import { ErrorState } from "../../components/states/ErrorState";
import { NoDataYet } from "../../components/states/NoDataYet";
import { buildSitePerformanceReportPdf, type SitePerformanceReportPdfData } from "../../reports/pdf";

type SectionStatus = "loading" | "ready" | "error";

type EnergyState = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  current: EnergyConsumptionResponse | null;
  reference: EnergyTypicalReferenceResponse | null;
  /** Previous-Period comparison (Slice A) -- no whole-day-window
   *  restriction, unlike the typical-reference basis above. Used as the
   *  Energy Performance section's display fallback whenever typical-
   *  reference isn't available for this period (ADR-015 gap resolution 6)
   *  -- current value and *a* comparison stay available even when
   *  Attention/Site Health (which require typical-reference specifically,
   *  per ADR-010) cannot be assessed. */
  previousPeriod: EnergyConsumptionResponse | null;
  evidence: EnergyConsumptionEvidenceResponse | null;
  referenceUnsupportedReason: string | null;
};

type DemandState = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  series: DemandSeriesResponse | null;
};

type PowerQualityState = {
  status: SectionStatus;
  error: unknown;
  unsupportedReason: string | null;
  data: PowerQualityResponse | null;
};

const ENERGY_INITIAL: EnergyState = {
  status: "loading",
  error: null,
  unsupportedReason: null,
  current: null,
  reference: null,
  previousPeriod: null,
  evidence: null,
  referenceUnsupportedReason: null,
};
const DEMAND_INITIAL: DemandState = { status: "loading", error: null, unsupportedReason: null, series: null };
const PQ_INITIAL: PowerQualityState = { status: "loading", error: null, unsupportedReason: null, data: null };

/** Formats the Energy Performance value + comparison text, honestly
 *  labeling which basis is actually in effect (ADR-015 gap resolution 6:
 *  typical-reference when available, Previous-Period otherwise). */
function energyValueText(
  displayResult: { currentTotalKwh: number | null; deltaPercent: number | null } | null,
  usingTypical: boolean,
): string {
  const value = `${displayResult?.currentTotalKwh?.toFixed(1) ?? "—"} kWh`;
  if (displayResult?.deltaPercent === null || displayResult?.deltaPercent === undefined) return value;
  const sign = displayResult.deltaPercent >= 0 ? "+" : "";
  const basisLabel = usingTypical ? "vs. typical" : "vs. previous period";
  return `${value} (${sign}${displayResult.deltaPercent.toFixed(1)}% ${basisLabel})`;
}

function periodLabelFor(config: ReportConfig): string {
  const base = REPORT_PERIOD_LABELS[config.period];
  const from = new Date(config.range.from).toLocaleDateString();
  const to = new Date(config.range.to).toLocaleDateString();
  return `${base} (${from} – ${to})`;
}

export function SitePerformanceReportView({
  config,
  onChange,
  onGenerateAnother,
}: {
  config: ReportConfig;
  /** "Change" -- back to configuration, preserving the current selection. */
  onChange: () => void;
  /** "Generate another report" -- back to configuration, reset to defaults. */
  onGenerateAnother: () => void;
}) {
  const [energy, setEnergy] = useState<EnergyState>(ENERGY_INITIAL);
  const [demand, setDemand] = useState<DemandState>(DEMAND_INITIAL);
  const [pq, setPq] = useState<PowerQualityState>(PQ_INITIAL);
  const [nonce, setNonce] = useState(0);
  const [pdfError, setPdfError] = useState<string | null>(null);
  const [pdfGenerating, setPdfGenerating] = useState(false);

  useEffect(() => {
    let active = true;
    setEnergy((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const consumptionPlan = planReportEnergyRequest(config.range);
    if (!consumptionPlan.supported) {
      setEnergy({ ...ENERGY_INITIAL, status: "ready", unsupportedReason: consumptionPlan.reason });
      return;
    }
    const referencePlan = planReportEnergyTypicalReferenceRequest(config.range);
    // Previous-Period (Slice A) has no whole-day-window restriction, unlike
    // typical-reference -- always fetched so the Energy Performance value
    // and a comparison stay available even when typical-reference/Attention
    // cannot be assessed for this period (ADR-015 gap resolution 6).
    const previousPeriodRange = shiftRangeForComparison(consumptionPlan.range, "PREVIOUS_PERIOD");

    const calls: Promise<unknown>[] = [
      getSiteEnergyConsumption(config.siteId, { resolution: consumptionPlan.resolution, ...consumptionPlan.range }),
      getSiteEnergyConsumptionEvidence(config.siteId, {
        resolution: consumptionPlan.resolution,
        ...consumptionPlan.range,
      }),
      getSiteEnergyConsumption(config.siteId, { resolution: consumptionPlan.resolution, ...previousPeriodRange }),
    ];
    if (referencePlan.supported) {
      calls.push(getSiteEnergyTypicalReference(config.siteId, referencePlan.current));
    }

    Promise.all(calls)
      .then((results) => {
        if (!active) return;
        const [current, evidence, previousPeriod, reference] = results as [
          EnergyConsumptionResponse,
          EnergyConsumptionEvidenceResponse,
          EnergyConsumptionResponse,
          EnergyTypicalReferenceResponse | undefined,
        ];
        setEnergy({
          status: "ready",
          error: null,
          unsupportedReason: null,
          current,
          evidence,
          previousPeriod,
          reference: reference ?? null,
          referenceUnsupportedReason: referencePlan.supported ? null : referencePlan.reason,
        });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setEnergy((s) => ({ ...s, status: "error", error: err }));
      });

    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, nonce]);

  useEffect(() => {
    let active = true;
    setDemand((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const plan = planReportDemandRequest(config.range);
    if (!plan.supported) {
      setDemand({ ...DEMAND_INITIAL, status: "ready", unsupportedReason: plan.reason });
      return;
    }
    getSiteDemandSeries(config.siteId, plan.range)
      .then((series) => {
        if (!active) return;
        setDemand({ status: "ready", error: null, unsupportedReason: null, series });
      })
      .catch((err: unknown) => {
        if (!active) return;
        setDemand((s) => ({ ...s, status: "error", error: err }));
      });
    return () => {
      active = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, nonce]);

  useEffect(() => {
    let active = true;
    setPq((s) => ({ ...s, status: "loading", error: null, unsupportedReason: null }));

    const plan = planReportPowerQualityRequest(config.range);
    if (!plan.supported) {
      setPq({ ...PQ_INITIAL, status: "ready", unsupportedReason: plan.reason });
      return;
    }
    getSitePowerQuality(config.siteId, { resolution: plan.resolution, ...plan.range })
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [config, nonce]);

  const comparisonResult =
    energy.current && energy.reference ? buildTypicalReferenceResult(energy.current, energy.reference) : null;
  const previousPeriodResult =
    energy.current && energy.previousPeriod
      ? buildComparisonResult("PREVIOUS_PERIOD", energy.current, energy.previousPeriod)
      : null;
  /** What the Energy Performance section actually displays: the
   *  typical-reference comparison when available, otherwise the
   *  Previous-Period comparison (ADR-015 gap resolution 6) -- Attention/
   *  Site Health below still use `comparisonResult` (typical-reference)
   *  only, never this fallback, per ADR-010's exact rule. */
  const displayResult = comparisonResult ?? previousPeriodResult;
  const evidenceSummary = energy.evidence ? summarizeEnergyEvidence(energy.evidence) : null;

  const attentionItems: AttentionItem[] = useMemo(() => {
    if (!comparisonResult) return [];
    const item = evaluateEnergyAttention({
      result: comparisonResult,
      evidence: evidenceSummary,
      policy: MVP3_MATERIALITY_POLICY.ENERGY_CONSUMPTION,
      siteName: config.siteName,
      window: config.range,
      investigatePath: "/features/energy",
    });
    return item ? [item] : [];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [comparisonResult, evidenceSummary, config.siteName, config.range]);

  const energyAssessable = comparisonResult ? comparisonResult.sufficient && comparisonResult.currentHasData : false;
  const siteHealthState = deriveSiteHealth({ energyAssessable, attentionItems });
  const healthUnavailableReason =
    energy.status === "loading"
      ? null
      : energy.unsupportedReason ||
        energy.referenceUnsupportedReason ||
        (!energyAssessable ? "Not enough valid data to assess Site Health for this period." : null);
  const siteHealthKnown = energy.status === "ready" && !healthUnavailableReason;

  const demandPeak = demand.series ? findPeak(demand.series.series) : null;
  const pqLatest = pq.data ? latestPowerQualityPoint(pq.data.series) : null;

  const periodLabel = periodLabelFor(config);
  const title = reportTitle(config);

  const pdfData: SitePerformanceReportPdfData = useMemo(
    () => ({
      title,
      periodLabel,
      generatedAt: new Date().toLocaleString(),
      siteHealth: siteHealthKnown
        ? { available: true, lines: [siteHealthSummary(siteHealthState, attentionItems.length)] }
        : { available: false, reason: healthUnavailableReason ?? "Site Health is not available for this period." },
      attention: !siteHealthKnown
        ? { available: false, reason: "Attention is not available until Site Health can be assessed." }
        : attentionItems.length === 0
          ? { available: true, lines: ["No active issues for the selected period."] }
          : {
              available: true,
              lines: attentionItems.map((i) => `${i.what} — ${i.where} — ${i.trigger}`),
            },
      energy:
        energy.status !== "ready"
          ? { available: false, reason: "Energy data is not available for this period." }
          : energy.unsupportedReason
            ? { available: false, reason: energy.unsupportedReason }
            : energy.current?.no_data
              ? { available: false, reason: "No energy data for this period." }
              : {
                  available: true,
                  lines: [energyValueText(displayResult, comparisonResult !== null)],
                },
      demand:
        demand.status !== "ready"
          ? { available: false, reason: "Demand data is not available for this period." }
          : demand.unsupportedReason
            ? { available: false, reason: demand.unsupportedReason }
            : demandPeak
              ? { available: true, lines: [`Peak ${demandPeak.kw.toFixed(1)} kW at ${new Date(demandPeak.at).toLocaleString()}`] }
              : { available: false, reason: "No demand data for this period." },
      powerQuality:
        pq.status !== "ready"
          ? { available: false, reason: "Power Quality data is not available for this period." }
          : pq.unsupportedReason
            ? { available: false, reason: pq.unsupportedReason }
            : pqLatest && pqLatest.power_factor_avg !== null
              ? { available: true, lines: [`PF ${pqLatest.power_factor_avg.toFixed(2)}`] }
              : { available: false, reason: "No power quality data for this period." },
      investigation: [`Spaces: /features/spaces`, `Assets: /features/assets`, `${config.contextName}: ${config.investigatePath}`],
    }),
    [
      title,
      periodLabel,
      siteHealthKnown,
      siteHealthState,
      attentionItems,
      healthUnavailableReason,
      energy,
      demand,
      pq,
      comparisonResult,
      displayResult,
      demandPeak,
      pqLatest,
      config,
    ],
  );

  function handleDownloadPdf() {
    setPdfError(null);
    setPdfGenerating(true);
    try {
      const doc = buildSitePerformanceReportPdf(pdfData);
      doc.save(`performance-report-${config.contextName.replace(/\s+/g, "-").toLowerCase()}.pdf`);
    } catch (err) {
      // EMS-REQ-116: a PDF failure never discards the in-app report.
      setPdfError(err instanceof Error ? err.message : "Couldn't generate the PDF. The report above is unaffected.");
    } finally {
      setPdfGenerating(false);
    }
  }

  return (
    <div className="report-view" data-testid="report-view">
      <div className="report-view__header">
        <h2 data-testid="report-title">{title}</h2>
        <p className="hint" data-testid="report-period">
          {periodLabel}
        </p>
      </div>

      {/* 1. Overall Site Health / Status */}
      {siteHealthKnown ? (
        <SiteHealthBanner state={siteHealthState} summary={siteHealthSummary(siteHealthState, attentionItems.length)} />
      ) : energy.status === "loading" ? (
        <Loading label="Assessing site health…" />
      ) : energy.status === "error" ? (
        <ErrorState title="Couldn't assess site health" error={energy.error} onRetry={() => setNonce((n) => n + 1)} />
      ) : (
        <NoDataYet message={healthUnavailableReason ?? "Site health isn't available for this period."} />
      )}

      {/* 2. Attention / Exceptions */}
      <section className="report-attention" data-testid="report-attention">
        <h3>Attention</h3>
        {!siteHealthKnown ? (
          <p className="hint">Attention isn't available until site health can be assessed.</p>
        ) : (
          <AttentionList items={attentionItems} />
        )}
      </section>

      {/* 3. Energy Performance */}
      <section className="report-energy" data-testid="report-energy">
        <h3>Energy Performance</h3>
        {energy.status === "loading" ? <Loading label="Loading energy…" /> : null}
        {energy.status === "error" ? (
          <ErrorState error={energy.error} onRetry={() => setNonce((n) => n + 1)} />
        ) : null}
        {energy.status === "ready" && energy.unsupportedReason ? <NoDataYet message={energy.unsupportedReason} /> : null}
        {energy.status === "ready" && !energy.unsupportedReason ? (
          energy.current?.no_data ? (
            <NoDataYet />
          ) : (
            <p data-testid="report-energy-value">{energyValueText(displayResult, comparisonResult !== null)}</p>
          )
        ) : null}
      </section>

      {/* 4. Maximum Demand */}
      <section className="report-demand" data-testid="report-demand">
        <h3>Maximum Demand</h3>
        {demand.status === "loading" ? <Loading label="Loading demand…" /> : null}
        {demand.status === "error" ? <ErrorState error={demand.error} onRetry={() => setNonce((n) => n + 1)} /> : null}
        {demand.status === "ready" && demand.unsupportedReason ? <NoDataYet message={demand.unsupportedReason} /> : null}
        {demand.status === "ready" && !demand.unsupportedReason ? (
          demandPeak ? (
            <p data-testid="report-demand-value">
              Peak {demandPeak.kw.toFixed(1)} kW at {new Date(demandPeak.at).toLocaleString()}
            </p>
          ) : (
            <NoDataYet />
          )
        ) : null}
      </section>

      {/* 5. Power Quality */}
      <section className="report-power-quality" data-testid="report-power-quality">
        <h3>Power Quality</h3>
        {pq.status === "loading" ? <Loading label="Loading power quality…" /> : null}
        {pq.status === "error" ? <ErrorState error={pq.error} onRetry={() => setNonce((n) => n + 1)} /> : null}
        {pq.status === "ready" && pq.unsupportedReason ? <NoDataYet message={pq.unsupportedReason} /> : null}
        {pq.status === "ready" && !pq.unsupportedReason ? (
          pq.data?.no_data || !pqLatest || pqLatest.power_factor_avg === null ? (
            <NoDataYet />
          ) : (
            <p data-testid="report-pq-value">PF {pqLatest.power_factor_avg.toFixed(2)}</p>
          )
        ) : null}
      </section>

      {/* 6. Investigation paths */}
      <section className="report-investigate" data-testid="report-investigate">
        <h3>Investigate</h3>
        <ul>
          <li>
            <Link to={config.investigatePath}>{config.contextName} →</Link>
          </li>
          <li>
            <Link to="/features/spaces">Spaces →</Link>
          </li>
          <li>
            <Link to="/features/assets">Assets →</Link>
          </li>
        </ul>
      </section>

      <div className="report-view__controls">
        <button type="button" onClick={onChange} data-testid="report-change">
          Change
        </button>
        <button type="button" onClick={onGenerateAnother} data-testid="report-generate-another">
          Generate another report
        </button>
        <button type="button" onClick={handleDownloadPdf} disabled={pdfGenerating} data-testid="report-download-pdf">
          {pdfGenerating ? "Generating PDF…" : "Download PDF"}
        </button>
        {pdfError ? (
          <ErrorState title="Couldn't generate the PDF" error={new Error(pdfError)} onRetry={handleDownloadPdf} />
        ) : null}
      </div>
    </div>
  );
}
