-- Epic 11 Stories 11.1-11.3: telemetry availability and validation.

CREATE TABLE IF NOT EXISTS config.telemetry_availability_policy (
    policy_key TEXT PRIMARY KEY,
    receiving_threshold_seconds INTEGER NOT NULL CHECK (receiving_threshold_seconds > 0),
    stale_threshold_seconds INTEGER NOT NULL CHECK (stale_threshold_seconds > receiving_threshold_seconds),
    silent_threshold_seconds INTEGER NOT NULL CHECK (silent_threshold_seconds > stale_threshold_seconds),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO config.telemetry_availability_policy(
    policy_key, receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds
) VALUES ('DEFAULT', 300, 900, 3600)
ON CONFLICT (policy_key) DO NOTHING;

-- Existing idx_norm_device_time already supports
-- (device_id, event_time DESC); do not create a duplicate index.
CREATE INDEX IF NOT EXISTS idx_normalized_points_device_received_time
    ON telemetry.normalized_points(device_id, created_at DESC);

CREATE OR REPLACE VIEW analytics.v_device_telemetry_availability
WITH (security_barrier = TRUE)
AS
WITH policy AS (
    SELECT receiving_threshold_seconds, stale_threshold_seconds, silent_threshold_seconds
    FROM config.telemetry_availability_policy
    WHERE policy_key = 'DEFAULT'
),
profile_mapping AS (
    SELECT profile_id, count(*) AS mapped_point_count,
           count(*) FILTER (WHERE is_required) AS required_point_count
    FROM config.profile_field_mapping
    GROUP BY profile_id
),
telemetry_rollup AS (
    SELECT
        np.device_id,
        max(np.event_time) AS latest_source_timestamp,
        max(np.created_at) AS latest_received_timestamp,
        max(np.event_time) FILTER (
            WHERE coalesce(np.quality_code, 'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC')
              AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value), '') IS NOT NULL)
        ) AS latest_valid_source_timestamp,
        max(np.created_at) FILTER (
            WHERE coalesce(np.quality_code, 'GOOD') NOT IN ('INVALID','REJECTED','INVALID_NUMERIC')
              AND (np.numeric_value IS NOT NULL OR nullif(btrim(np.raw_value), '') IS NOT NULL)
        ) AS latest_valid_received_timestamp
    FROM telemetry.normalized_points np
    GROUP BY np.device_id
),
asset_association AS (
    SELECT ad.device_id,
           string_agg(DISTINCT a.name, ', ' ORDER BY a.name) AS associated_asset_names
    FROM metadata.asset_devices ad
    JOIN metadata.assets a ON a.id = ad.asset_id
    GROUP BY ad.device_id
)
SELECT
    d.organization_id,
    g.site_id,
    s.name AS site_name,
    g.id AS gateway_id,
    g.name AS gateway_name,
    d.id AS device_id,
    d.name AS device_name,
    d.external_id,
    d.lifecycle_status,
    d.profile_id,
    dp.profile_code AS profile_code,
    coalesce(aa.associated_asset_names, '—') AS associated_asset_names,
    CASE
        WHEN d.profile_id IS NULL OR d.device_model_id IS NULL THEN 'INVALID_PROFILE'
        WHEN NOT EXISTS (
            SELECT 1
            FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id = d.device_model_id
            WHERE dpc.profile_id = d.profile_id
              AND dpc.device_category_id = dm.device_category_id
        ) THEN 'INVALID_PROFILE'
        WHEN coalesce(pm.mapped_point_count, 0) = 0 THEN 'UNMAPPED'
        ELSE 'VALIDATED'
    END AS configuration_state,
    CASE
        -- Telemetry health is evaluated independently from configuration.
        WHEN tr.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'
        WHEN tr.latest_received_timestamp
             < now() - make_interval(secs => p.silent_threshold_seconds)
        THEN 'SILENT'
        WHEN d.profile_id IS NULL
          OR d.device_model_id IS NULL
          OR coalesce(pm.mapped_point_count, 0) = 0
          OR NOT EXISTS (
                SELECT 1
                FROM config.device_profile_categories dpc
                JOIN metadata.device_models dm
                  ON dm.id = d.device_model_id
                WHERE dpc.profile_id = d.profile_id
                  AND dpc.device_category_id = dm.device_category_id
          )
        THEN 'INVALID_PROFILE'
        WHEN d.operational_policy = 'ASSET_ASSIGNED'
         AND NOT EXISTS (
                SELECT 1
                FROM metadata.asset_devices ad
                WHERE ad.device_id = d.id
         )
        THEN 'UNMAPPED'
        WHEN tr.latest_valid_source_timestamp IS NULL THEN 'RECEIVING'
        WHEN tr.latest_valid_source_timestamp
             < now() - make_interval(secs => p.stale_threshold_seconds)
        THEN 'STALE'
        WHEN tr.latest_valid_received_timestamp
             >= now() - make_interval(secs => p.receiving_threshold_seconds)
        THEN 'VALIDATED'
        ELSE 'RECEIVING'
    END AS telemetry_state,
    tr.latest_source_timestamp,
    tr.latest_received_timestamp,
    tr.latest_valid_source_timestamp,
    tr.latest_valid_received_timestamp,
    CASE
        WHEN d.profile_id IS NULL THEN 'PROFILE_MISSING'
        WHEN d.device_model_id IS NULL THEN 'DEVICE_MODEL_MISSING'
        WHEN NOT EXISTS (
            SELECT 1
            FROM config.device_profile_categories dpc
            JOIN metadata.device_models dm ON dm.id = d.device_model_id
            WHERE dpc.profile_id = d.profile_id
              AND dpc.device_category_id = dm.device_category_id
        ) THEN 'PROFILE_CATEGORY_INCOMPATIBLE'
        WHEN coalesce(pm.mapped_point_count, 0) = 0 THEN 'PROFILE_UNMAPPED'
        ELSE 'PROFILE_VALID'
    END AS profile_validation_result,
    coalesce(pm.mapped_point_count, 0)::BIGINT AS mapped_point_count,
    coalesce(pm.required_point_count, 0)::BIGINT AS required_point_count,
    p.receiving_threshold_seconds,
    p.stale_threshold_seconds,
    p.silent_threshold_seconds
