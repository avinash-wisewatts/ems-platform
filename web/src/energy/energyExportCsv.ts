/**
 * Q75 -- Energy contextual CSV export (ADR-014, amended 2026-09-15).
 * Pure serialization of the exact values EnergyOverview.tsx already
 * computes and displays -- no network, no state, no new calculation.
 * Mirrors the no-network/pure-function discipline of energy/comparison.ts
 * and energy/evidence.ts: this module accepts the same already-built
 * ComparisonResult/TypicalReferenceResult/EnergyEvidenceSummary/
 * SiteTelemetryFreshnessResponse objects the screen already holds, and
 * does not recompute any of comparison, evidence, or freshness logic.
 *
 * 2026-09-15 correction (Product Owner decision, see ADR-014's dated
 * amendment and requirements-traceability.md §12): the export now
 * contains one CSV row per Energy chart point (current.series --
 * bucket_start/import_kwh, at the response-level resolution), in the
 * same order the chart itself renders them, in place of the original
 * single period-summary row. This is NOT the raw/underlying telemetry
 * ADR-014 decision 1 still excludes -- it is exactly the chart's own
 * already-aggregated, already-displayed series, per the amendment.
 * Comparison remains summary/contextual only (ADR-014 decision 8): the
 * comparison period's own series is never displayed on the chart, so it
 * is never exported point-by-point, only as the same total/delta/basis
 * already shown on screen, repeated as context on every row.
 *
 * export_kwh, source_interval_count, and per-point evidence/quality are
 * deliberately NOT included -- explicitly out of scope/undecided per the
 * 2026-09-15 decision (see ADR-014's amendment); do not add them without
 * a separate product decision.
 *
 * Row-shape implementation conventions (not specified by ADR-014 /
 * EMS-REQ-094-099 -- no prior CSV export existed anywhere in this
 * codebase before Q75): every context column (site/hierarchy, metric,
 * unit, resolution, selected period, comparison, aggregate evidence,
 * freshness) repeats identically on every data row, per the explicit
 * Product Owner instruction that context accompany every exported point.
 * Numeric precision (`.toFixed(1)`) and the filename convention are
 * unchanged from the original increment -- see energyConsumptionExportFilename
 * below and EnergyOverview.tsx's/EnergyEvidencePanel.tsx's own on-screen
 * `.toFixed(1)` rendering.
 *
 * Whole-period no-data representation: when current.no_data is true (or
 * defensively, when current.series is empty despite that flag), the
 * export emits the header plus exactly one row with an empty
 * chart_timestamp, an empty energy_consumption_kwh (never a fabricated
 * value, per ADR-014 decision 11), and period_has_data=false -- the same
 * established has-data signal (result.currentHasData) EnergyOverview.tsx
 * already exposes, not a new customer-facing quality label. No free-text
 * "no data" message is invented here; the existing NoDataYet component's
 * "No data for the selected range." wording remains the on-screen
 * equivalent and is not duplicated into the CSV as a new column.
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
  "period_has_data",
  "chart_timestamp",
  "energy_consumption_kwh",
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

type CsvRow = Record<(typeof CSV_COLUMNS)[number], string | number | boolean | null>;

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

function formatRow(row: CsvRow): string {
  return CSV_COLUMNS.map((col) => csvField(row[col])).join(",");
}

/** Pure CSV construction -- no network, no DOM, no side effects. One row
 *  per Energy chart point (current.series, in chart order), or exactly
 *  one explicit no-data row when the period has no usable series. See
 *  this file's header comment for the full rationale. */
