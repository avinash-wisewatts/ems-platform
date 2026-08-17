BEGIN;

-- =====================================================================
-- Analytics Explorer native short-history reader.
--
-- Why PL/pgSQL dynamic SQL?
--
-- The equivalent SQL executed directly uses an efficient TimescaleDB
-- plan, while the SQL-language SECURITY DEFINER function was observed
-- executing through a substantially slower cached/opaque function plan.
--
-- EXECUTE causes this statement to be planned for the actual parameter
-- values on each invocation.
--
-- Parameters remain passed through USING -- no user values are
-- interpolated into SQL text.
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
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, analytics, telemetry, metadata, config
AS $function$

BEGIN

    IF p_grafana_org_id IS NULL THEN
        RAISE EXCEPTION 'grafana_org_id is required';
    END IF;

    IF p_site_id IS NULL THEN
        RAISE EXCEPTION 'site_id is required';
    END IF;

    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'history time bounds are required';
    END IF;

    IF p_from >= p_to THEN
        RAISE EXCEPTION
            'history start must be before history end';
    END IF;


    RETURN QUERY EXECUTE $sql$

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

            WHERE s.grafana_org_id = $1
              AND s.site_id = $2

              AND (
                    $3::uuid[] IS NULL
                    OR s.asset_id = ANY($3::uuid[])
              )

              AND (
                    $4::uuid[] IS NULL
                    OR s.logical_point_id = ANY($4::uuid[])
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

              AND np.event_time >= $5
              AND np.event_time <= $6

              AND np.numeric_value IS NOT NULL

            OFFSET 0

        ) AS history

    $sql$

    USING
        p_grafana_org_id,
        p_site_id,
        p_asset_ids,
        p_logical_point_ids,
        p_from,
        p_to;

END;

$function$;


COMMENT ON FUNCTION analytics.get_grafana_short_history(
    bigint,
    uuid,
    uuid[],
    uuid[],
    timestamptz,
    timestamptz
) IS
'Tenant-safe, parameter-aware native short-history reader. Resolves configured asset/device/logical-point series before TimescaleDB access and dynamically replans the telemetry query for the actual selection. Intended for short windows only; long-range analytics route through aggregate historian surfaces.';


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