FROM metadata.devices d
JOIN metadata.gateways g ON g.id = d.gateway_id
JOIN metadata.sites s ON s.id = g.site_id
LEFT JOIN config.device_profiles dp ON dp.id = d.profile_id
LEFT JOIN profile_mapping pm ON pm.profile_id = d.profile_id
LEFT JOIN telemetry_rollup tr ON tr.device_id = d.id
LEFT JOIN asset_association aa ON aa.device_id = d.id
CROSS JOIN policy p;

COMMENT ON VIEW analytics.v_device_telemetry_availability IS
'Latest source and received telemetry timestamps, configuration health, and declarative telemetry availability per device. Source and receive maxima are independent so late arrivals remain traceable without corrupting true last-seen logic.';

CREATE OR REPLACE FUNCTION admin.list_accessible_device_telemetry_availability(
    p_actor_portal_user_id BIGINT,
    p_organization_id UUID DEFAULT NULL,
    p_site_id UUID DEFAULT NULL,
    p_telemetry_state TEXT DEFAULT NULL
)
RETURNS TABLE (
    organization_id UUID, site_id UUID, site_name TEXT,
    gateway_id UUID, gateway_name TEXT,
    device_id UUID, device_name TEXT, external_id TEXT,
    lifecycle_status TEXT, profile_id UUID, profile_code TEXT,
    associated_asset_names TEXT, configuration_state TEXT, telemetry_state TEXT,
    latest_source_timestamp TIMESTAMPTZ, latest_received_timestamp TIMESTAMPTZ,
    latest_valid_source_timestamp TIMESTAMPTZ, latest_valid_received_timestamp TIMESTAMPTZ,
    profile_validation_result TEXT, mapped_point_count BIGINT, required_point_count BIGINT,
    receiving_threshold_seconds INTEGER, stale_threshold_seconds INTEGER, silent_threshold_seconds INTEGER
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, analytics
AS $function$
SELECT
    v.organization_id, v.site_id, v.site_name,
    v.gateway_id, v.gateway_name,
    v.device_id, v.device_name, v.external_id,
    v.lifecycle_status, v.profile_id, v.profile_code,
    v.associated_asset_names, v.configuration_state, v.telemetry_state,
    v.latest_source_timestamp, v.latest_received_timestamp,
    v.latest_valid_source_timestamp, v.latest_valid_received_timestamp,
    v.profile_validation_result, v.mapped_point_count, v.required_point_count,
    v.receiving_threshold_seconds, v.stale_threshold_seconds, v.silent_threshold_seconds
FROM analytics.v_device_telemetry_availability v
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id, v.site_id)
  AND (p_organization_id IS NULL OR v.organization_id = p_organization_id)
  AND (p_site_id IS NULL OR v.site_id = p_site_id)
  AND (p_telemetry_state IS NULL OR v.telemetry_state = upper(btrim(p_telemetry_state)))
ORDER BY v.site_name, v.gateway_name, v.device_name;
$function$;

ALTER VIEW analytics.v_device_telemetry_availability OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_device_telemetry_availability(BIGINT,UUID,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON analytics.v_device_telemetry_availability FROM PUBLIC;
REVOKE ALL ON analytics.v_device_telemetry_availability FROM ems_app;
REVOKE ALL ON FUNCTION admin.list_accessible_device_telemetry_availability(BIGINT,UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.list_accessible_device_telemetry_availability(BIGINT,UUID,UUID,TEXT) TO ems_app;