export function buildEnergyConsumptionExportCsv(input: EnergyConsumptionExportInput): string {
  const { site, current, basis, result, referenceResult, evidence, freshness } = input;

  // evidence.hasData === false (whether evidence is null, or a non-null
  // EMPTY_SUMMARY from evidence.ts) means the numeric counters are not
  // real coverage/gap/reset/rollover data -- EnergyEvidencePanel.tsx fully
  // suppresses them on screen in this state ("No evidence available for
  // this period yet"). Mirror that here: empty cells, never a literal 0,
  // for every evidence_* field except evidence_has_data itself, which
  // still carries the false signal so the CSV communicates the state.
  const evidenceNumbers = evidence?.hasData ? evidence : null;

  // Context repeated identically on every row, per the explicit Product
  // Owner instruction ("Each row repeats the relevant export context").
  const context: Omit<CsvRow, "chart_timestamp" | "energy_consumption_kwh"> = {
    site_id: site.site_id,
    site_name: site.site_name,
    site_code: site.site_code,
    metric: "Energy Consumption",
    unit: "kWh",
    resolution: current.resolution,
    period_from: current.from,
    period_to: current.to,
    period_has_data: result.currentHasData,
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
    evidence_total_intervals: evidenceNumbers?.totalIntervals ?? null,
    evidence_valid_import_intervals: evidenceNumbers?.validImportIntervals ?? null,
    evidence_invalid_import_intervals: evidenceNumbers?.invalidImportIntervals ?? null,
    evidence_valid_export_intervals: evidenceNumbers?.validExportIntervals ?? null,
    evidence_invalid_export_intervals: evidenceNumbers?.invalidExportIntervals ?? null,
    evidence_gap_interval_count: evidenceNumbers?.gapIntervalCount ?? null,
    evidence_reset_interval_count: evidenceNumbers?.resetIntervalCount ?? null,
    evidence_rollover_interval_count: evidenceNumbers?.rolloverIntervalCount ?? null,
    evidence_invalid_interval_count: evidenceNumbers?.invalidIntervalCount ?? null,
    evidence_coverage_percent: fixed1(evidenceNumbers?.coveragePercent),
    evidence_first_source_bucket: evidenceNumbers?.firstSourceBucket ?? null,
    evidence_last_source_bucket: evidenceNumbers?.lastSourceBucket ?? null,
    freshness_state: freshness?.energy.state ?? null,
    freshness_as_of: freshness?.energy.as_of ?? null,
  };

  const header = CSV_COLUMNS.map(csvField).join(",");

  // Whole-period no-data: current.no_data is the API's own contract for
  // this (see NoDataYet.tsx's doc comment -- HTTP 200, no_data: true,
  // series: []); series.length === 0 is checked too, defensively, in case
  // that invariant is ever violated -- never silently emit zero rows.
  const hasNoUsableSeries = current.no_data || current.series.length === 0;

  const dataRows: string[] = hasNoUsableSeries
    ? [formatRow({ ...context, chart_timestamp: null, energy_consumption_kwh: null })]
    : current.series.map((point) =>
        formatRow({
          ...context,
          chart_timestamp: point.bucket_start,
          energy_consumption_kwh: fixed1(point.import_kwh),
        }),
      );

  return `${header}\r\n${dataRows.map((row) => `${row}\r\n`).join("")}`;
}

/** Slugifies for a filesystem-safe, space-free filename segment. Mirrors
 *  SitePerformanceReportView.tsx's existing `.replace(/\s+/g, "-").
 *  toLowerCase()` precedent (the only prior filename-building code in
 *  this codebase). Unchanged from the original increment. */
function slug(value: string): string {
  return value.trim().replace(/\s+/g, "-").toLowerCase();
}

/** Filename convention: `<metric-slug>-<site-name-slug>-<from-date>-to-
 *  <to-date>.csv`, dates taken as the date-only (YYYY-MM-DD) portion of
 *  the ISO period bounds. Unchanged from the original increment --
 *  implementation convention, not a product decision. */
export function energyConsumptionExportFilename(input: Pick<EnergyConsumptionExportInput, "site" | "current">): string {
  const fromDate = input.current.from.slice(0, 10);
  const toDate = input.current.to.slice(0, 10);
  return `energy-consumption-${slug(input.site.site_name)}-${fromDate}-to-${toDate}.csv`;
}
