-- 016_asset_dashboard_runtime_fix.sql
-- Fix Grafana runtime permissions and eliminate historical telemetry scans from
-- Asset Dashboard telemetry/alarm/device context reads.

-- ---------------------------------------------------------------------------
-- 1. Grafana-safe resolver execution.
--
-- These functions were deliberately granted EXECUTE to grafana_reader but were
-- SECURITY INVOKER. Their bodies read config schema objects, which caused
-- "permission denied for schema config" at dashboard runtime. Keep config
-- tables private and execute only the fixed, non-dynamic resolver code with the
-- ems_admin owner's privileges.
-- ---------------------------------------------------------------------------

ALTER FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
    SECURITY DEFINER;
ALTER FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
    SET search_path TO pg_catalog, config, metadata;

ALTER FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
    SECURITY DEFINER;
ALTER FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
    SET search_path TO pg_catalog, analytics, config, metadata;

ALTER FUNCTION telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ)
    SECURITY DEFINER;
ALTER FUNCTION telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ)
    SET search_path TO pg_catalog, telemetry, config, metadata;

REVOKE ALL ON FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION config.resolve_device_demand_method(UUID, TEXT, INTEGER)
TO ems_readonly, grafana_reader;
GRANT EXECUTE ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ)
TO ems_readonly, grafana_reader;
GRANT EXECUTE ON FUNCTION telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ)
TO ems_admin, ems_app, ems_readonly, grafana_reader;

COMMENT ON FUNCTION analytics.resolve_demand_capability(UUID, TEXT, UUID, TIMESTAMPTZ) IS
'Owner-rights capability resolver with fixed search_path. Exposes only the canonical demand capability contract; callers do not receive direct config-schema access.';

COMMENT ON FUNCTION telemetry.resolve_site_capture_bucket(UUID, TIMESTAMPTZ) IS
'Owner-rights capture-policy resolver with fixed search_path. Allows approved telemetry/analytics readers to resolve effective capture buckets without direct config-schema access.';

-- ---------------------------------------------------------------------------
-- 2. Fast asset-device telemetry context.
--
-- The legacy Grafana view joined analytics.v_grafana_devices, whose original
-- implementation grouped the entire normalized_points history on every query.
-- The telemetry performance work already maintains compact
-- telemetry.device_telemetry_state. v_device_telemetry_availability is backed by
-- that compact state; use it here instead of rescanning historical telemetry.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_grafana_asset_devices
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    a.organization_id,
    a.site_id,
    s.name AS site_name,
    a.id AS asset_id,
    a.name AS asset_name,
    ad.device_id,
    d.name AS device_name,
    d.external_id AS device_external_id,
    ad.relationship_type,
    d.lifecycle_status AS device_lifecycle_status,
    dta.telemetry_state,
    dta.latest_received_timestamp
FROM metadata.grafana_organization_map AS gom
JOIN metadata.assets AS a
  ON a.organization_id = gom.organization_id
JOIN metadata.sites AS s
  ON s.id = a.site_id
JOIN metadata.asset_devices AS ad
  ON ad.asset_id = a.id
JOIN metadata.devices AS d
  ON d.id = ad.device_id
LEFT JOIN analytics.v_device_telemetry_availability AS dta
  ON dta.device_id = d.id
 AND dta.organization_id = a.organization_id
 AND dta.site_id = a.site_id
WHERE gom.is_active = TRUE;

COMMENT ON VIEW analytics.v_grafana_asset_devices IS
'Grafana-safe asset/device assignment and compact telemetry state. Does not scan normalized telemetry history.';

