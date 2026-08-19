-- ============================================================================
-- Migration 032
-- Validated energy semantic reporting rollups
--
-- Purpose:
--   Build higher-resolution reporting intervals exclusively from already
--   classified native-resolution consumption.
--
-- Native semantic sources:
--   analytics.energy_consumption_1min  -> effective <=60-second capture
--   analytics.energy_consumption_5min  -> effective 300-second capture
--
-- IMPORTANT:
--   This layer MUST NOT rerun cumulative-register delta classification.
--   Classification belongs only in native persistence layers.
--
-- This migration introduces internal rollup views only. Existing public
-- compatibility/reporting views remain unchanged until equivalence and
-- performance validation is complete.
-- ============================================================================


-- ============================================================================
-- 1. UNIFIED NATIVE SEMANTIC SOURCE
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

    gap_detected

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

    gap_detected

FROM analytics.energy_consumption_5min;


COMMENT ON VIEW analytics.v_energy_consumption_native IS
'Internal unified native-resolution validated energy-consumption source. Combines persisted one-minute semantics for <=60-second capture policies and persisted native five-minute semantics for 300-second capture policies. No register-delta classification occurs in this view.';


-- ============================================================================
-- 2. INTERNAL FIVE-MINUTE SEMANTIC ROLLUP
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_5min
AS

