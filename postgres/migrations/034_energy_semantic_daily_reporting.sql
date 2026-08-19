-- ============================================================================
-- Migration 034
-- Site-timezone-aware semantic daily energy reporting
--
-- Purpose:
--   Aggregate the validated fifteen-minute semantic reporting contract into
--   daily device-level energy reporting using each site's configured timezone.
--
-- IMPORTANT:
--   This migration does NOT replace analytics.v_energy_consumption_daily.
--   It introduces a shadow semantic daily contract for validation first.
--
--   Energy is never reclassified here. Only already-validated semantic energy
--   and child quality counts are aggregated.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_energy_reporting_daily
WITH (security_barrier = true)
AS

WITH daily AS
(
    SELECT
        r.grafana_org_id,
        r.organization_id,
        r.site_id,
        r.device_id,

        r.external_id,
        r.device_name,

        s.timezone AS site_timezone,

        (
            r.bucket_start
            AT TIME ZONE s.timezone
        )::date AS consumption_date,

        sum(r.source_interval_count)
            AS source_interval_count,

        sum(r.source_sample_count)
            AS source_sample_count,

        sum(r.valid_import_intervals)
            AS valid_import_intervals,

        sum(r.invalid_import_intervals)
            AS invalid_import_intervals,

        sum(r.valid_export_intervals)
            AS valid_export_intervals,

        sum(r.invalid_export_intervals)
            AS invalid_export_intervals,

        sum(r.import_gap_intervals)
            AS import_gap_intervals,

        sum(r.export_gap_intervals)
            AS export_gap_intervals,

        sum(r.import_reset_intervals)
            AS import_reset_intervals,

        sum(r.export_reset_intervals)
            AS export_reset_intervals,

        sum(r.import_rollover_intervals)
            AS import_rollover_intervals,

        sum(r.export_rollover_intervals)
            AS export_rollover_intervals,

        sum(r.import_consumption_wh)
            AS import_consumption_wh,

        sum(r.import_consumption_kwh)
            AS import_consumption_kwh,

        sum(r.export_consumption_wh)
            AS export_consumption_wh,

        sum(r.export_consumption_kwh)
            AS export_consumption_kwh,

        min(r.first_native_bucket_start)
            AS first_native_bucket_start,

        max(r.last_native_bucket_start)
            AS last_native_bucket_start,

        min(r.minimum_native_resolution_seconds)
            AS minimum_native_resolution_seconds,

        max(r.maximum_native_resolution_seconds)
            AS maximum_native_resolution_seconds

    FROM analytics.v_energy_reporting_15min r

    JOIN metadata.sites s
      ON s.id = r.site_id
     AND s.organization_id = r.organization_id

    GROUP BY
        r.grafana_org_id,
        r.organization_id,
        r.site_id,
        r.device_id,
        r.external_id,
        r.device_name,
        s.timezone,
        (
            r.bucket_start
            AT TIME ZONE s.timezone
        )::date
)

SELECT
    d.*,

    CASE
        WHEN
            d.invalid_import_intervals > 0
            OR d.invalid_export_intervals > 0
            THEN 'INVALID_INTERVALS'

        WHEN
            d.import_reset_intervals > 0
            OR d.export_reset_intervals > 0
            THEN 'RESET_DETECTED'

        WHEN
            d.import_gap_intervals > 0
            OR d.export_gap_intervals > 0
            THEN 'GAPS_DETECTED'

        WHEN
            d.import_rollover_intervals > 0
            OR d.export_rollover_intervals > 0
            THEN 'ROLLOVER_DETECTED'

        ELSE 'GOOD'
    END AS quality_status

FROM daily d;


COMMENT ON VIEW analytics.v_energy_reporting_daily IS
'Tenant-aware, site-timezone-aware daily semantic energy reporting derived exclusively from validated fifteen-minute semantic reporting. Valid energy and child quality counts are preserved independently; cumulative registers are never reclassified.';


ALTER VIEW analytics.v_energy_reporting_daily
OWNER TO ems_admin;


REVOKE ALL
ON analytics.v_energy_reporting_daily
FROM PUBLIC;


-- Validation-only shadow reporting contract.
-- Consumer grants are intentionally deferred until compatibility cutover.

GRANT SELECT
ON analytics.v_energy_reporting_daily
TO ems_admin;

