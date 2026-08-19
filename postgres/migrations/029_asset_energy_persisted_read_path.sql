-- ============================================================================
-- Migration 029
-- Asset energy persisted read path
--
-- Replaces the implementation of the existing tenant-safe Grafana asset
-- energy function with the validated persisted one-minute consumption layer.
--
-- Public contract intentionally remains unchanged:
--
-- analytics.get_grafana_asset_energy_intervals(
--     grafana_org_id,
--     asset_id,
--     from,
--     to
-- )
--
-- This allows Grafana and other callers to retain the same interface while
-- eliminating repeated register-delta classification at query time.
-- ============================================================================


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

WITH ctx AS (
    SELECT
        a.id AS asset_id,
        ad.device_id,
        d.name AS device_name

    FROM metadata.grafana_organization_map AS gom

    JOIN metadata.assets AS a
      ON a.organization_id = gom.organization_id

    JOIN metadata.asset_devices AS ad
      ON ad.asset_id = a.id
     AND ad.relationship_type = 'PRIMARY_METER'

    JOIN metadata.devices AS d
      ON d.id = ad.device_id

    WHERE gom.grafana_org_id = p_grafana_org_id
      AND gom.is_active
      AND a.id = p_asset_id
      AND p_to > p_from

    LIMIT 1
)

SELECT
    ec.bucket_start AS interval_start,
    ec.device_id,
    ctx.device_name,
    ec.elapsed_minutes,
    ec.import_consumption_kwh,
    ec.export_consumption_kwh,
    ec.import_quality_code,
    ec.export_quality_code,

    (
        ec.import_reset_detected
        OR ec.export_reset_detected
    ) AS reset_detected,

    ec.gap_detected

FROM ctx

JOIN analytics.energy_consumption_1min AS ec
  ON ec.device_id = ctx.device_id
 AND ec.bucket_start >= p_from
 AND ec.bucket_start <= p_to

ORDER BY
    ec.bucket_start;

$function$;


COMMENT ON FUNCTION analytics.get_grafana_asset_energy_intervals(
    BIGINT,
    UUID,
    TIMESTAMPTZ,
    TIMESTAMPTZ
)
IS
'Tenant-safe Asset Dashboard energy interval contract backed by persisted validated one-minute consumption. Grafana organization ownership and PRIMARY_METER assignment are resolved before returning energy rows.';


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

