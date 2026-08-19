-- ============================================================================
-- Migration 044
-- Dynamic Grafana resolution routing
--
-- Purpose:
--   Route Grafana panel energy queries to a reporting resolution chosen
--   automatically from the requested time range, instead of always reading
--   raw one-minute consumption (migration 029) regardless of range length.
--   Built entirely on top of the canonical energy reader (migration 042):
--   this migration adds no new physical energy source, only routing and a
--   multi-asset fan-out with a bounded-cost safeguard.
--
-- Routing rule (analytics.resolve_grafana_energy_routing_resolution):
--   range <= 24 hours -> '15m'
--   range <= 14 days  -> '1h'
--   range >  14 days  -> '1d'
--
-- Objects:
--   analytics.resolve_grafana_energy_routing_resolution(from, to) -> TEXT
--     Pure tier-selection helper shared by both functions below, so the
--     three thresholds exist in exactly one place.
--
--   analytics.get_grafana_asset_energy_intervals(...)
--     CREATE OR REPLACE of the existing single-asset contract (migration
--     029). Signature and column list are unchanged, so existing Grafana
--     panels do not need to be reconfigured; only the underlying source and
--     bucketing change, from raw 1-minute rows to the routed resolution
--     tier read through analytics.get_canonical_energy_read. Invalid ranges
--     (p_to <= p_from) continue to collapse to zero rows rather than
--     raising, matching the prior contract.
--
--   analytics.get_grafana_assets_energy_intervals(...)
--     New multi-asset fan-out over the function above. Rejects more than
--     10 assets per call so a single dashboard panel cannot fan out an
--     unbounded number of canonical-reader calls.
-- ============================================================================


CREATE OR REPLACE FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $function$
SELECT CASE
    WHEN p_to - p_from <= INTERVAL '24 hours' THEN '15m'
    WHEN p_to - p_from <= INTERVAL '14 days'  THEN '1h'
    ELSE '1d'
END;
$function$;


COMMENT ON FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Maps a Grafana panel time range to a canonical reporting resolution tier: <=24h -> 15m, <=14d -> 1h, >14d -> 1d. Pure function shared by analytics.get_grafana_asset_energy_intervals and analytics.get_grafana_assets_energy_intervals.';


ALTER FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.resolve_grafana_energy_routing_resolution(
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;

-- Internal helper only, invoked from within the two SECURITY DEFINER
-- functions below (both owned by ems_admin). Not exposed to Grafana or app
-- roles directly.


CREATE OR REPLACE FUNCTION analytics.get_grafana_asset_energy_intervals(
    p_grafana_org_id BIGINT,
    p_asset_id UUID,
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE (
    interval_start TIMESTAMPTZ,
    device_id UUID,
    device_name TEXT,
    elapsed_minutes NUMERIC,
    import_consumption_kwh NUMERIC,
    export_consumption_kwh NUMERIC,
    import_quality_code TEXT,
    export_quality_code TEXT,
    reset_detected BOOLEAN,
    gap_detected BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    metadata
AS $function$

WITH params AS (
    SELECT
        p_from AS range_from,
        p_to AS range_to
    WHERE p_to > p_from
)

SELECT
    r.interval_start,
    r.resolved_device_id,
    r.device_name,
    EXTRACT(EPOCH FROM (r.interval_end - r.interval_start)) / 60.0,
    r.import_consumption_kwh,
    r.export_consumption_kwh,
    r.import_quality_status,
    r.export_quality_status,
    (r.reset_interval_count > 0),
    (r.gap_interval_count > 0)

FROM params

CROSS JOIN LATERAL analytics.get_canonical_energy_read(
    p_grafana_org_id,
    p_asset_id,
    params.range_from,
    params.range_to,
    analytics.resolve_grafana_energy_routing_resolution(
        params.range_from,
        params.range_to
    ),
    'native'
) AS r

ORDER BY
    r.interval_start;

$function$;


COMMENT ON FUNCTION analytics.get_grafana_asset_energy_intervals(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Tenant-safe Asset Dashboard energy interval contract with dynamic resolution routing: reads through analytics.get_canonical_energy_read at a resolution chosen from the requested range by analytics.resolve_grafana_energy_routing_resolution (<=24h -> 15m, <=14d -> 1h, >14d -> 1d). Grafana organization ownership and PRIMARY_METER assignment are resolved before returning energy rows; an invalid range (p_to <= p_from) returns zero rows.';


ALTER FUNCTION analytics.get_grafana_asset_energy_intervals(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_grafana_asset_energy_intervals(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_asset_energy_intervals(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO
    ems_app,
    ems_readonly,
    grafana_reader;


CREATE OR REPLACE FUNCTION analytics.get_grafana_assets_energy_intervals(
    p_grafana_org_id BIGINT,
    p_asset_ids UUID[],
    p_from TIMESTAMPTZ,
    p_to TIMESTAMPTZ
)
RETURNS TABLE (
    asset_id UUID,
    interval_start TIMESTAMPTZ,
    device_id UUID,
    device_name TEXT,
    elapsed_minutes NUMERIC,
    import_consumption_kwh NUMERIC,
    export_consumption_kwh NUMERIC,
    import_quality_code TEXT,
    export_quality_code TEXT,
    reset_detected BOOLEAN,
    gap_detected BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO
    pg_catalog,
    analytics,
    metadata
AS $function$
DECLARE
    v_asset_count INTEGER;
    v_asset_id UUID;
BEGIN
    v_asset_count := array_length(p_asset_ids, 1);

    IF p_asset_ids IS NULL OR v_asset_count IS NULL THEN
        RAISE EXCEPTION
            'p_asset_ids must contain at least one asset';
    END IF;

    IF v_asset_count > 10 THEN
        RAISE EXCEPTION
            'too many assets requested (%); a maximum of 10 assets is '
            'supported per multi-asset Grafana energy query',
            v_asset_count;
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RETURN;
    END IF;

    FOREACH v_asset_id IN ARRAY p_asset_ids
    LOOP
        RETURN QUERY
        SELECT
            v_asset_id,
            i.interval_start,
            i.device_id,
            i.device_name,
            i.elapsed_minutes,
            i.import_consumption_kwh,
            i.export_consumption_kwh,
            i.import_quality_code,
            i.export_quality_code,
            i.reset_detected,
            i.gap_detected
        FROM analytics.get_grafana_asset_energy_intervals(
            p_grafana_org_id,
            v_asset_id,
            p_from,
            p_to
        ) AS i;
    END LOOP;

    RETURN;
END;
$function$;


COMMENT ON FUNCTION analytics.get_grafana_assets_energy_intervals(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Multi-asset fan-out over analytics.get_grafana_asset_energy_intervals for multi-series Grafana panels. Rejects NULL/empty p_asset_ids and rejects more than 10 assets per call to bound the number of canonical-reader invocations behind one panel query. Each asset independently receives dynamic resolution routing for the same [p_from, p_to) range.';


ALTER FUNCTION analytics.get_grafana_assets_energy_intervals(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
OWNER TO ems_admin;


REVOKE ALL
ON FUNCTION analytics.get_grafana_assets_energy_intervals(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_assets_energy_intervals(
    BIGINT,
    UUID[],
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
TO
    ems_app,
    ems_readonly,
    grafana_reader;
