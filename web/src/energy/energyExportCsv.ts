/**
 * Q75 Increment 1 -- Energy contextual CSV export (ADR-014). Pure
 * serialization of the exact values EnergyOverview.tsx already computes and
 * displays -- no network, no state, no new calculation. Mirrors the
 * no-network/pure-function discipline of energy/comparison.ts and
 * energy/evidence.ts: this module accepts the same already-built
 * ComparisonResult/TypicalReferenceResult/EnergyEvidenceSummary/
 * SiteTelemetryFreshnessResponse objects the screen already holds, and
 * does not recompute any of comparison, evidence, or freshness logic.
 *
 * ADR-014 decision 1 ("a period's total consumption... not the raw/
 * underlying time-series measurements") is why this exports the single
 * current-period total and its comparison, never EnergyOverview's Trend
 * chart series (current.series) or raw telemetry.
 *
 * Four CSV details are NOT specified by ADR-014 / EMS-REQ-094-099 or any
 * other canonical doc (confirmed by repository search -- no existing CSV
 * export exists anywhere in this codebase to establish a convention). The
 * choices below are IMPLEMENTATION CONVENTIONS, not product decisions --
 * see the accompanying session report for the full rationale. They are
 * deliberately reversible (a serialization detail, not a change to what
 * data Export contains or means):
 *   - Column names/order/row layout: one CSV file per export, one header
 *     row + exactly one data row ("wide" format), covering every field
 *     ADR-014 decisions 2/3/8/10/11 require to be included. No existing
 *     convention resolves this (no prior CSV export exists in this repo).
 *   - Numeric precision: one decimal place for all kWh/percent values,
 *     via `.toFixed(1)` -- this DOES have an existing, citable convention:
 *     EnergyOverview.tsx's own on-screen rendering (`result.currentTotalKwh
 *     ?.toFixed(1)`, etc.) and EnergyEvidencePanel.tsx's
 *     `coveragePercent.toFixed(1)`. Reused verbatim, not invented.
 *   - Filename convention: `<metric-slug>-<site-name-slug>-<from-date>-to-
 *     <to-date>.csv`, mirroring the one existing precedent in this
 *     codebase, SitePerformanceReportView.tsx's
 *     `performance-report-${contextName-slugified}.pdf` (kebab-case
 *     type-then-context naming) -- see downloadEnergyConsumptionExportCsv
 *     in this file.
 *   - Typical-reference per-window evidence notes (the "N of M included
 *     periods had a gap/reset/rollover/invalid interval" text in
 *     EnergyOverview.tsx): included only as the two already-aggregate
 *     counts (eligible/requested period counts), NOT as a per-window
 *     breakdown -- the per-window detail is prose-only on screen today,
 *     never a table, so serializing it as new CSV columns would introduce
 *     a level of detail Export does not currently mirror from the screen.
 */

import type { ComparisonBasis } from "../time/ranges";
import { COMPARISON_BASIS_LABELS } from "../time/ranges";
import type { ComparisonResult, TypicalReferenceResult } from "./comparison";
import type { EnergyEvidenceSummary } from "./evidence";
import type { SiteSummary, SiteTelemetryFreshnessResponse, EnergyConsumptionResponse } from "../api/types";

export type EnergyConsumptionExportInput = {
  site: SiteSummary;
  current: EnergyConsumptionResponse;
  basis: ComparisonBasis;
  result: ComparisonResult;
  /** Non-null only when basis === "TYPICAL_HISTORICAL_REFERENCE". */
  referenceResult: TypicalReferenceResult | null;
  /** Null when the evidence endpoint hasn't returned data for this period
   *  yet -- mirrors EnergyOverview.tsx's own "No evidence available for
   *  this period yet" state; never fabricated. */
  evidence: EnergyEvidenceSummary | null;
  /** Null when the freshness fetch failed or hasn't completed -- mirrors
   *  FreshnessIndicator's own handling of an absent state. */
  freshness: SiteTelemetryFreshnessResponse | null;
};

const CSV_COLUMNS = [
  "site_id",
  "site_name",
  "site_code",
  "metric",
  "unit",
  "resolution",
  "period_from",
  "period_to",
  "current_value_kwh",
  "current_has_data",
  "comparison_basis",
  "comparison_basis_label",
  "comparison_value_kwh",
  "comparison_has_data",
  "delta_kwh",
  "delta_percent",
  "typical_reference_eligible_periods",
  "typical_reference_requested_periods",
  "typical_reference_sufficient",
  "evidence_has_data",
  "evidence_total_intervals",
  "evidence_valid_import_intervals",
  "evidence_invalid_import_intervals",
  "evidence_valid_export_intervals",
  "evidence_invalid_export_intervals",
  "evidence_gap_interval_count",
  "evidence_reset_interval_count",
  "evidence_rollover_interval_count",
  "evidence_invalid_interval_count",
  "evidence_coverage_percent",
  "evidence_first_source_bucket",
  "evidence_last_source_bucket",
  "freshness_state",
  "freshness_as_of",
] as const;

