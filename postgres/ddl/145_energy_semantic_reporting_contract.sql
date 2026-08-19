-- ============================================================================
-- Migration 033
-- Tenant-aware semantic energy reporting contract
--
-- Purpose:
--   Expose the validated semantic rollups through stable tenant-aware
--   reporting views while preserving their richer quality information.
--
-- This migration DOES NOT replace any existing public compatibility view.
-- Grafana, EMS application and readonly consumers remain on their current
-- paths until equivalence and performance validation has completed.
-- ============================================================================


-- ============================================================================
-- 1. FIVE-MINUTE SEMANTIC REPORTING CONTRACT
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_reporting_5min
WITH (security_barrier = true)
AS

SELECT
    gom.grafana_org_id,

    r.organization_id,
    r.site_id,
    r.device_id,

    d.external_id,
    d.name AS device_name,

    r.bucket_start,

    r.source_interval_count,
    r.source_sample_count,

    r.valid_import_intervals,
    r.invalid_import_intervals,
    r.valid_export_intervals,
    r.invalid_export_intervals,

    r.import_gap_intervals,
    r.export_gap_intervals,

    r.import_reset_intervals,
    r.export_reset_intervals,

    r.import_rollover_intervals,
    r.export_rollover_intervals,

    r.import_consumption_wh,
    r.import_consumption_kwh,

    r.export_consumption_wh,
    r.export_consumption_kwh,

    r.first_native_bucket_start,
    r.last_native_bucket_start,
    r.first_previous_bucket_start,

    r.previous_import_register_wh,
    r.import_register_wh,

    r.previous_export_register_wh,
    r.export_register_wh,

    r.import_quality_codes,
    r.export_quality_codes,

    r.minimum_native_resolution_seconds,
    r.maximum_native_resolution_seconds,

    r.quality_status

FROM analytics.v_energy_semantic_rollup_5min r

JOIN metadata.devices d
  ON d.id = r.device_id
 AND d.organization_id = r.organization_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = r.organization_id
 AND gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_reporting_5min IS
'Tenant-aware five-minute semantic energy reporting contract derived exclusively from persisted native validated consumption. Preserves valid energy and explicit child quality counts without reclassifying cumulative registers.';


-- ============================================================================
-- 2. FIFTEEN-MINUTE SEMANTIC REPORTING CONTRACT
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_reporting_15min
WITH (security_barrier = true)
AS

SELECT
    gom.grafana_org_id,

    r.organization_id,
    r.site_id,
    r.device_id,

    d.external_id,
    d.name AS device_name,

    r.bucket_start,

    r.source_interval_count,
    r.source_sample_count,

    r.valid_import_intervals,
    r.invalid_import_intervals,
    r.valid_export_intervals,
    r.invalid_export_intervals,

    r.import_gap_intervals,
    r.export_gap_intervals,

    r.import_reset_intervals,
    r.export_reset_intervals,

    r.import_rollover_intervals,
    r.export_rollover_intervals,

    r.import_consumption_wh,
    r.import_consumption_kwh,

    r.export_consumption_wh,
    r.export_consumption_kwh,

    r.first_native_bucket_start,
    r.last_native_bucket_start,
    r.first_previous_bucket_start,

    r.previous_import_register_wh,
    r.import_register_wh,

    r.previous_export_register_wh,
    r.export_register_wh,

    r.import_quality_codes,
    r.export_quality_codes,

    r.minimum_native_resolution_seconds,
    r.maximum_native_resolution_seconds,

    r.quality_status

FROM analytics.v_energy_semantic_rollup_15min r

JOIN metadata.devices d
  ON d.id = r.device_id
 AND d.organization_id = r.organization_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = r.organization_id
 AND gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_energy_reporting_15min IS
'Tenant-aware fifteen-minute semantic energy reporting contract derived exclusively from persisted native validated consumption. Preserves valid energy and explicit child quality counts without coarse-register reclassification.';


-- ============================================================================
-- 3. SECURITY BOUNDARY
-- ============================================================================

ALTER VIEW analytics.v_energy_reporting_5min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_reporting_15min
OWNER TO ems_admin;


REVOKE ALL
ON analytics.v_energy_reporting_5min
FROM PUBLIC;

REVOKE ALL
ON analytics.v_energy_reporting_15min
FROM PUBLIC;


-- Validation-only reporting contract for now.
-- Consumer grants are deliberately deferred until equivalence validation.

GRANT SELECT
ON analytics.v_energy_reporting_5min
TO ems_admin;

GRANT SELECT
ON analytics.v_energy_reporting_15min
TO ems_admin;

