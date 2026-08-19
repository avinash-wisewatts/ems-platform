-- ============================================================================
-- Migration 041
-- Site-timezone-aware semantic hourly energy reporting
--
-- Purpose:
--   Introduce the missing hourly reporting tier by aggregating the existing
--   validated fifteen-minute semantic reporting contract, exactly mirroring
--   how analytics.v_energy_reporting_daily is already built from it.
--
-- Source:
--   analytics.v_energy_reporting_15min, whose energy is already classified
--   at native resolution and already tenant-scoped.
--
-- IMPORTANT:
--   No cumulative-register classification occurs here. This migration does
--   not touch telemetry.ca_energy_hourly or analytics.v_energy_hourly -- both
--   are raw MAX/MIN continuous aggregates with no quality classification and
--   are not used as a source anywhere in this file.
--
--   Bucket boundaries are anchored to each site's configured timezone, not
--   to a fixed UTC epoch, so that sites in UTC+X:30 (e.g. Asia/Kolkata) get
--   real local-hour boundaries. See the inline note below for the one known
--   limitation of this approach at DST fall-back transitions.
-- ============================================================================


CREATE OR REPLACE VIEW analytics.v_energy_reporting_hourly
WITH (security_barrier = true)
AS

WITH hourly AS
(
    SELECT
        r.grafana_org_id,
        r.organization_id,
        r.site_id,
        r.device_id,
        r.external_id,
        r.device_name,

        s.timezone AS site_timezone,

        -- ----------------------------------------------------------------
        -- Site-local hour start, expressed as a real TIMESTAMPTZ instant.
        --
        -- date_trunc('hour', bucket_start AT TIME ZONE site_timezone)
        --     truncates to the site's local wall-clock hour (a naive
        --     timestamp), then "AT TIME ZONE site_timezone" converts that
        --     local wall-clock time back into an instant.
        --
        -- Known limitation: during a DST fall-back transition, the local
        -- civil hour is genuinely ambiguous (it occurs twice). PostgreSQL
        -- resolves that ambiguity deterministically but the two real-world
        -- occurrences collapse onto the same bucket instant. This is an
        -- inherent civil-time ambiguity, not specific to this query, and
        -- is not exercised by any current site (all configured site
        -- timezones are fixed-offset, non-DST, at the time of this
        -- migration). Revisit before onboarding a DST-observing site.
        -- ----------------------------------------------------------------
        (
            date_trunc('hour', r.bucket_start AT TIME ZONE s.timezone)
            AT TIME ZONE s.timezone
        ) AS bucket_start,

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
            AS maximum_native_resolution_seconds,

        sum(r.gap_interval_count)
            AS gap_interval_count,

        sum(r.reset_interval_count)
            AS reset_interval_count,

        sum(r.rollover_interval_count)
            AS rollover_interval_count,

        sum(r.invalid_interval_count)
            AS invalid_interval_count

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
            date_trunc('hour', r.bucket_start AT TIME ZONE s.timezone)
            AT TIME ZONE s.timezone
        )
)

SELECT
    h.grafana_org_id,
    h.organization_id,
    h.site_id,
    h.device_id,
    h.external_id,
    h.device_name,
    h.site_timezone,
    h.bucket_start,

    h.source_interval_count,
    h.source_sample_count,

    h.valid_import_intervals,
    h.invalid_import_intervals,
    h.valid_export_intervals,
    h.invalid_export_intervals,

    h.import_gap_intervals,
    h.export_gap_intervals,
    h.import_reset_intervals,
    h.export_reset_intervals,
    h.import_rollover_intervals,
    h.export_rollover_intervals,

    h.import_consumption_wh,
    h.import_consumption_kwh,
    h.export_consumption_wh,
    h.export_consumption_kwh,

    h.first_native_bucket_start,
    h.last_native_bucket_start,
    h.minimum_native_resolution_seconds,
    h.maximum_native_resolution_seconds,

    CASE
        WHEN h.invalid_interval_count > 0
            THEN 'INVALID_INTERVALS'
        WHEN h.reset_interval_count > 0
            THEN 'RESET_DETECTED'
        WHEN h.gap_interval_count > 0
            THEN 'GAPS_DETECTED'
        WHEN h.rollover_interval_count > 0
            THEN 'ROLLOVER_DETECTED'
        ELSE 'GOOD'
    END AS quality_status,

    h.gap_interval_count,
    h.reset_interval_count,
    h.rollover_interval_count,
    h.invalid_interval_count

FROM hourly h;


ALTER VIEW analytics.v_energy_reporting_hourly
OWNER TO ems_admin;


REVOKE ALL
ON analytics.v_energy_reporting_hourly
FROM PUBLIC;


-- Validation-only reporting contract for now, matching the existing
-- deferred-grant posture of v_energy_reporting_5min/15min/daily. Consumer
-- grants (ems_app, ems_readonly, grafana_reader) are deferred until the
-- canonical energy reader is wired to this tier.

GRANT SELECT
ON analytics.v_energy_reporting_hourly
TO ems_admin;


COMMENT ON VIEW analytics.v_energy_reporting_hourly IS
'Tenant-aware, site-timezone-aware hourly semantic energy reporting derived exclusively from validated fifteen-minute semantic reporting. Valid energy and child quality counts are preserved independently; cumulative registers are never reclassified.';