/** RFC4180-style CSV field escaping: quote and double-escape any field
 *  containing a comma, double quote, or line break. Null/undefined
 *  serialize to an empty field -- ADR-014 decision 11 ("never a
 *  fabricated number"): an empty cell, not "null"/"N/A"/0. */
export function csvField(value: string | number | boolean | null | undefined): string {
  if (value === null || value === undefined) return "";
  const raw = typeof value === "string" ? value : String(value);
  if (raw.includes(",") || raw.includes('"') || raw.includes("\n") || raw.includes("\r")) {
    return `"${raw.replace(/"/g, '""')}"`;
  }
  return raw;
}

function fixed1(value: number | null | undefined): string | null {
  return value === null || value === undefined ? null : value.toFixed(1);
}

/** Pure CSV construction -- no network, no DOM, no side effects. See this
 *  file's header comment for the four implementation conventions applied
 *  here that ADR-014 does not itself specify. */
export function buildEnergyConsumptionExportCsv(input: EnergyConsumptionExportInput): string {
  const { site, current, basis, result, referenceResult, evidence, freshness } = input;

  const row: Record<(typeof CSV_COLUMNS)[number], string | number | boolean | null> = {
    site_id: site.site_id,
    site_name: site.site_name,
    site_code: site.site_code,
    metric: "Energy Consumption",
    unit: "kWh",
    resolution: current.resolution,
    period_from: current.from,
    period_to: current.to,
    current_value_kwh: current.no_data ? null : fixed1(result.currentTotalKwh),
    current_has_data: result.currentHasData,
    comparison_basis: basis,
    comparison_basis_label: COMPARISON_BASIS_LABELS[basis],
    comparison_value_kwh: fixed1(result.comparisonTotalKwh),
    comparison_has_data: result.comparisonHasData,
    delta_kwh: fixed1(result.deltaKwh),
    delta_percent: fixed1(result.deltaPercent),
    typical_reference_eligible_periods: referenceResult?.eligiblePeriodCount ?? null,
    typical_reference_requested_periods: referenceResult?.requestedPeriodCount ?? null,
    typical_reference_sufficient: referenceResult?.sufficient ?? null,
    evidence_has_data: evidence?.hasData ?? null,
    evidence_total_intervals: evidence?.totalIntervals ?? null,
    evidence_valid_import_intervals: evidence?.validImportIntervals ?? null,
    evidence_invalid_import_intervals: evidence?.invalidImportIntervals ?? null,
    evidence_valid_export_intervals: evidence?.validExportIntervals ?? null,
    evidence_invalid_export_intervals: evidence?.invalidExportIntervals ?? null,
    evidence_gap_interval_count: evidence?.gapIntervalCount ?? null,
    evidence_reset_interval_count: evidence?.resetIntervalCount ?? null,
    evidence_rollover_interval_count: evidence?.rolloverIntervalCount ?? null,
    evidence_invalid_interval_count: evidence?.invalidIntervalCount ?? null,
    evidence_coverage_percent: evidence ? fixed1(evidence.coveragePercent) : null,
    evidence_first_source_bucket: evidence?.firstSourceBucket ?? null,
    evidence_last_source_bucket: evidence?.lastSourceBucket ?? null,
    freshness_state: freshness?.energy.state ?? null,
    freshness_as_of: freshness?.energy.as_of ?? null,
  };

  const header = CSV_COLUMNS.map(csvField).join(",");
  const dataRow = CSV_COLUMNS.map((col) => csvField(row[col])).join(",");
  return `${header}\r\n${dataRow}\r\n`;
}

/** Slugifies for a filesystem-safe, space-free filename segment. Mirrors
 *  SitePerformanceReportView.tsx's existing `.replace(/\s+/g, "-").
 *  toLowerCase()` precedent (the only prior filename-building code in
 *  this codebase). */
function slug(value: string): string {
  return value.trim().replace(/\s+/g, "-").toLowerCase();
}

/** Filename convention: `<metric-slug>-<site-name-slug>-<from-date>-to-
 *  <to-date>.csv`, dates taken as the date-only (YYYY-MM-DD) portion of
 *  the ISO period bounds. Implementation convention -- see file header. */
export function energyConsumptionExportFilename(input: Pick<EnergyConsumptionExportInput, "site" | "current">): string {
  const fromDate = input.current.from.slice(0, 10);
  const toDate = input.current.to.slice(0, 10);
  return `energy-consumption-${slug(input.site.site_name)}-${fromDate}-to-${toDate}.csv`;
}
