BEGIN;

CREATE OR REPLACE FUNCTION analytics.get_grafana_short_history(
    p_grafana_org_id bigint,
    p_site_id uuid,
    p_asset_ids uuid[],
    p_logical_point_ids uuid[],
    p_from timestamptz,
    p_to timestamptz
)
RETURNS TABLE (
    event_time timestamptz,
    asset_id uuid,
    asset_name text,
    device_id uuid,
    device_name text,
    logical_point_id uuid,
    logical_point text,
    unit_symbol text,
    recommended_aggregation text,
    numeric_value double precision,
    quality_code text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, analytics, telemetry, metadata, config
AS $function$

WITH selected_series AS MATERIALIZED (

    SELECT DISTINCT
        s.organization_id,
        s.site_id,
        s.asset_id,
        s.asset_name,
        s.device_id,
        s.device_name,
        s.logical_point_id,
        s.logical_point,
        s.unit_symbol,
        s.recommended_aggregation

    FROM analytics.v_grafana_asset_point_selector AS s

    WHERE s.grafana_org_id = p_grafana_org_id
      AND s.site_id = p_site_id

      AND (
          p_asset_ids IS NULL
          OR s.asset_id = ANY(p_asset_ids)
      )

      AND (
          p_logical_point_ids IS NULL
          OR s.logical_point_id = ANY(p_logical_point_ids)
      )
)

SELECT
    history.event_time,

    ss.asset_id,
    ss.asset_name,

    ss.device_id,
    ss.device_name,

    ss.logical_point_id,
    ss.logical_point,
    ss.unit_symbol,
    ss.recommended_aggregation,

    history.numeric_value,
    history.quality_code

FROM selected_series AS ss

CROSS JOIN LATERAL (

    SELECT
        np.event_time,
        np.numeric_value::double precision AS numeric_value,
        np.quality_code

    FROM telemetry.normalized_points AS np

    WHERE np.organization_id = ss.organization_id
      AND np.site_id = ss.site_id
      AND np.device_id = ss.device_id
      AND np.logical_point_id = ss.logical_point_id

      AND np.event_time >= p_from
      AND np.event_time <= p_to

      AND np.numeric_value IS NOT NULL

    -- Prevent PostgreSQL from pulling this lookup back into a
    -- broad telemetry-first join. Each configured series must
    -- reach normalized_points with device + point + time known.
    OFFSET 0

) AS history

ORDER BY
    history.event_time,
    ss.asset_name,
    ss.logical_point;

$function$;


COMMENT ON FUNCTION analytics.get_grafana_short_history(
    bigint,
    uuid,
    uuid[],
    uuid[],
    timestamptz,
    timestamptz
) IS
'Tenant-safe short-history reader for Analytics Explorer. Resolves configured asset/device/logical-point series first, then performs an isolated device+logical-point+time telemetry lookup per series. Intended only for short/native historical windows; longer analytics route through resolution-aware aggregate surfaces.';


REVOKE ALL
ON FUNCTION analytics.get_grafana_short_history(
    bigint,
    uuid,
    uuid[],
    uuid[],
    timestamptz,
    timestamptz
)
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION analytics.get_grafana_short_history(
    bigint,
    uuid,
    uuid[],
    uuid[],
    timestamptz,
    timestamptz
)
TO grafana_reader;

COMMIT;
