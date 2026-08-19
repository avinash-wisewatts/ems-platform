-- ============================================================================
-- Migration 035
-- Combined native energy-quality event counters
--
-- Purpose:
--   Preserve exact legacy-compatible combined event counts without
--   double-counting import/export states.
--
-- Rules:
--   gap_detected      -> authoritative persisted combined flag
--   reset_detected    -> import_reset_detected OR export_reset_detected
--   rollover_detected -> import_rollover_detected OR export_rollover_detected
--   invalid_detected  -> either import or export interval is not valid
--
-- No energy register classification occurs in this migration.
-- Existing columns and ordering are preserved; new columns are appended.
-- ============================================================================


-- ============================================================================
-- 1. NATIVE SEMANTIC SOURCE
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_consumption_native
AS

SELECT
    bucket_start,
    organization_id,
    site_id,
    device_id,

    60::INTEGER AS native_resolution_seconds,

    previous_bucket_start,
    elapsed_minutes,
    source_sample_count,

    import_register_wh,
    previous_import_register_wh,
    import_consumption_wh,
    import_consumption_kwh,
    import_quality_code,
    import_is_valid,
    import_reset_detected,
    import_rollover_detected,

    export_register_wh,
    previous_export_register_wh,
    export_consumption_wh,
    export_consumption_kwh,
    export_quality_code,
    export_is_valid,
    export_reset_detected,
    export_rollover_detected,

    gap_detected,

    (
        COALESCE(import_reset_detected, FALSE)
        OR COALESCE(export_reset_detected, FALSE)
    ) AS reset_detected,

    (
        COALESCE(import_rollover_detected, FALSE)
        OR COALESCE(export_rollover_detected, FALSE)
    ) AS rollover_detected,

    (
        import_is_valid IS NOT TRUE
        OR export_is_valid IS NOT TRUE
    ) AS invalid_detected

FROM analytics.energy_consumption_1min


UNION ALL


SELECT
    bucket_start,
    organization_id,
    site_id,
    device_id,

    300::INTEGER AS native_resolution_seconds,

    previous_bucket_start,
    elapsed_minutes,
    source_sample_count,

    import_register_wh,
    previous_import_register_wh,
    import_consumption_wh,
    import_consumption_kwh,
    import_quality_code,
    import_is_valid,
    import_reset_detected,
    import_rollover_detected,

    export_register_wh,
    previous_export_register_wh,
    export_consumption_wh,
    export_consumption_kwh,
    export_quality_code,
    export_is_valid,
    export_reset_detected,
    export_rollover_detected,

    gap_detected,

    (
        COALESCE(import_reset_detected, FALSE)
        OR COALESCE(export_reset_detected, FALSE)
    ) AS reset_detected,

    (
        COALESCE(import_rollover_detected, FALSE)
        OR COALESCE(export_rollover_detected, FALSE)
    ) AS rollover_detected,

    (
        import_is_valid IS NOT TRUE
        OR export_is_valid IS NOT TRUE
    ) AS invalid_detected

FROM analytics.energy_consumption_5min;


COMMENT ON VIEW analytics.v_energy_consumption_native IS
'Internal unified native validated energy source. Includes authoritative combined gap, reset, rollover and invalid event flags without reclassifying registers.';


-- ============================================================================
-- 2. FIVE-MINUTE SEMANTIC ROLLUP
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_5min
AS

