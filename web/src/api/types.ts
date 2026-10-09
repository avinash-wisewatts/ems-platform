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
  organization_name: string;
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
// Identity + placement, PLUS type/hierarchy/location (Asset View) --
// sourced from the existing, already-portal-scoped
// admin.list_accessible_assets; no asset_relationships / component-tree
// read (still explicitly deferred; see docs in endpoints.ts).

export type AssetSummary = {
  asset_id: string;
  site_id: string;
  space_id: string | null;
  parent_asset_id: string | null;
  external_id: string;
  asset_name: string;
  lifecycle_status: string;
  asset_type_id: string | null;
  asset_type_name: string | null;
  parent_asset_name: string | null;
  building_id: string | null;
  building_name: string | null;
  floor_id: string | null;
  floor_name: string | null;
  space_name: string | null;
  location_path: string | null;
};

export type AssetsResponse = {
  site_id: string;
  assets: AssetSummary[];
};

// ---- GET /api/v1/sites/{site_id}/assets/{asset_id}/live-state --
// Always a "right now" read -- one row per (device, logical_point)
// currently attached to the asset. No historical series. Paired with the
// portal-session live WebSocket that keeps it current after the initial
// fetch (see routes/assetView/useAssetLiveSocket.ts) -- this same shape
// (asset_id + points[]) is also what that socket's "snapshot"/"telemetry"
// messages carry.

export type AssetLivePoint = {
  device_id: string;
  device_name: string;
  relationship_type: string;
  logical_point: string;
  unit_symbol: string | null;
  numeric_value: number | null;
  text_value: string | null;
  event_time: string | null;
  received_at: string | null;
  freshness_state: string;
  quality_code: string | null;
};

export type AssetLiveStateResponse = {
  asset_id: string;
  points: AssetLivePoint[];
};

// ---- GET /api/v1/sites/{site_id}/assets/{asset_id}/energy/consumption (Asset View, migration 244) --
// Raw interval rows -- period-total summation and previous-window
// comparison are computed client-side (routes/assetView/assetEnergy.ts),
// the same as site energy consumption already is.

export type AssetEnergyIntervalPoint = {
  interval_start: string;
  device_id: string;
  device_name: string;
  elapsed_minutes: number;
  import_consumption_kwh: number | null;
  export_consumption_kwh: number | null;
  import_quality_code: string | null;
  export_quality_code: string | null;
  reset_detected: boolean;
  gap_detected: boolean;
};

export type AssetEnergyIntervalsResponse = {
  asset_id: string;
  from: string;
  to: string;
  no_data: boolean;
  series: AssetEnergyIntervalPoint[];
};

// ---- GET /api/v1/sites/{site_id}/energy/consumption --------------------

// "1w"/"1mo"/"1y" (migration 248) are NOT a separate persisted tier -- they
// are server-side date_trunc aggregations of the SAME "1d" historian
// (analytics.energy_consumption_daily), returned in the exact same
// EnergyConsumptionPoint shape as "1h"/"1d". See energyUsage.ts's module
// docstring for why the Main Dashboard Energy Usage chart's Weekly/Monthly/
// Yearly resolutions are sourced this way rather than by aggregating raw
// daily rows client-side.
export const ENERGY_RESOLUTIONS = ["1h", "1d", "1w", "1mo", "1y"] as const;
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

// ---- GET /api/v1/sites/{site_id}/energy/consumption/availability
// (migration 247) -- the site's ACTUAL persisted energy-consumption data
// availability (earliest/latest across BOTH energy_consumption_daily and
// energy_consumption_hourly), deliberately independent of
// ENERGY_MAX_WINDOW_S's per-request query-window caps. has_data is false,
// and earliest/latest are both null, when the site has no energy data at
// all -- never a fabricated date.

