-- ============================================================================
-- Migration 185
-- Analytical Explorer backend infrastructure: generic rollup CAGGs and a
-- safe, dynamically-routed query contract for the Analytics Explorer
-- dashboard's ad-hoc asset/point picker.
--
-- Purpose:
--   The Explorer lets a user pick up to 5 assets and up to 5 logical
--   points and chart any time range. Reading telemetry.normalized_points
--   directly for wide ranges is expensive at scale, so this migration
--   adds two generic rollup tiers plus a single safeguarded, dynamically-
--   routed function, mirroring the pattern already established for
--   energy (migrations 044/045) and electrical (migration 046) trend
--   panels: <=24h native, <=14d 15-minute rollup, >14d hourly rollup.
--
-- Schema note -- deviation from the literal "group by asset_id" request:
--   telemetry.normalized_points has no asset_id column (verified via
--   \d telemetry.normalized_points before writing this file). A raw
--   telemetry row identifies its source by device_id only; asset
--   ownership is a separate, mutable relationship
--   (metadata.asset_devices, device_id -> asset_id, which can carry
--   several relationship_type rows per device). Baking that join into
--   the continuous aggregate's GROUP BY would let a later device/asset
--   reassignment silently desynchronize already-materialized buckets,
--   since CAGG refresh only reprocesses by time range, not by changes to
--   a joined dimension table. So the two CAGGs below group by device_id
--   (the real, immutable column on the hypertable) and asset_id is
--   resolved at query time inside get_grafana_explorer_intervals, via a
--   fresh join to metadata.asset_devices -- always correct, never stale,
--   consistent with how every other function in this system resolves
--   asset -> device.
--
-- p_logical_points is TEXT[] (point names, e.g. 'ACTIVE_POWER_TOTAL'),
--   matching telemetry.normalized_points.logical_point, which already
--   carries the human-readable name on every row -- no extra join is
--   needed to filter the native tier. The 15m/1h tiers only store
--   logical_point_id (uuid), so those two branches resolve the requested
--   names to ids via metadata.logical_points.name once per call.
--
-- New objects:
--   analytics.generic_telemetry_15m / generic_telemetry_1h
--     Continuous aggregates over telemetry.normalized_points, grouped by
--     time_bucket, organization_id, site_id, device_id, logical_point_id.
--     avg_value / min_value / max_value only, per the requested output
--     shape -- no extra columns.
--
--   analytics.get_grafana_explorer_intervals(
--     p_grafana_org_id bigint,
--     p_asset_ids uuid[],
--     p_logical_points text[],
--     p_from timestamptz,
--     p_to timestamptz
--   )
--     Hard safeguard: raises 'Explorer is limited to 5 assets and 5
--     metrics to ensure performance.' if either array exceeds 5
--     elements. Returns no rows if either array is NULL or empty.
--     Routes native / generic_telemetry_15m / generic_telemetry_1h by
--     the same <=24h / <=14d / >14d thresholds used elsewhere. Tenant
--     isolation via metadata.grafana_organization_map + an inner join to
--     metadata.assets requiring organization_id to match -- an
--     asset_id from another org simply produces no rows.
--
-- Backfill:
--   refresh_continuous_aggregate() cannot run inside an explicit
--   transaction block, and this repo's migration runner always wraps
--   files in BEGIN/COMMIT, so the historical backfill is NOT in this
--   file -- run separately, immediately after this migration applies:
--
--     CALL refresh_continuous_aggregate('analytics.generic_telemetry_15m', NULL, NULL);
--     CALL refresh_continuous_aggregate('analytics.generic_telemetry_1h', NULL, NULL);
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Continuous aggregates.
-- ----------------------------------------------------------------------------

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.generic_telemetry_15m
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '15 minutes',
        event_time
    )
        AS bucket_start,

    organization_id,
    site_id,
    device_id,
    logical_point_id,

    AVG(numeric_value) AS avg_value,
    MIN(numeric_value) AS min_value,
    MAX(numeric_value) AS max_value

FROM telemetry.normalized_points

WHERE numeric_value IS NOT NULL

GROUP BY
    1,
    organization_id,
    site_id,
    device_id,
    logical_point_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy
(
    'analytics.generic_telemetry_15m'::REGCLASS,

    start_offset      => INTERVAL '2 days',
    end_offset        => INTERVAL '1 minute',
    schedule_interval => INTERVAL '5 minutes',

    if_not_exists     => TRUE
);


CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.generic_telemetry_1h
WITH
(
    timescaledb.continuous
)
AS

SELECT
    time_bucket
    (
        INTERVAL '1 hour',
        event_time
    )
        AS bucket_start,

    organization_id,
    site_id,
    device_id,
    logical_point_id,

    AVG(numeric_value) AS avg_value,
    MIN(numeric_value) AS min_value,
    MAX(numeric_value) AS max_value

FROM telemetry.normalized_points

WHERE numeric_value IS NOT NULL

GROUP BY
    1,
    organization_id,
    site_id,
    device_id,
    logical_point_id

WITH NO DATA;


SELECT add_continuous_aggregate_policy
(
    'analytics.generic_telemetry_1h'::REGCLASS,

    start_offset      => INTERVAL '7 days',
    end_offset        => INTERVAL '5 minutes',
    schedule_interval => INTERVAL '15 minutes',

    if_not_exists     => TRUE
);


GRANT SELECT
ON analytics.generic_telemetry_15m
TO
    ems_app,
    ems_readonly,
    grafana_reader;