WITH grouped AS
(
    SELECT
        date_bin(
            INTERVAL '5 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS bucket_start,

        n.organization_id,
        n.site_id,
        n.device_id,

        count(*) AS source_interval_count,
        sum(n.source_sample_count) AS source_sample_count,

        count(*) FILTER (WHERE n.import_is_valid)
            AS valid_import_intervals,

        count(*) FILTER (WHERE NOT n.import_is_valid)
            AS invalid_import_intervals,

        count(*) FILTER (WHERE n.export_is_valid)
            AS valid_export_intervals,

        count(*) FILTER (WHERE NOT n.export_is_valid)
            AS invalid_export_intervals,

        count(*) FILTER (
            WHERE n.import_quality_code = 'GAP'
        ) AS import_gap_intervals,

        count(*) FILTER (
            WHERE n.export_quality_code = 'GAP'
        ) AS export_gap_intervals,

        count(*) FILTER (
            WHERE n.import_reset_detected
        ) AS import_reset_intervals,

        count(*) FILTER (
            WHERE n.export_reset_detected
        ) AS export_reset_intervals,

        count(*) FILTER (
            WHERE n.import_rollover_detected
        ) AS import_rollover_intervals,

        count(*) FILTER (
            WHERE n.export_rollover_detected
        ) AS export_rollover_intervals,

        sum(n.import_consumption_wh)
            FILTER (WHERE n.import_is_valid)
            AS import_consumption_wh,

        sum(n.import_consumption_kwh)
            FILTER (WHERE n.import_is_valid)
            AS import_consumption_kwh,

        sum(n.export_consumption_wh)
            FILTER (WHERE n.export_is_valid)
            AS export_consumption_wh,

        sum(n.export_consumption_kwh)
            FILTER (WHERE n.export_is_valid)
            AS export_consumption_kwh,

        min(n.bucket_start) AS first_native_bucket_start,
        max(n.bucket_start) AS last_native_bucket_start,

        (array_agg(
            n.previous_bucket_start
            ORDER BY n.bucket_start
        ))[1] AS first_previous_bucket_start,

        (array_agg(
            n.previous_import_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_import_register_wh,

        (array_agg(
            n.import_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS import_register_wh,

        (array_agg(
            n.previous_export_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_export_register_wh,

        (array_agg(
            n.export_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS export_register_wh,

        array_agg(
            DISTINCT n.import_quality_code
            ORDER BY n.import_quality_code
        ) AS import_quality_codes,

        array_agg(
            DISTINCT n.export_quality_code
            ORDER BY n.export_quality_code
        ) AS export_quality_codes,

        min(n.native_resolution_seconds)
            AS minimum_native_resolution_seconds,

        max(n.native_resolution_seconds)
            AS maximum_native_resolution_seconds,

        count(*) FILTER (WHERE n.gap_detected)
            AS gap_interval_count,

        count(*) FILTER (WHERE n.reset_detected)
            AS reset_interval_count,

        count(*) FILTER (WHERE n.rollover_detected)
            AS rollover_interval_count,

        count(*) FILTER (WHERE n.invalid_detected)
            AS invalid_interval_count

    FROM analytics.v_energy_consumption_native n

    GROUP BY
        date_bin(
            INTERVAL '5 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ),
        n.organization_id,
        n.site_id,
        n.device_id
)

SELECT
    g.bucket_start,
    g.organization_id,
    g.site_id,
    g.device_id,
    g.source_interval_count,
    g.source_sample_count,
    g.valid_import_intervals,
    g.invalid_import_intervals,
    g.valid_export_intervals,
    g.invalid_export_intervals,
    g.import_gap_intervals,
    g.export_gap_intervals,
    g.import_reset_intervals,
    g.export_reset_intervals,
    g.import_rollover_intervals,
    g.export_rollover_intervals,
    g.import_consumption_wh,
    g.import_consumption_kwh,
    g.export_consumption_wh,
    g.export_consumption_kwh,
    g.first_native_bucket_start,
    g.last_native_bucket_start,
    g.first_previous_bucket_start,
    g.previous_import_register_wh,
    g.import_register_wh,
    g.previous_export_register_wh,
    g.export_register_wh,
    g.import_quality_codes,
    g.export_quality_codes,
    g.minimum_native_resolution_seconds,
    g.maximum_native_resolution_seconds,

    CASE
        WHEN g.invalid_interval_count > 0
            THEN 'INVALID_INTERVALS'
        WHEN g.reset_interval_count > 0
            THEN 'RESET_DETECTED'
        WHEN g.gap_interval_count > 0
            THEN 'GAPS_DETECTED'
        WHEN g.rollover_interval_count > 0
            THEN 'ROLLOVER_DETECTED'
        ELSE 'GOOD'
    END AS quality_status,

    g.gap_interval_count,
    g.reset_interval_count,
    g.rollover_interval_count,
    g.invalid_interval_count

FROM grouped g;


-- ============================================================================
-- 3. FIFTEEN-MINUTE SEMANTIC ROLLUP
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_15min
AS

WITH grouped AS
(
    SELECT
        date_bin(
            INTERVAL '15 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS bucket_start,

        n.organization_id,
        n.site_id,
        n.device_id,

        count(*) AS source_interval_count,
        sum(n.source_sample_count) AS source_sample_count,

        count(*) FILTER (WHERE n.import_is_valid)
            AS valid_import_intervals,

        count(*) FILTER (WHERE NOT n.import_is_valid)
            AS invalid_import_intervals,

        count(*) FILTER (WHERE n.export_is_valid)
            AS valid_export_intervals,

        count(*) FILTER (WHERE NOT n.export_is_valid)
            AS invalid_export_intervals,

        count(*) FILTER (
            WHERE n.import_quality_code = 'GAP'
        ) AS import_gap_intervals,

        count(*) FILTER (
            WHERE n.export_quality_code = 'GAP'
        ) AS export_gap_intervals,

        count(*) FILTER (
            WHERE n.import_reset_detected
        ) AS import_reset_intervals,

        count(*) FILTER (
            WHERE n.export_reset_detected
        ) AS export_reset_intervals,

        count(*) FILTER (
            WHERE n.import_rollover_detected
        ) AS import_rollover_intervals,

        count(*) FILTER (
            WHERE n.export_rollover_detected
        ) AS export_rollover_intervals,

        sum(n.import_consumption_wh)
            FILTER (WHERE n.import_is_valid)
            AS import_consumption_wh,

        sum(n.import_consumption_kwh)
            FILTER (WHERE n.import_is_valid)
            AS import_consumption_kwh,

        sum(n.export_consumption_wh)
            FILTER (WHERE n.export_is_valid)
            AS export_consumption_wh,

        sum(n.export_consumption_kwh)
            FILTER (WHERE n.export_is_valid)
            AS export_consumption_kwh,

        min(n.bucket_start) AS first_native_bucket_start,
        max(n.bucket_start) AS last_native_bucket_start,

        (array_agg(
            n.previous_bucket_start
            ORDER BY n.bucket_start
        ))[1] AS first_previous_bucket_start,

        (array_agg(
            n.previous_import_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_import_register_wh,

        (array_agg(
            n.import_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS import_register_wh,

        (array_agg(
            n.previous_export_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_export_register_wh,

        (array_agg(
            n.export_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS export_register_wh,

        array_agg(
            DISTINCT n.import_quality_code
            ORDER BY n.import_quality_code
        ) AS import_quality_codes,

        array_agg(
            DISTINCT n.export_quality_code
            ORDER BY n.export_quality_code
        ) AS export_quality_codes,

        min(n.native_resolution_seconds)
            AS minimum_native_resolution_seconds,

        max(n.native_resolution_seconds)
            AS maximum_native_resolution_seconds,

        count(*) FILTER (WHERE n.gap_detected)
            AS gap_interval_count,

        count(*) FILTER (WHERE n.reset_detected)
            AS reset_interval_count,

        count(*) FILTER (WHERE n.rollover_detected)
            AS rollover_interval_count,

        count(*) FILTER (WHERE n.invalid_detected)
            AS invalid_interval_count

    FROM analytics.v_energy_consumption_native n

    GROUP BY
        date_bin(
            INTERVAL '15 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ),
        n.organization_id,
        n.site_id,
        n.device_id
)

SELECT
    g.bucket_start,
    g.organization_id,
    g.site_id,
    g.device_id,
    g.source_interval_count,
    g.source_sample_count,
    g.valid_import_intervals,
    g.invalid_import_intervals,
    g.valid_export_intervals,
    g.invalid_export_intervals,
    g.import_gap_intervals,
    g.export_gap_intervals,
    g.import_reset_intervals,
    g.export_reset_intervals,
    g.import_rollover_intervals,
    g.export_rollover_intervals,
    g.import_consumption_wh,
    g.import_consumption_kwh,
    g.export_consumption_wh,
    g.export_consumption_kwh,
    g.first_native_bucket_start,
    g.last_native_bucket_start,
    g.first_previous_bucket_start,
    g.previous_import_register_wh,
    g.import_register_wh,
    g.previous_export_register_wh,
    g.export_register_wh,
    g.import_quality_codes,
    g.export_quality_codes,
    g.minimum_native_resolution_seconds,
    g.maximum_native_resolution_seconds,

    CASE
        WHEN g.invalid_interval_count > 0
            THEN 'INVALID_INTERVALS'
        WHEN g.reset_interval_count > 0
            THEN 'RESET_DETECTED'
        WHEN g.gap_interval_count > 0
            THEN 'GAPS_DETECTED'
        WHEN g.rollover_interval_count > 0
            THEN 'ROLLOVER_DETECTED'
        ELSE 'GOOD'
    END AS quality_status,

    g.gap_interval_count,
    g.reset_interval_count,
    g.rollover_interval_count,
    g.invalid_interval_count

FROM grouped g;


-- ============================================================================
-- 4. TENANT-AWARE REPORTING VIEWS
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

    r.quality_status,

    r.gap_interval_count,
    r.reset_interval_count,
    r.rollover_interval_count,
    r.invalid_interval_count

FROM analytics.v_energy_semantic_rollup_5min r

JOIN metadata.devices d
  ON d.id = r.device_id
 AND d.organization_id = r.organization_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = r.organization_id
 AND gom.is_active = TRUE;


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

    r.quality_status,

    r.gap_interval_count,
    r.reset_interval_count,
    r.rollover_interval_count,
    r.invalid_interval_count

FROM analytics.v_energy_semantic_rollup_15min r

JOIN metadata.devices d
  ON d.id = r.device_id
 AND d.organization_id = r.organization_id

JOIN metadata.grafana_organization_map gom
  ON gom.organization_id = r.organization_id
 AND gom.is_active = TRUE;


-- ============================================================================
-- 5. DAILY SEMANTIC REPORTING
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
            r.bucket_start AT TIME ZONE s.timezone
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
            r.bucket_start AT TIME ZONE s.timezone
        )::date
)

SELECT
    d.grafana_org_id,
    d.organization_id,
    d.site_id,
    d.device_id,
    d.external_id,
    d.device_name,
    d.site_timezone,
    d.consumption_date,
    d.source_interval_count,
    d.source_sample_count,
    d.valid_import_intervals,
    d.invalid_import_intervals,
    d.valid_export_intervals,
    d.invalid_export_intervals,
    d.import_gap_intervals,
    d.export_gap_intervals,
    d.import_reset_intervals,
    d.export_reset_intervals,
    d.import_rollover_intervals,
    d.export_rollover_intervals,
    d.import_consumption_wh,
    d.import_consumption_kwh,
    d.export_consumption_wh,
    d.export_consumption_kwh,
    d.first_native_bucket_start,
    d.last_native_bucket_start,
    d.minimum_native_resolution_seconds,
    d.maximum_native_resolution_seconds,

    CASE
        WHEN d.invalid_interval_count > 0
            THEN 'INVALID_INTERVALS'
        WHEN d.reset_interval_count > 0
            THEN 'RESET_DETECTED'
        WHEN d.gap_interval_count > 0
            THEN 'GAPS_DETECTED'
        WHEN d.rollover_interval_count > 0
            THEN 'ROLLOVER_DETECTED'
        ELSE 'GOOD'
    END AS quality_status,

    d.gap_interval_count,
    d.reset_interval_count,
    d.rollover_interval_count,
    d.invalid_interval_count

FROM daily d;


-- ============================================================================
-- 6. OWNERSHIP AND SECURITY
-- ============================================================================

ALTER VIEW analytics.v_energy_consumption_native
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_semantic_rollup_5min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_semantic_rollup_15min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_reporting_5min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_reporting_15min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_reporting_daily
OWNER TO ems_admin;


REVOKE ALL ON analytics.v_energy_consumption_native FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_semantic_rollup_5min FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_semantic_rollup_15min FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_reporting_5min FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_reporting_15min FROM PUBLIC;
REVOKE ALL ON analytics.v_energy_reporting_daily FROM PUBLIC;


GRANT SELECT ON analytics.v_energy_consumption_native TO ems_admin;
GRANT SELECT ON analytics.v_energy_semantic_rollup_5min TO ems_admin;
GRANT SELECT ON analytics.v_energy_semantic_rollup_15min TO ems_admin;
GRANT SELECT ON analytics.v_energy_reporting_5min TO ems_admin;
GRANT SELECT ON analytics.v_energy_reporting_15min TO ems_admin;
GRANT SELECT ON analytics.v_energy_reporting_daily TO ems_admin;

