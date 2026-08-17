BEGIN;

-- =====================================================================
-- Canonical short-window Analytics Explorer history surface.
--
-- Design:
--   1. Resolve tenant-safe Asset -> Device -> Logical Point using the
--      lightweight configuration metadata surface.
--   2. Join telemetry.normalized_points by:
--
--          organization_id
--          site_id
--          device_id
--          logical_point_id
--          event_time
--
--   This deliberately avoids the expensive historical
--   asset-resolution path in analytics.v_grafana_normalized_points.
--
-- Usage:
--   NULL asset array       = all available assets
--   NULL logical-point arr = all configured logical points
--
-- This function is intended for SHORT-WINDOW native history.
-- Long windows will later route through the canonical resolution/CAGG
-- historian layer.
-- =====================================================================

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
    np.event_time,

    ss.asset_id,
    ss.asset_name,

    ss.device_id,
    ss.device_name,

    ss.logical_point_id,
    ss.logical_point,
    ss.unit_symbol,
    ss.recommended_aggregation,

    np.numeric_value::double precision,
    np.quality_code

FROM selected_series AS ss

JOIN telemetry.normalized_points AS np
  ON np.organization_id = ss.organization_id
 AND np.site_id = ss.site_id
 AND np.device_id = ss.device_id
 AND np.logical_point_id = ss.logical_point_id

WHERE np.event_time >= p_from
  AND np.event_time <= p_to
  AND np.numeric_value IS NOT NULL

ORDER BY
    np.event_time,
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
'Tenant-safe, device-first native history reader for Analytics Explorer short time windows. Resolves configured asset/device/logical-point series before accessing telemetry.normalized_points. Long-range analytics should use the resolution-aware historian layer.';


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
