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