export type SiteEnergyAvailabilityResponse = {
  site_id: string;
  has_data: boolean;
  earliest: string | null;
  latest: string | null;
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

// ---- GET /api/v1/sites/{site_id}/assets/{asset_id}/demand (Asset View,
// migration 245) -- mirrors GET /sites/{site_id}/demand exactly, scoped to
// the asset. Same source table (analytics.demand_intervals, scope_type=
// 'ASSET'), same quality_status vocabulary, so the series reuses
// DemandIntervalPoint rather than a duplicate type. No resolution
// parameter, no maximum query-window (migration 246 batch removed the
// artificial 31-day cap from both Site and Asset Demand).

export type AssetDemandSeriesResponse = {
  asset_id: string;
  from: string;
  to: string;
  no_data: boolean;
  series: DemandIntervalPoint[];
};

// ---- GET /api/v1/sites/{site_id}/assets/{asset_id}/demand/current (Asset
// View, migration 245) -- mirrors GET /sites/{site_id}/demand/current,
// reading analytics.demand_state (scope_type='ASSET').

export type AssetCurrentDemandResponse = {
  asset_id: string;
  has_data: boolean;
  interval_start: string | null;
  interval_end: string | null;
  current_demand_kw: number | null;
  current_demand_kva: number | null;
  quality_status: string | null;
  coverage_percent: number | null;
};

// ---- GET /api/v1/sites/{site_id}/assets/{asset_id}/power-trend (Asset
// View, migration 246) -- raw instantaneous active-power samples from the
// asset's PRIMARY_METER device, read directly from telemetry.energy_
// measurements (no Grafana envelope). sample_time, not interval_start/end:
// this is a point sample series, not an aggregated interval. quality_code
// is deliberately not returned by the API -- it has no established
// customer-facing translation anywhere in the platform (unlike Demand's
// own quality_status) -- so only is_estimated (a plain boolean) is
// available as the data-state signal. No resolution parameter, no maximum
// query-window.

export type AssetPowerTrendPoint = {
  sample_time: string;
  active_power_kw: number | null;
  is_estimated: boolean;
};

export type AssetPowerTrendResponse = {
  asset_id: string;
  from: string;
  to: string;
  no_data: boolean;
  series: AssetPowerTrendPoint[];
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
// device state, device_id, or gateway_id is ever returned. as_of has existed
// on the wire since MVP-4 but was intentionally not consumed by the frontend
// then (no approved UX decision on timestamp presentation yet). The
// WiseWatts Main Dashboard's "Last data update" line is the first consumer
// -- the most recent non-null as_of across energy/demand/power_quality, per
// explicit product direction for that screen (routes/dashboard/
// MainDashboard.tsx). No other screen reads it.

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

// ---- Analytics v1 (ADR-022) -------------------------------------------------
// GET /api/v1/sites/{site_id}/analytics/catalog and .../analytics/series --
// docs/07-features/analytics/README.md "API contract", matching the backend
// models in app/src/analytics_trends_service.py field for field. All
// timestamps are UTC ISO-8601 strings; site-local presentation is the
// frontend's job (ADR-019).

/** Registry data-point codes (B3): ENERGY_IMPORT ("Energy"), ENERGY_EXPORT
 *  ("Energy Export"), ACTIVE_POWER ("Power"), REACTIVE_POWER, CURRENT,
 *  VOLTAGE_LINE_NEUTRAL ("Voltage"), VOLTAGE_LINE_LINE, POWER_FACTOR and
 *  FREQUENCY; the registry can grow, so any code the catalogue returns is
 *  accepted. */
export type AnalyticsDataPointCode = "ENERGY_IMPORT" | "ENERGY_EXPORT" | (string & {});

export type AnalyticsResolutionCode = "1m" | "15m" | "30m" | "1h" | "1d";
/** `auto` lets the server choose (ADR-019 rule, floor-aware). */
export type AnalyticsRequestedResolution = "auto" | AnalyticsResolutionCode;
export type AnalyticsPhase = "system" | "three_phase";

export type AnalyticsLimits = {
  max_data_points: number;
  max_assets: number;
  max_series: number;
};

export type AnalyticsResolution = {
  resolution: AnalyticsResolutionCode;
  max_window_seconds: number;
  default_window_seconds: number;
  /** This resolution's retention floor for the site; null = no floor. */
  available_from: string | null;
};

export type AnalyticsDataPoint = {
  data_point: AnalyticsDataPointCode;
  label: string;
  category: string | null;
  unit: string | null;
  chart_kind: "bar" | "line";
  aggregation: "sum" | "mean";
  phases: { system: boolean; three_phase: boolean };
  /** Data bounds for this asset and data point; null = no data yet. */
  available_from: string | null;
  available_to: string | null;
  /** When the data point is assigned to the asset -- current, closed and
   *  future assignments, in time order (migration 288). Data outside every
   *  period is NOT_ASSIGNED. */
  assignment_periods: AnalyticsAssignmentPeriod[];
};

/** [assigned_from, assigned_to); null = unbounded at that end. */
export type AnalyticsAssignmentPeriod = {
  assigned_from: string | null;
  assigned_to: string | null;
};

export type AnalyticsCatalogAsset = {
  asset_id: string;
  asset_name: string;
  asset_type_id: string | null;
  asset_type_name: string | null;
  building_name: string | null;
  floor_name: string | null;
  space_id: string | null;
  space_name: string | null;
  location_path: string | null;
  data_points: AnalyticsDataPoint[];
};

export type AnalyticsCatalogResponse = {
  site_id: string;
  site_name: string;
  site_timezone: string | null;
  limits: AnalyticsLimits;
  resolutions: AnalyticsResolution[];
  /** ACTIVE assets with at least one registry data point only. */
  assets: AnalyticsCatalogAsset[];
};

/** Series status (migration 282). Only OK series are charted. */
export type AnalyticsSeriesStatus =
  | "OK"
  | "NO_DATA"
  | "NOT_AVAILABLE"
  | "RESOLUTION_UNAVAILABLE"
  | "DATA_UNAVAILABLE";

/** status_reasons values. NO_DATA carries exactly one (first match);
 *  RESOLUTION_UNAVAILABLE one; DATA_UNAVAILABLE all that apply;
 *  NOT_AVAILABLE and OK none. */
export type AnalyticsStatusReason =
  | "NOT_ASSIGNED_IN_RANGE"
  | "NO_DATA_EVER"
  | "RANGE_IN_FUTURE"
  | "RANGE_BEFORE_DATA"
  | "RANGE_AFTER_LATEST_DATA"
  | "NO_DATA_IN_RANGE"
  | "BEFORE_RETENTION_FLOOR"
  | "CAPTURE_INTERVAL_TOO_COARSE"
  | "CAPTURE_POLICY_CHANGE"
  | "CAPTURE_POLICY_GAP"
  | "TIMEZONE_MISMATCH";

export type AnalyticsBucketState = "COMPLETE" | "IN_PROGRESS" | "FUTURE";
export type AnalyticsDataState =
  | "MEASURED"
  | "GAP"
  | "NOT_ASSIGNED"
  | "BEFORE_DATA"
  | "AFTER_LATEST_DATA"
  | "FUTURE";
/** Every evidence condition present in a bucket (Energy). */
export type AnalyticsEvidenceFlag =
  | "INVALID_INTERVALS"
  | "RESET_DETECTED"
  | "GAPS_DETECTED"
  | "RECONSTRUCTED_TIMING"
  | "ROLLOVER_DETECTED";

export type AnalyticsSeriesPoint = {
  bucket_start: string;
  bucket_end: string;
  /** null = no value in this bucket (every grid bucket is returned). */
  value: number | null;
  /** Non-Energy only; null for Energy (a bucket is a sum). */
  min: number | null;
  max: number | null;
  bucket_state: AnalyticsBucketState;
  data_state: AnalyticsDataState | null;
  expected_intervals: number | null;
  assigned_expected_intervals: number | null;
  valid_intervals: number;
  invalid_intervals: number;
  reconstructed_intervals: number;
  evidence_flags: AnalyticsEvidenceFlag[];
  /** Compatibility: the most severe Energy evidence status; null for an empty bucket. */
  evidence_status: string | null;
  /** Non-Energy only: the GOOD/GAP/ESTIMATED/INVALID/PARTIAL lattice. */
  quality: "GOOD" | "GAP" | "ESTIMATED" | "INVALID" | "PARTIAL" | null;
  /** Compatibility: bucket_state !== "COMPLETE". */
  is_partial: boolean;
};

export type AnalyticsSeriesSummary = {
  /** Energy only. */
  total: number | null;
  average: number | null;
  min: number | null;
  min_at: string | null;
  max: number | null;
  max_at: string | null;
};

export type AnalyticsSeries = {
  asset_id: string;
  /** null for NOT_AVAILABLE series (the catalogue could not serve them). */
  asset_name: string | null;
  data_point: AnalyticsDataPointCode;
  label: string | null;
  /** "TOTAL" = System; "L1"/"L2"/"L3" per phase ("L12"/"L23"/"L31" for
   *  line-to-line voltage). Never shown to customers (D83). */
  qualifier: string;
  unit: string | null;
  chart_kind: "bar" | "line";
  aggregation: "sum" | "mean";
  status: AnalyticsSeriesStatus;
  status_reasons: AnalyticsStatusReason[];
  /** Set for RESOLUTION_UNAVAILABLE / BEFORE_RETENTION_FLOOR. */
  resolution_available_from: string | null;
  first_data_at: string | null;
  last_data_at: string | null;
  /** Data latency (business rule 12); null where the capture path is unverified. */
  stale: boolean | null;
  /** Empty for NOT_AVAILABLE / RESOLUTION_UNAVAILABLE / DATA_UNAVAILABLE. */
  points: AnalyticsSeriesPoint[];
  summary: AnalyticsSeriesSummary;
};

export type AnalyticsSeriesResponse = {
  site_id: string;
  site_timezone: string | null;
  /** The one database clock read every value in the response is evaluated at. */
  as_of: string;
  from: string;
  to: string;
  requested_resolution: AnalyticsRequestedResolution;
  /** The resolution actually served (Auto resolved, floor-aware). */
  resolution: AnalyticsResolutionCode;
  phase: AnalyticsPhase;
  /** One series per selection, in request order. */
  series: AnalyticsSeries[];
};