WITH grouped AS
(
    SELECT
        date_bin
        (
            INTERVAL '5 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS bucket_start,

        n.organization_id,
        n.site_id,
        n.device_id,

        count(*) AS source_interval_count,

        sum(n.source_sample_count) AS source_sample_count,

        count(*) FILTER
        (
            WHERE n.import_is_valid
        ) AS valid_import_intervals,

        count(*) FILTER
        (
            WHERE NOT n.import_is_valid
        ) AS invalid_import_intervals,

        count(*) FILTER
        (
            WHERE n.export_is_valid
        ) AS valid_export_intervals,

        count(*) FILTER
        (
            WHERE NOT n.export_is_valid
        ) AS invalid_export_intervals,

        count(*) FILTER
        (
            WHERE n.import_quality_code = 'GAP'
        ) AS import_gap_intervals,

        count(*) FILTER
        (
            WHERE n.export_quality_code = 'GAP'
        ) AS export_gap_intervals,

        count(*) FILTER
        (
            WHERE n.import_reset_detected
        ) AS import_reset_intervals,

        count(*) FILTER
        (
            WHERE n.export_reset_detected
        ) AS export_reset_intervals,

        count(*) FILTER
        (
            WHERE n.import_rollover_detected
        ) AS import_rollover_intervals,

        count(*) FILTER
        (
            WHERE n.export_rollover_detected
        ) AS export_rollover_intervals,

        sum(n.import_consumption_wh) FILTER
        (
            WHERE n.import_is_valid
        ) AS import_consumption_wh,

        sum(n.import_consumption_kwh) FILTER
        (
            WHERE n.import_is_valid
        ) AS import_consumption_kwh,

        sum(n.export_consumption_wh) FILTER
        (
            WHERE n.export_is_valid
        ) AS export_consumption_wh,

        sum(n.export_consumption_kwh) FILTER
        (
            WHERE n.export_is_valid
        ) AS export_consumption_kwh,

        min(n.bucket_start) AS first_native_bucket_start,
        max(n.bucket_start) AS last_native_bucket_start,

        (array_agg
        (
            n.previous_bucket_start
            ORDER BY n.bucket_start
        ))[1] AS first_previous_bucket_start,

        (array_agg
        (
            n.previous_import_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_import_register_wh,

        (array_agg
        (
            n.import_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS import_register_wh,

        (array_agg
        (
            n.previous_export_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_export_register_wh,

        (array_agg
        (
            n.export_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS export_register_wh,

        array_agg
        (
            DISTINCT n.import_quality_code
            ORDER BY n.import_quality_code
        ) AS import_quality_codes,

        array_agg
        (
            DISTINCT n.export_quality_code
            ORDER BY n.export_quality_code
        ) AS export_quality_codes,

        min(n.native_resolution_seconds) AS
            minimum_native_resolution_seconds,

        max(n.native_resolution_seconds) AS
            maximum_native_resolution_seconds

    FROM analytics.v_energy_consumption_native n

    GROUP BY
        date_bin
        (
            INTERVAL '5 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ),
        n.organization_id,
        n.site_id,
        n.device_id
)

SELECT
    g.*,

    CASE
        WHEN
            g.invalid_import_intervals > 0
            OR g.invalid_export_intervals > 0
            THEN 'INVALID_INTERVALS'

        WHEN
            g.import_reset_intervals > 0
            OR g.export_reset_intervals > 0
            THEN 'RESET_DETECTED'

        WHEN
            g.import_gap_intervals > 0
            OR g.export_gap_intervals > 0
            THEN 'GAPS_DETECTED'

        WHEN
            g.import_rollover_intervals > 0
            OR g.export_rollover_intervals > 0
            THEN 'ROLLOVER_DETECTED'

        ELSE 'GOOD'
    END AS quality_status

FROM grouped g;


COMMENT ON VIEW analytics.v_energy_semantic_rollup_5min IS
'Internal five-minute semantic reporting rollup derived only from persisted validated native energy intervals. Preserves valid energy while separately exposing invalid, gap, reset and rollover child-interval counts.';


-- ============================================================================
-- 3. INTERNAL FIFTEEN-MINUTE SEMANTIC ROLLUP
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_energy_semantic_rollup_15min
AS

WITH grouped AS
(
    SELECT
        date_bin
        (
            INTERVAL '15 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ) AS bucket_start,

        n.organization_id,
        n.site_id,
        n.device_id,

        count(*) AS source_interval_count,

        sum(n.source_sample_count) AS source_sample_count,

        count(*) FILTER
        (
            WHERE n.import_is_valid
        ) AS valid_import_intervals,

        count(*) FILTER
        (
            WHERE NOT n.import_is_valid
        ) AS invalid_import_intervals,

        count(*) FILTER
        (
            WHERE n.export_is_valid
        ) AS valid_export_intervals,

        count(*) FILTER
        (
            WHERE NOT n.export_is_valid
        ) AS invalid_export_intervals,

        count(*) FILTER
        (
            WHERE n.import_quality_code = 'GAP'
        ) AS import_gap_intervals,

        count(*) FILTER
        (
            WHERE n.export_quality_code = 'GAP'
        ) AS export_gap_intervals,

        count(*) FILTER
        (
            WHERE n.import_reset_detected
        ) AS import_reset_intervals,

        count(*) FILTER
        (
            WHERE n.export_reset_detected
        ) AS export_reset_intervals,

        count(*) FILTER
        (
            WHERE n.import_rollover_detected
        ) AS import_rollover_intervals,

        count(*) FILTER
        (
            WHERE n.export_rollover_detected
        ) AS export_rollover_intervals,

        sum(n.import_consumption_wh) FILTER
        (
            WHERE n.import_is_valid
        ) AS import_consumption_wh,

        sum(n.import_consumption_kwh) FILTER
        (
            WHERE n.import_is_valid
        ) AS import_consumption_kwh,

        sum(n.export_consumption_wh) FILTER
        (
            WHERE n.export_is_valid
        ) AS export_consumption_wh,

        sum(n.export_consumption_kwh) FILTER
        (
            WHERE n.export_is_valid
        ) AS export_consumption_kwh,

        min(n.bucket_start) AS first_native_bucket_start,
        max(n.bucket_start) AS last_native_bucket_start,

        (array_agg
        (
            n.previous_bucket_start
            ORDER BY n.bucket_start
        ))[1] AS first_previous_bucket_start,

        (array_agg
        (
            n.previous_import_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_import_register_wh,

        (array_agg
        (
            n.import_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS import_register_wh,

        (array_agg
        (
            n.previous_export_register_wh
            ORDER BY n.bucket_start
        ))[1] AS previous_export_register_wh,

        (array_agg
        (
            n.export_register_wh
            ORDER BY n.bucket_start DESC
        ))[1] AS export_register_wh,

        array_agg
        (
            DISTINCT n.import_quality_code
            ORDER BY n.import_quality_code
        ) AS import_quality_codes,

        array_agg
        (
            DISTINCT n.export_quality_code
            ORDER BY n.export_quality_code
        ) AS export_quality_codes,

        min(n.native_resolution_seconds) AS
            minimum_native_resolution_seconds,

        max(n.native_resolution_seconds) AS
            maximum_native_resolution_seconds

    FROM analytics.v_energy_consumption_native n

    GROUP BY
        date_bin
        (
            INTERVAL '15 minutes',
            n.bucket_start,
            TIMESTAMPTZ '2000-01-01 00:00:00+00'
        ),
        n.organization_id,
        n.site_id,
        n.device_id
)

SELECT
    g.*,

    CASE
        WHEN
            g.invalid_import_intervals > 0
            OR g.invalid_export_intervals > 0
            THEN 'INVALID_INTERVALS'

        WHEN
            g.import_reset_intervals > 0
            OR g.export_reset_intervals > 0
            THEN 'RESET_DETECTED'

        WHEN
            g.import_gap_intervals > 0
            OR g.export_gap_intervals > 0
            THEN 'GAPS_DETECTED'

        WHEN
            g.import_rollover_intervals > 0
            OR g.export_rollover_intervals > 0
            THEN 'ROLLOVER_DETECTED'

        ELSE 'GOOD'
    END AS quality_status

FROM grouped g;


COMMENT ON VIEW analytics.v_energy_semantic_rollup_15min IS
'Internal fifteen-minute semantic reporting rollup derived only from persisted validated native energy intervals. Higher-resolution register deltas are never reclassified.';


-- ============================================================================
-- 4. SECURITY BOUNDARY
-- ============================================================================

ALTER VIEW analytics.v_energy_consumption_native
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_semantic_rollup_5min
OWNER TO ems_admin;

ALTER VIEW analytics.v_energy_semantic_rollup_15min
OWNER TO ems_admin;


REVOKE ALL
ON analytics.v_energy_consumption_native
FROM PUBLIC;

REVOKE ALL
ON analytics.v_energy_semantic_rollup_5min
FROM PUBLIC;

REVOKE ALL
ON analytics.v_energy_semantic_rollup_15min
FROM PUBLIC;


-- Internal validation layer only.
-- Existing Grafana/public reporting consumers are intentionally not changed.

GRANT SELECT
ON analytics.v_energy_consumption_native
TO ems_admin;

GRANT SELECT
ON analytics.v_energy_semantic_rollup_5min
TO ems_admin;

GRANT SELECT
ON analytics.v_energy_semantic_rollup_15min
TO ems_admin;

