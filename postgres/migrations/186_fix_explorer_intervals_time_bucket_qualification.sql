-- ============================================================================
-- Migration 186
-- Fix analytics.get_grafana_explorer_intervals native-tier query: schema-
-- qualify time_bucket().
--
-- Bug: the function's SET search_path is 'pg_catalog, analytics,
--   telemetry, metadata' -- it deliberately does not include public,
--   since widening a SECURITY DEFINER function's search_path to include
--   a schema where any authenticated role can create objects is exactly
--   the class of hijacking risk SET search_path exists to close.
--   TimescaleDB's time_bucket() is installed in the public schema (the
--   extension's default), so the native (<=24h) branch, the only branch
--   that calls time_bucket() directly rather than reading it back out of
--   an already-materialized continuous aggregate, failed with
--   "function time_bucket(interval, timestamp with time zone) does not
--   exist" for every call. The 15m/1h branches were unaffected since
--   they only read bucket_start columns already computed inside
--   analytics.generic_telemetry_15m/1h.
--
-- Fix: schema-qualify the single call site as public.time_bucket(...)
--   instead of adding public to search_path, so the SECURITY DEFINER
--   posture introduced in migration 185 is unchanged.
-- ============================================================================

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
            public.time_bucket(INTERVAL '1 minute', np.event_time),
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
