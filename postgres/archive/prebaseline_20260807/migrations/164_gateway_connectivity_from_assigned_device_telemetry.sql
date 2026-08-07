-- Gateway connectivity from either explicit device-status events or recent normalized telemetry.
-- A gateway is considered seen when any assigned device has produced mapped telemetry.

CREATE OR REPLACE VIEW analytics.v_gateway_connectivity
WITH (security_barrier = TRUE)
AS
WITH status_seen AS (
    SELECT
        ds.gateway_id,
        max(coalesce(ds.last_successful_communication, ds.source_timestamp, ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds
    WHERE ds.gateway_id IS NOT NULL
    GROUP BY ds.gateway_id
), telemetry_seen AS (
    SELECT
        d.gateway_id,
        max(coalesce(np.platform_received_at, np.created_at)) AS last_seen_at
    FROM metadata.devices d
    JOIN telemetry.normalized_points np
      ON np.device_id = d.id
    WHERE d.gateway_id IS NOT NULL
    GROUP BY d.gateway_id
)
SELECT
    g.id AS gateway_id,
    ss.last_seen_at AS status_last_seen_at,
    ts.last_seen_at AS telemetry_last_seen_at,
    greatest(ss.last_seen_at, ts.last_seen_at) AS last_seen_at,
    CASE
        WHEN ss.last_seen_at IS NULL AND ts.last_seen_at IS NULL THEN NULL
        WHEN ts.last_seen_at IS NULL THEN 'DEVICE_STATUS'
        WHEN ss.last_seen_at IS NULL THEN 'NORMALIZED_TELEMETRY'
        WHEN ts.last_seen_at >= ss.last_seen_at THEN 'NORMALIZED_TELEMETRY'
        ELSE 'DEVICE_STATUS'
    END AS last_seen_source
FROM metadata.gateways g
LEFT JOIN status_seen ss ON ss.gateway_id = g.id
LEFT JOIN telemetry_seen ts ON ts.gateway_id = g.id;

COMMENT ON VIEW analytics.v_gateway_connectivity IS
'Canonical gateway last-seen evidence from explicit device-status events or mapped normalized telemetry received from assigned devices.';

ALTER VIEW analytics.v_gateway_connectivity OWNER TO ems_admin;
REVOKE ALL ON analytics.v_gateway_connectivity FROM PUBLIC;
GRANT SELECT ON analytics.v_gateway_connectivity TO ems_app, ems_readonly, grafana_reader;

CREATE OR REPLACE VIEW analytics.v_commissioning_readiness
WITH (security_barrier = TRUE)
AS
WITH asset_readiness AS (
    SELECT
        'ASSET'::text AS entity_type,
        a.id AS entity_id,
        a.organization_id,
        a.site_id,
        a.name AS entity_name,
        a.lifecycle_status,
        CASE
            WHEN a.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN a.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN c.coverage_status IN ('MISSING_DIRECT_METER', 'UNKNOWN_POLICY') THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            a.lifecycle_status <> 'DECOMMISSIONED'
            AND (
                a.lifecycle_status = 'ACTIVE'
                OR a.metering_requirement IN ('NOT_REQUIRED', 'DESCENDANT_COVERAGE_ALLOWED')
                OR (
                    a.metering_requirement = 'DIRECT_METER_REQUIRED'
                    AND c.coverage_status = 'CONFIGURED'
                )
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN a.lifecycle_status = 'DECOMMISSIONED' THEN 'ASSET_DECOMMISSIONED' END,
            CASE WHEN a.metering_requirement IS NULL THEN 'METERING_POLICY_MISSING' END,
            CASE
                WHEN a.metering_requirement = 'DIRECT_METER_REQUIRED'
                 AND c.coverage_status IS DISTINCT FROM 'CONFIGURED'
                THEN 'QUALIFYING_PRIMARY_METER_REQUIRED'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE
                WHEN a.metering_requirement = 'DESCENDANT_COVERAGE_ALLOWED'
                 AND c.coverage_status IN ('NO_REQUIRED_DESCENDANTS', 'PARTIALLY_CONFIGURED', 'MISSING_DESCENDANT_COVERAGE')
                THEN c.coverage_status
            END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.assets a
    LEFT JOIN analytics.v_asset_meter_coverage_configuration c
      ON c.asset_id = a.id
),
gateway_last_seen AS (
    SELECT gateway_id, last_seen_at
    FROM analytics.v_gateway_connectivity
),
gateway_readiness AS (
    SELECT
        'GATEWAY'::text AS entity_type,
        g.id AS entity_id,
        g.organization_id,
        g.site_id,
        g.name AS entity_name,
        g.lifecycle_status,
        CASE
            WHEN g.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN g.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN nullif(btrim(g.external_id), '') IS NULL OR g.gateway_model_id IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at IS NULL THEN 'BLOCKED'
            WHEN gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            g.lifecycle_status = 'ACTIVE'
            OR (
                g.lifecycle_status <> 'DECOMMISSIONED'
                AND nullif(btrim(g.external_id), '') IS NOT NULL
                AND g.gateway_model_id IS NOT NULL
                AND gls.last_seen_at >= now() - make_interval(secs => gcp.online_threshold_seconds)
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'DECOMMISSIONED' THEN 'GATEWAY_DECOMMISSIONED' END,
            CASE WHEN nullif(btrim(g.external_id), '') IS NULL THEN 'GATEWAY_IDENTITY_MISSING' END,
            CASE WHEN g.gateway_model_id IS NULL THEN 'GATEWAY_MODEL_MISSING' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status <> 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CONNECTIVITY_OFFLINE' END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NULL THEN 'GATEWAY_CURRENTLY_NEVER_SEEN' END,
            CASE WHEN g.lifecycle_status = 'ACTIVE' AND gls.last_seen_at IS NOT NULL AND gls.last_seen_at < now() - make_interval(secs => gcp.online_threshold_seconds) THEN 'GATEWAY_CURRENTLY_OFFLINE' END
        ], NULL)::text[] AS warning_reason_codes
    FROM metadata.gateways g
    CROSS JOIN config.gateway_connectivity_policy gcp
    LEFT JOIN gateway_last_seen gls ON gls.gateway_id = g.id
),
device_required_points AS (
    SELECT
        d.id AS device_id,
        count(DISTINCT pfm.logical_point_id) FILTER (WHERE pfm.is_required) AS required_point_count,
        count(DISTINCT np.logical_point_id) FILTER (
            WHERE pfm.is_required
              AND np.logical_point_id IS NOT NULL
        ) AS validated_required_point_count
    FROM metadata.devices d
    LEFT JOIN config.profile_field_mapping pfm
      ON pfm.profile_id = d.profile_id
    LEFT JOIN telemetry.normalized_points np
      ON np.device_id = d.id
     AND np.logical_point_id = pfm.logical_point_id
     AND coalesce(np.quality_code, 'GOOD') NOT IN ('INVALID', 'REJECTED')
     AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value), '') IS NOT NULL)
    GROUP BY d.id
),
device_readiness AS (
    SELECT
        'DEVICE'::text AS entity_type,
        d.id AS entity_id,
        d.organization_id,
        g.site_id,
        d.name AS entity_name,
        d.lifecycle_status,
        CASE
            WHEN d.lifecycle_status = 'ACTIVE' THEN 'COMMISSIONED'
            WHEN d.lifecycle_status = 'COMMISSIONING' THEN 'IN_PROGRESS'
            WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'FAILED'
            WHEN d.gateway_id IS NULL OR d.device_model_id IS NULL OR d.profile_id IS NULL THEN 'BLOCKED'
            WHEN NOT EXISTS (
                SELECT 1
                FROM config.device_profile_categories dpc
                JOIN metadata.device_models dm ON dm.id = d.device_model_id
                WHERE dpc.profile_id = d.profile_id
                  AND dpc.device_category_id = dm.device_category_id
            ) THEN 'BLOCKED'
            WHEN drp.validated_required_point_count < drp.required_point_count THEN 'BLOCKED'
            WHEN d.operational_policy = 'ASSET_ASSIGNED'
             AND NOT EXISTS (
                SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id
             ) THEN 'BLOCKED'
            ELSE 'READY'
        END AS commissioning_status,
        (
            d.lifecycle_status = 'ACTIVE'
            OR (
                d.lifecycle_status <> 'DECOMMISSIONED'
                AND d.gateway_id IS NOT NULL
                AND d.device_model_id IS NOT NULL
                AND d.profile_id IS NOT NULL
                AND EXISTS (
                    SELECT 1
                    FROM config.device_profile_categories dpc
                    JOIN metadata.device_models dm ON dm.id = d.device_model_id
                    WHERE dpc.profile_id = d.profile_id
                      AND dpc.device_category_id = dm.device_category_id
                )
                AND drp.validated_required_point_count = drp.required_point_count
                AND (
                    d.operational_policy <> 'ASSET_ASSIGNED'
                    OR EXISTS (
                        SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id
                    )
                )
            )
        ) AS is_ready,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN d.lifecycle_status = 'DECOMMISSIONED' THEN 'DEVICE_DECOMMISSIONED' END,
            CASE WHEN d.gateway_id IS NULL THEN 'GATEWAY_REQUIRED' END,
            CASE WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_REQUIRED' END,
            CASE WHEN d.profile_id IS NULL THEN 'DEVICE_PROFILE_REQUIRED' END,
            CASE
                WHEN d.device_model_id IS NOT NULL
                 AND d.profile_id IS NOT NULL
                 AND NOT EXISTS (
                    SELECT 1
                    FROM config.device_profile_categories dpc
                    JOIN metadata.device_models dm ON dm.id = d.device_model_id
                    WHERE dpc.profile_id = d.profile_id
                      AND dpc.device_category_id = dm.device_category_id
                 )
                THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
            END,
            CASE
                WHEN coalesce(drp.required_point_count, 0) > 0
                 AND drp.validated_required_point_count < drp.required_point_count
                THEN 'REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED'
            END,
            CASE
                WHEN d.operational_policy = 'ASSET_ASSIGNED'
                 AND NOT EXISTS (SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id = d.id)
                THEN 'ASSET_ASSIGNMENT_REQUIRED_BY_POLICY'
            END
        ], NULL)::text[] AS blocking_reason_codes,
        ARRAY[]::text[] AS warning_reason_codes
    FROM metadata.devices d
    LEFT JOIN metadata.gateways g ON g.id = d.gateway_id
    LEFT JOIN device_required_points drp ON drp.device_id = d.id
)
SELECT * FROM asset_readiness
UNION ALL
SELECT * FROM gateway_readiness
UNION ALL
SELECT * FROM device_readiness;