GRANT SELECT
ON analytics.generic_telemetry_1h
TO
    ems_app,
    ems_readonly,
    grafana_reader;


-- ----------------------------------------------------------------------------
-- 2. Safe, dynamically-routed query function.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION analytics.get_grafana_explorer_intervals
(
    p_grafana_org_id BIGINT,
    p_asset_ids UUID[],
    p_logical_points TEXT[],
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE
(
    interval_start TIMESTAMPTZ,
    asset_id UUID,
    logical_point_id UUID,
    avg_value DOUBLE PRECISION,
    min_value DOUBLE PRECISION,
    max_value DOUBLE PRECISION
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'pg_catalog', 'analytics', 'telemetry', 'metadata'
AS $function$

DECLARE
    v_asset_count INTEGER;
    v_point_count INTEGER;
    v_resolution TEXT;

BEGIN

    v_asset_count := array_length(p_asset_ids, 1);
    v_point_count := array_length(p_logical_points, 1);

    IF v_asset_count IS NULL OR v_point_count IS NULL THEN
        RETURN;
    END IF;

    IF v_asset_count > 5 OR v_point_count > 5 THEN
        RAISE EXCEPTION
            'Explorer is limited to 5 assets and 5 metrics to ensure performance.';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RETURN;
    END IF;

    IF p_to - p_from <= INTERVAL '24 hours' THEN
        v_resolution := 'native';
    ELSIF p_to - p_from <= INTERVAL '14 days' THEN
        v_resolution := '15m';
    ELSE
        v_resolution := '1h';
    END IF;

    IF v_resolution = 'native' THEN

        RETURN QUERY
        SELECT
            time_bucket(INTERVAL '1 minute', np.event_time),
            ad.asset_id,
            np.logical_point_id,

            AVG(np.numeric_value)::DOUBLE PRECISION,
            MIN(np.numeric_value)::DOUBLE PRECISION,
            MAX(np.numeric_value)::DOUBLE PRECISION

        FROM metadata.grafana_organization_map AS gom

        JOIN metadata.assets AS a
            ON a.organization_id = gom.organization_id
            AND a.id = ANY(p_asset_ids)

        JOIN metadata.asset_devices AS ad
            ON ad.asset_id = a.id

        JOIN telemetry.normalized_points AS np
            ON np.device_id = ad.device_id
            AND np.organization_id = gom.organization_id
            AND np.event_time >= p_from
            AND np.event_time < p_to
            AND np.numeric_value IS NOT NULL
            AND np.logical_point = ANY(p_logical_points)

        WHERE gom.grafana_org_id = p_grafana_org_id
            AND gom.is_active

        GROUP BY
            1,
            ad.asset_id,
            np.logical_point_id

        ORDER BY 1;

    ELSIF v_resolution = '15m' THEN

        RETURN QUERY
        SELECT
            g.bucket_start,
            ad.asset_id,
            g.logical_point_id,

            g.avg_value::DOUBLE PRECISION,
            g.min_value::DOUBLE PRECISION,
            g.max_value::DOUBLE PRECISION

        FROM metadata.grafana_organization_map AS gom

        JOIN metadata.assets AS a
            ON a.organization_id = gom.organization_id
            AND a.id = ANY(p_asset_ids)

        JOIN metadata.asset_devices AS ad
            ON ad.asset_id = a.id

        JOIN metadata.logical_points AS lp
            ON lp.name = ANY(p_logical_points)

        JOIN analytics.generic_telemetry_15m AS g
            ON g.device_id = ad.device_id
            AND g.organization_id = gom.organization_id
            AND g.logical_point_id = lp.id
            AND g.bucket_start >= p_from
            AND g.bucket_start < p_to

        WHERE gom.grafana_org_id = p_grafana_org_id
            AND gom.is_active

        ORDER BY 1;

    ELSE

        RETURN QUERY
        SELECT
            g.bucket_start,
            ad.asset_id,
            g.logical_point_id,

            g.avg_value::DOUBLE PRECISION,
            g.min_value::DOUBLE PRECISION,
            g.max_value::DOUBLE PRECISION

        FROM metadata.grafana_organization_map AS gom

        JOIN metadata.assets AS a
            ON a.organization_id = gom.organization_id
            AND a.id = ANY(p_asset_ids)

        JOIN metadata.asset_devices AS ad
            ON ad.asset_id = a.id

        JOIN metadata.logical_points AS lp
            ON lp.name = ANY(p_logical_points)

        JOIN analytics.generic_telemetry_1h AS g
            ON g.device_id = ad.device_id
            AND g.organization_id = gom.organization_id
            AND g.logical_point_id = lp.id
            AND g.bucket_start >= p_from
            AND g.bucket_start < p_to

        WHERE gom.grafana_org_id = p_grafana_org_id
            AND gom.is_active

        ORDER BY 1;

    END IF;

    RETURN;

END;
$function$;


COMMENT ON FUNCTION analytics.get_grafana_explorer_intervals(
    BIGINT,
    UUID[],
    TEXT[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Safeguarded, dynamically-routed query contract for the Analytics Explorer dashboard: max 5 assets and 5 logical points per call, routes native/15m/1h by the <=24h/<=14d/>14d thresholds shared with the energy and electrical trend contracts.';


ALTER FUNCTION analytics.get_grafana_explorer_intervals(
    BIGINT,
    UUID[],
    TEXT[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_grafana_explorer_intervals(
    BIGINT,
    UUID[],
    TEXT[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_explorer_intervals(
    BIGINT,
    UUID[],
    TEXT[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO
    ems_app,
    ems_readonly,
    grafana_reader;
