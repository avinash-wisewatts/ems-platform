/**
 * Types mirroring the approved Phase 7 /api/v1 contract EXACTLY.
 *
 * The frontend knows only this semantic contract -- never PostgreSQL,
 * TimescaleDB, Grafana, internal analytics tables, or internal SQL
 * functions. No arbitrary query parameters, no generic query mechanism.
 */

// ---- GET /api/v1/me (Phase 8 additive session echo) -------------------------

export type AccessScopeMode = "GLOBAL" | "ORGANIZATION" | "SELECTED_SITES";
export type RoleCode = "ADMIN" | "OPERATOR" | "VIEWER";

export type CurrentUser = {
  portal_user_id: number;
  username: string;
  display_name: string;
  role_code: RoleCode;
  access_scope_mode: AccessScopeMode;
  organization_id: string | null;
  site_ids: string[];
  permissions: string[];
};

// ---- GET /api/v1/sites -----------------------------------------------------

export type SiteSummary = {
  site_id: string;
  organization_id: string;
  site_code: string;
  site_name: string;
  timezone: string | null;
};

export type SitesResponse = {
  sites: SiteSummary[];
};

// ---- GET /api/v1/spaces/{space_id}/measurements --------------------------

export const MEASUREMENT_PARAMETERS = ["TEMPERATURE", "HUMIDITY", "DEW_POINT"] as const;
export type MeasurementParameter = (typeof MEASUREMENT_PARAMETERS)[number];

export const MEASUREMENT_RESOLUTIONS = ["raw", "1h"] as const;
export type MeasurementResolution = (typeof MEASUREMENT_RESOLUTIONS)[number];

export type MeasurementPoint = {
  bucket_start: string;
  value: number;
  /** Pass-through of the source quality_code. Currently always null for the
   *  first slice (Phase 3 / Phase 6 NULL discipline). Never invent a value. */
  quality: number | null;
  sample_count: number;
};

export type MeasurementSeriesResponse = {
  space_id: string;
  parameter: MeasurementParameter;
  unit: string;
  resolution: MeasurementResolution;
  from: string;
  to: string;
  no_data: boolean;
  series: MeasurementPoint[];
};

// ---- GET /api/v1/sites/{site_id}/spaces (Slice 0: Hierarchy Foundation) --

export type SpaceSummary = {
  space_id: string;
  site_id: string;
  space_code: string;
  space_name: string;
};

export type SpacesResponse = {
  site_id: string;
  spaces: SpaceSummary[];
};

// ---- GET /api/v1/sites/{site_id}/assets (Slice 0: Hierarchy Foundation) --
// Identity + placement only. NO relationship/component-tree fields --
// explicitly deferred; see docs in endpoints.ts.

export type AssetSummary = {
  asset_id: string;
  site_id: string;
  space_id: string | null;
  parent_asset_id: string | null;
  external_id: string;
  asset_name: string;
  lifecycle_status: string;
};

export type AssetsResponse = {
  site_id: string;
  assets: AssetSummary[];
};

// ---- GET /api/v1/sites/{site_id}/energy/consumption --------------------

export const ENERGY_RESOLUTIONS = ["1h", "1d"] as const;
export type EnergyResolution = (typeof ENERGY_RESOLUTIONS)[number];

export type EnergyConsumptionPoint = {
  bucket_start: string;
  import_kwh: number | null;
  export_kwh: number | null;
  source_interval_count: number;
};

export type EnergyConsumptionResponse = {
  site_id: string;
  resolution: EnergyResolution;
  from: string;
  to: string;
  no_data: boolean;
  series: EnergyConsumptionPoint[];
};

// ---- GET /api/v1/sites/{site_id}/energy/consumption/evidence (Slice C) ---
// Additive parallel read of the SAME two historians /energy/consumption
// reads -- exposes coverage/gap/reset/rollover counters that already exist
// there but were never returned by that endpoint. Does NOT change
// /energy/consumption's own response shape.
//
// valid_import_intervals/invalid_import_intervals (and export counterparts)
// are a genuine complementary pair. gap_interval_count/reset_interval_count/
// rollover_interval_count/invalid_interval_count are INDEPENDENT evidence
// counters (traced to analytics.v_energy_semantic_rollup_15min, postgres/
// ddl/147_combined_energy_quality_counters.sql -- NOT the register-delta
// classifier's single quality_code column) -- NOT a mutually-exclusive
// classification, NOT guaranteed to sum to source_interval_count, and
// deliberately NOT the unrelated five-value measurement lattice
// (web/src/components/QualityIndicator.tsx: GOOD/GAP/ESTIMATED/INVALID/
// PARTIAL). See web/src/energy/evidence.ts.

export type EnergyConsumptionEvidencePoint = {
  bucket_start: string;
  source_interval_count: number;
  valid_import_intervals: number;
  invalid_import_intervals: number;
  valid_export_intervals: number;
  invalid_export_intervals: number;
  gap_interval_count: number;
  reset_interval_count: number;
  rollover_interval_count: number;
  invalid_interval_count: number;
  first_source_bucket: string | null;
  last_source_bucket: string | null;
};

export type EnergyConsumptionEvidenceResponse = {
  site_id: string;
  resolution: EnergyResolution;
  from: string;
  to: string;
  no_data: boolean;
  series: EnergyConsumptionEvidencePoint[];
};