CREATE OR REPLACE FUNCTION admin.get_gateway_workspace
(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, analytics, metadata, telemetry, config
AS $function$
WITH gateway_row AS (
    SELECT
        g.id AS gateway_id,
        g.organization_id,
        o.code AS organization_code,
        o.name AS organization_name,
        g.site_id,
        s.code AS site_code,
        s.name AS site_name,
        g.building_id,
        b.name AS building_name,
        g.floor_id,
        f.name AS floor_name,
        g.space_id,
        sp.name AS space_name,
        g.gateway_model_id,
        gm.vendor AS gateway_vendor,
        gm.model AS gateway_model,
        gm.protocol AS gateway_protocol,
        g.name AS gateway_name,
        g.external_id,
        g.lifecycle_status,
        g.created_at,
        (SELECT count(*) FROM metadata.devices d WHERE d.gateway_id=g.id) AS device_count,
        (SELECT gc.last_seen_at
           FROM analytics.v_gateway_connectivity gc WHERE gc.gateway_id=g.id) AS last_seen_at,
        (SELECT online_threshold_seconds FROM config.gateway_connectivity_policy WHERE policy_id=1) AS threshold
    FROM metadata.gateways g
    JOIN metadata.organizations o ON o.id=g.organization_id
    JOIN metadata.sites s ON s.id=g.site_id
    LEFT JOIN metadata.gateway_models gm ON gm.id=g.gateway_model_id
    LEFT JOIN metadata.buildings b ON b.id=g.building_id
    LEFT JOIN metadata.floors f ON f.id=g.floor_id
    LEFT JOIN metadata.spaces sp ON sp.id=g.space_id
    WHERE g.id=p_gateway_id
      AND admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
)
SELECT jsonb_build_object(
    'gateway_id',gateway_id,'organization_id',organization_id,
    'organization_code',organization_code,'organization_name',organization_name,
    'site_id',site_id,'site_code',site_code,'site_name',site_name,
    'building_id',building_id,'building_name',building_name,
    'floor_id',floor_id,'floor_name',floor_name,'space_id',space_id,'space_name',space_name,
    'gateway_model_id',gateway_model_id,'gateway_vendor',gateway_vendor,
    'gateway_model',gateway_model,'gateway_protocol',gateway_protocol,
    'gateway_name',gateway_name,'external_id',external_id,
    'lifecycle_status',lifecycle_status,'created_at',created_at,
    'device_count',device_count,'last_seen_at',last_seen_at,
    'connectivity_status',CASE WHEN last_seen_at IS NULL THEN 'NEVER_SEEN'
      WHEN last_seen_at >= now()-make_interval(secs=>threshold) THEN 'ONLINE' ELSE 'OFFLINE' END
)
FROM gateway_row;
$function$;


DROP FUNCTION IF EXISTS admin.list_accessible_gateways(BIGINT);
CREATE FUNCTION admin.list_accessible_gateways(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID, organization_code TEXT, organization_name TEXT,
    site_id UUID, site_code TEXT, site_name TEXT,
    gateway_id UUID, gateway_name TEXT, external_id TEXT,
    gateway_model_id UUID, gateway_vendor TEXT, gateway_model TEXT, gateway_protocol TEXT,
    building_id UUID, building_name TEXT, floor_id UUID, floor_name TEXT,
    space_id UUID, space_name TEXT, location_path TEXT,
    lifecycle_status TEXT, connectivity_status TEXT, last_seen_at TIMESTAMPTZ,
    online_threshold_seconds INTEGER, device_count BIGINT
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, analytics, metadata, telemetry, config
AS $function$
WITH policy AS (
    SELECT online_threshold_seconds FROM config.gateway_connectivity_policy WHERE policy_id=1
), last_seen AS (
    SELECT gateway_id,last_seen_at
    FROM analytics.v_gateway_connectivity
)
SELECT g.organization_id,o.code,o.name,g.site_id,s.code,s.name,
       g.id,g.name,g.external_id,g.gateway_model_id,gm.vendor,gm.model,gm.protocol,
       g.building_id,b.name,g.floor_id,f.name,g.space_id,sp.name,
       concat_ws(' / ',o.name,s.name,b.name,f.name,sp.name),
       g.lifecycle_status,
       CASE WHEN ls.last_seen_at IS NULL THEN 'NEVER_SEEN'
            WHEN ls.last_seen_at>=now()-make_interval(secs=>p.online_threshold_seconds) THEN 'ONLINE'
            ELSE 'OFFLINE' END,
       ls.last_seen_at,p.online_threshold_seconds,
       (SELECT count(*) FROM metadata.devices d WHERE d.gateway_id=g.id)
FROM metadata.gateways g
JOIN metadata.organizations o ON o.id=g.organization_id
JOIN metadata.sites s ON s.id=g.site_id
LEFT JOIN metadata.gateway_models gm ON gm.id=g.gateway_model_id
LEFT JOIN metadata.buildings b ON b.id=g.building_id
LEFT JOIN metadata.floors f ON f.id=g.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=g.space_id
CROSS JOIN policy p
LEFT JOIN last_seen ls ON ls.gateway_id=g.id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY o.name,s.name,b.name,f.name,sp.name,g.name,g.lifecycle_status;
$function$;



COMMENT ON VIEW analytics.v_commissioning_readiness IS
'Declarative tenant-scoped readiness for assets, gateways, and devices. Gateway connectivity accepts explicit device-status events or recent mapped telemetry from assigned devices.';

-- Keep ownership and execution boundaries unchanged.
ALTER FUNCTION admin.get_gateway_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_gateways(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_gateway_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_gateways(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_gateway_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_gateways(BIGINT) TO ems_app;