-- ---------------------------------------------------------------------------
-- 3. Fast active-alarm feed.
--
-- Telemetry alarms also used analytics.v_grafana_devices and therefore paid the
-- full normalized_points history scan. Resolve telemetry alarm state from the
-- compact availability view instead.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_grafana_active_alarms
WITH (security_barrier = TRUE)
AS
WITH latest_asset_health AS (
    SELECT DISTINCT ON (ah.asset_id) ah.*
    FROM telemetry.asset_health AS ah
    WHERE ah.asset_id IS NOT NULL
    ORDER BY ah.asset_id, ah.received_at DESC, ah.id DESC
),
asset_alarms AS (
    SELECT
        gom.grafana_org_id,
        ah.organization_id,
        ah.site_id,
        'ASSET_ALARM:' || ah.asset_id::text AS alarm_key,
        'ASSET'::text AS entity_type,
        ah.asset_id AS entity_id,
        a.name AS entity_name,
        COALESCE(NULLIF(ah.alarm_code,''), NULLIF(ah.fault_code,''), 'ASSET_ALARM') AS alarm_code,
        'HIGH'::text AS severity,
        'ACTIVE'::text AS alarm_state,
        COALESCE(NULLIF(ah.operating_state,''), 'Asset alarm signal is active') AS alarm_message,
        ah.received_at AS detected_at,
        ah.received_at AS last_observed_at,
        NULL::uuid AS device_id,
        ah.asset_id
    FROM latest_asset_health AS ah
    JOIN metadata.grafana_organization_map AS gom
      ON gom.organization_id = ah.organization_id
     AND gom.is_active
    LEFT JOIN metadata.assets AS a
      ON a.id = ah.asset_id
    WHERE ah.alarm_active IS TRUE
       OR NULLIF(ah.fault_code,'') IS NOT NULL
),
telemetry_alarms AS (
    SELECT
        gom.grafana_org_id,
        va.organization_id,
        va.site_id,
        'DEVICE_TELEMETRY:' || va.device_id::text AS alarm_key,
        'DEVICE'::text AS entity_type,
        va.device_id AS entity_id,
        va.device_name AS entity_name,
        va.telemetry_state AS alarm_code,
        CASE va.telemetry_state
          WHEN 'SILENT' THEN 'CRITICAL'
          WHEN 'NEVER_SEEN' THEN 'HIGH'
          WHEN 'INVALID_PROFILE' THEN 'HIGH'
          WHEN 'STALE' THEN 'MEDIUM'
          ELSE 'LOW'
        END AS severity,
        'ACTIVE'::text AS alarm_state,
        CASE va.telemetry_state
          WHEN 'SILENT' THEN 'No telemetry within the configured silent threshold.'
          WHEN 'NEVER_SEEN' THEN 'The device has never produced normalized telemetry.'
          WHEN 'INVALID_PROFILE' THEN 'The device profile or mapping is invalid.'
          WHEN 'STALE' THEN 'Telemetry is older than the configured stale threshold.'
          WHEN 'UNMAPPED' THEN 'The device is not correctly mapped or assigned.'
          ELSE 'Telemetry is not in the validated state.'
        END AS alarm_message,
        COALESCE(va.latest_received_timestamp, d.created_at) AS detected_at,
        va.latest_received_timestamp AS last_observed_at,
        va.device_id,
        NULL::uuid AS asset_id
    FROM analytics.v_device_telemetry_availability AS va
    JOIN metadata.grafana_organization_map AS gom
      ON gom.organization_id = va.organization_id
     AND gom.is_active
    JOIN metadata.devices AS d
      ON d.id = va.device_id
    WHERE va.telemetry_state IN ('SILENT','NEVER_SEEN','INVALID_PROFILE','STALE','UNMAPPED')
)
SELECT * FROM asset_alarms
UNION ALL
SELECT * FROM telemetry_alarms;

COMMENT ON VIEW analytics.v_grafana_active_alarms IS
'Grafana-safe active alarm feed using compact telemetry state instead of normalized history scans. Asset alarms remain explicit routed asset-health signals.';

ALTER VIEW analytics.v_grafana_asset_devices OWNER TO ems_admin;
ALTER VIEW analytics.v_grafana_active_alarms OWNER TO ems_admin;

REVOKE ALL ON analytics.v_grafana_asset_devices FROM PUBLIC;
REVOKE ALL ON analytics.v_grafana_active_alarms FROM PUBLIC;

GRANT SELECT ON analytics.v_grafana_asset_devices TO ems_app, ems_readonly, grafana_reader;
GRANT SELECT ON analytics.v_grafana_active_alarms TO ems_app, ems_readonly, grafana_reader;