// ---- GET /api/v1/sites/{site_id}/energy/consumption/typical-reference ---
// (Slice C -- comparable-period historical reference, per the approved
// Slice C Historical Comparison decision pack.) Additive alongside, NEVER
// a replacement for, /energy/consumption. Always exactly 8 windows,
// regardless of whether each has data. typical_kwh is the median of the
// eligible windows' totals and is null whenever sufficient is false --
// insufficient history is never manufactured into a value. No dependency
// on the evidence endpoint above; reads analytics.energy_consumption_daily
// only (migration 236).

export type EnergyTypicalReferenceWindow = {
  window_index: number;
  from: string;
  to: string;
  has_data: boolean;
  total_kwh: number | null;
  source_interval_count: number;
  valid_import_intervals: number;
  coverage_percent: number | null;
  eligible: boolean;
  gap_interval_count: number;
  reset_interval_count: number;
  rollover_interval_count: number;
  invalid_interval_count: number;
};

export type EnergyTypicalReferenceResponse = {
  site_id: string;
  period_length_days: number;
  from: string;
  to: string;
  typical_kwh: number | null;
  requested_period_count: number;
  windows_with_data_count: number;
  eligible_period_count: number;
  sufficient: boolean;
  windows: EnergyTypicalReferenceWindow[];
};

// ---- GET /api/v1/sites/{site_id}/demand (Slice B) --------------------------
// Reads analytics.demand_intervals only -- native interval grain, no
// resolution parameter (there is no coarser persisted demand tier to pick
// between). quality_status/coverage_percent are real, already-computed
// fields, not invented for the frontend.

export type DemandIntervalPoint = {
  interval_start: string;
  interval_end: string;
  demand_kw: number | null;
  peak_power_kw: number | null;
  quality_status: string;
  coverage_percent: number | null;
};

export type DemandSeriesResponse = {
  site_id: string;
  from: string;
  to: string;
  no_data: boolean;
  series: DemandIntervalPoint[];
};

// ---- GET /api/v1/sites/{site_id}/demand/current (Slice B) ------------------
// Reads analytics.demand_state only -- the live/current-interval table,
// distinct from the finalized historical series above.

export type CurrentDemandResponse = {
  site_id: string;
  has_data: boolean;
  interval_start: string | null;
  interval_end: string | null;
  current_demand_kw: number | null;
  current_demand_kva: number | null;
  quality_status: string | null;
  coverage_percent: number | null;
};

// ---- GET /api/v1/sites/{site_id}/power-quality (Slice B) -------------------
// Resolves the site's SITE_CONSUMPTION-role meter via
// config.site_energy_meter_roles and reads telemetry.ca_energy_15min/
// hourly/daily. THD is per-phase (L1/L2/L3) only -- no total-THD column
// exists in the source aggregates, so none is fabricated here.

export const POWER_QUALITY_RESOLUTIONS = ["15min", "1h", "1d"] as const;
export type PowerQualityResolution = (typeof POWER_QUALITY_RESOLUTIONS)[number];

export type PowerQualityPoint = {
  bucket_start: string;
  power_factor_avg: number | null;
  power_factor_min: number | null;
  power_factor_max: number | null;
  current_thd_l1_avg: number | null;
  current_thd_l1_max: number | null;
  current_thd_l2_avg: number | null;
  current_thd_l2_max: number | null;
  current_thd_l3_avg: number | null;
  current_thd_l3_max: number | null;
};

export type PowerQualityResponse = {
  site_id: string;
  resolution: PowerQualityResolution;
  from: string;
  to: string;
  no_data: boolean;
  series: PowerQualityPoint[];
};

// ---- GET /api/v1/sites/{site_id}/telemetry-freshness (MVP-4) ---------------
// Device connectivity/freshness only -- a signal kept deliberately separate
// from, and never merged into, the measurement-quality lattice
// (web/src/components/QualityIndicator.tsx) or Demand's own quality_status/
// coverage_percent above. state is one of exactly four values; no internal
// device state, device_id, or gateway_id is ever returned. as_of exists on
// the wire but is intentionally not consumed by the frontend in MVP-4 (no
// approved UX decision on timestamp presentation yet).

export type FreshnessState = "FRESH" | "STALE" | "NO_DATA" | "UNKNOWN";

export type DomainFreshness = {
  state: FreshnessState;
  as_of: string | null;
};

export type SiteTelemetryFreshnessResponse = {
  site_id: string;
  energy: DomainFreshness;
  demand: DomainFreshness;
  power_quality: DomainFreshness;
};

// ---- GET /api/v1/sites/{site_id}/alerts, GET /api/v1/alerts/{alert_id} (MVP-7) --
// In-product only, ADR-016/ADR-017. No analytical deep links, no internal
// identifiers (device_id/point_id), no customer-facing severity taxonomy.
// previous_occurrence_count / most_recent_previous_occurrence_at are
// derived server-side at read time -- never fetched separately.

export type AlertState = "ACTIVE" | "RESOLVED" | "ENDED";

export type Alert = {
  alert_id: string;
  site_id: string;
  space_id: string | null;
  asset_id: string | null;
  condition_key: string;
  metric: string;
  state: AlertState;
  triggered_at: string;
  trigger_value: number;
  resolved_at: string | null;
  resolved_value: number | null;
  ended_at: string | null;
  ended_reason: string | null;
  ended_reason_code: "CONFIGURATION_CHANGED" | "DATA_UNAVAILABLE" | null;
  data_unavailable: boolean;
  previous_occurrence_count: number;
  most_recent_previous_occurrence_at: string | null;
};

export type AlertListResponse = {
  site_id: string;
  alerts: Alert[];
};
