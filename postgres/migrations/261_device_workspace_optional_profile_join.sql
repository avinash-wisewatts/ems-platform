-- ============================================================================
-- Migration 261
-- admin.get_device_workspace() query-correctness fix -- an unprofiled
-- device is a valid pre-commissioning state (ADR-018 Amendment 1: Device
-- Commissioning is a distinct, later stage from device existence;
-- metadata.devices.profile_id is nullable by design), so it must remain
-- visible to an authorized caller instead of silently disappearing.
--
-- Root cause (confirmed this session, read-only, before this migration):
-- the function's FROM clause used
--     JOIN config.device_profiles dp ON dp.id = d.profile_id
-- an INNER JOIN against a nullable column. For any device with
-- profile_id IS NULL, this eliminates the row entirely, BEFORE the
-- function's own access predicate (admin.portal_user_can_access_site) is
-- even evaluated -- so the symptom looks exactly like an authorization
-- denial (an authorized actor, including a GLOBAL-scope ADMIN, sees no
-- device) when it is actually a query-shape bug reachable by every actor,
-- every role, every scope, for every not-yet-profiled device. Verified
-- directly this session: admin.portal_user_can_access_site(actor, site)
-- returns TRUE for the exact case that nonetheless got dropped.
--
-- Confirmed by contrast against the working sibling function, admin.
-- get_asset_workspace: every genuinely optional relationship there
-- (asset_type, parent_asset, building/floor/space, coverage, readiness)
-- is already a LEFT JOIN; only the required, NOT NULL organization_id/
-- site_id foreign keys are INNER JOINs. admin.get_device_workspace broke
-- that same pattern for exactly one relationship -- device_profiles --
-- which this migration corrects to match.
--
-- Scope, explicit and minimal: exactly one token changed,
-- "JOIN config.device_profiles dp" -> "LEFT JOIN config.device_profiles dp".
-- Every other line -- the CTE's other joins, every selected column
-- (dp.profile_code/dp.profile_name now read NULL instead of failing to
-- exist at all for an unprofiled device, exactly as every other optional
-- LEFT-JOINed column already behaves), the WHERE clause's access
-- predicate (admin.portal_user_can_access_site, unchanged), the
-- function's signature, return type, LANGUAGE, STABLE/SECURITY DEFINER
-- attributes, and search_path -- is byte-identical to the function as
-- currently deployed. No permission/grant change: CREATE OR REPLACE with
-- an identical signature preserves existing ACLs (confirmed before this
-- migration: PUBLIC has no EXECUTE, ems_app does), so this migration does
-- not re-issue REVOKE/GRANT.
--
-- Explicitly NOT in this migration: no change to metadata.devices,
-- config.device_profiles, or any other table/data; no change to the local
-- Banquet AHU Meter profile assignment approved and applied in the prior
-- session step; no change to admin.get_asset_workspace or any other
-- function; no staging or production deployment.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin.get_device_workspace(p_actor_portal_user_id bigint, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'admin', 'metadata', 'config', 'analytics'
AS $function$
WITH device_row AS (
    SELECT
        d.id AS device_id,d.organization_id,o.code AS organization_code,o.name AS organization_name,
        g.site_id,s.code AS site_code,s.name AS site_name,d.gateway_id,g.name AS gateway_name,
        g.external_id AS gateway_external_id,d.location_mode,
        d.building_id AS explicit_building_id,db.name AS explicit_building_name,
        d.floor_id AS explicit_floor_id,df.name AS explicit_floor_name,
        d.space_id AS explicit_space_id,ds.name AS explicit_space_name,
        g.building_id AS gateway_building_id,gb.name AS gateway_building_name,
        g.floor_id AS gateway_floor_id,gf.name AS gateway_floor_name,
        g.space_id AS gateway_space_id,gs.name AS gateway_space_name,
        CASE WHEN d.location_mode='GATEWAY' THEN g.building_id ELSE d.building_id END AS building_id,
        CASE WHEN d.location_mode='GATEWAY' THEN gb.name ELSE db.name END AS building_name,
        CASE WHEN d.location_mode='GATEWAY' THEN g.floor_id ELSE d.floor_id END AS floor_id,
        CASE WHEN d.location_mode='GATEWAY' THEN gf.name ELSE df.name END AS floor_name,
        CASE WHEN d.location_mode='GATEWAY' THEN g.space_id ELSE d.space_id END AS space_id,
        CASE WHEN d.location_mode='GATEWAY' THEN gs.name ELSE ds.name END AS space_name,
        concat_ws(' / ',o.name,s.name,
          CASE WHEN d.location_mode='GATEWAY' THEN gb.name ELSE db.name END,
          CASE WHEN d.location_mode='GATEWAY' THEN gf.name ELSE df.name END,
          CASE WHEN d.location_mode='GATEWAY' THEN gs.name ELSE ds.name END) AS location_path,
        concat_ws(' / ',o.name,s.name,gb.name,gf.name,gs.name) AS gateway_location_path,
        concat_ws(' / ',o.name,s.name,db.name,df.name,ds.name) AS explicit_location_path,
        d.device_model_id,dm.device_category_id,dc.name AS device_category_name,
        dm.vendor AS device_vendor,dm.model AS device_model,d.profile_id,
        dp.profile_code,dp.profile_name,d.name AS device_name,d.external_id,
        d.serial_number,d.firmware_version,d.protocol,d.lifecycle_status,
        d.operational_policy,d.created_at,d.updated_at,
        ident.identifier_type,ident.identifier_value,
        tv.telemetry_state,tv.configuration_state,tv.profile_validation_result,
        tv.latest_source_timestamp,tv.latest_received_timestamp,
        tv.latest_valid_source_timestamp,tv.latest_valid_received_timestamp,
        tv.mapped_point_count,tv.required_point_count,
        cr.commissioning_status,cr.is_ready,cr.blocking_reason_codes,cr.warning_reason_codes,
        (SELECT count(*) FROM metadata.asset_devices ad WHERE ad.device_id=d.id) AS relationship_count
    FROM metadata.devices d
    JOIN metadata.organizations o ON o.id=d.organization_id
    JOIN metadata.gateways g ON g.id=d.gateway_id
    JOIN metadata.sites s ON s.id=g.site_id
    JOIN metadata.device_models dm ON dm.id=d.device_model_id
    JOIN config.device_categories dc ON dc.id=dm.device_category_id
    LEFT JOIN config.device_profiles dp ON dp.id=d.profile_id
    LEFT JOIN metadata.buildings db ON db.id=d.building_id
    LEFT JOIN metadata.floors df ON df.id=d.floor_id
    LEFT JOIN metadata.spaces ds ON ds.id=d.space_id
    LEFT JOIN metadata.buildings gb ON gb.id=g.building_id
    LEFT JOIN metadata.floors gf ON gf.id=g.floor_id
    LEFT JOIN metadata.spaces gs ON gs.id=g.space_id
    LEFT JOIN LATERAL (
        SELECT di.identifier_type,di.identifier_value
        FROM metadata.device_identifiers di WHERE di.device_id=d.id
        ORDER BY CASE WHEN di.identifier_type='MQTT_UID' THEN 0 ELSE 1 END,di.created_at
        LIMIT 1
    ) ident ON TRUE
    LEFT JOIN analytics.v_device_telemetry_availability tv ON tv.device_id=d.id
    LEFT JOIN analytics.v_commissioning_readiness cr
      ON cr.entity_type='DEVICE' AND cr.entity_id=d.id
    WHERE d.id=p_device_id
      AND admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
)
SELECT to_jsonb(device_row) FROM device_row;
$function$;

COMMENT ON FUNCTION admin.get_device_workspace(BIGINT, UUID) IS
'Migration 261: profile_id is nullable on metadata.devices (a device may legitimately exist before Device Commissioning assigns it a profile, ADR-018 Amendment 1) -- device_profiles is joined with LEFT JOIN so such a device remains visible to an authorized caller, matching how every other optional relationship here (building/floor/space, telemetry availability, commissioning readiness) is already joined. profile_code/profile_name read NULL for an unprofiled device. Access predicate (admin.portal_user_can_access_site) and every other column/join are unchanged from the prior version.';


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    v_def TEXT;
BEGIN
    IF to_regprocedure('admin.get_device_workspace(bigint,uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: admin.get_device_workspace(bigint,uuid) does not exist.';
    END IF;

    v_def := pg_get_functiondef('admin.get_device_workspace(bigint,uuid)'::regprocedure);

    IF position('LEFT JOIN config.device_profiles dp' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: device_profiles is not LEFT JOINed.';
    END IF;
    IF v_def ~ '(?<!LEFT )JOIN config\.device_profiles' THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: an unqualified JOIN to device_profiles is still present.';
    END IF;
    IF position('admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: the access predicate was altered or removed.';
    END IF;

    -- ACLs must be exactly as they were before this migration (PUBLIC
    -- revoked, ems_app granted) -- CREATE OR REPLACE with an unchanged
    -- signature preserves them; this asserts that held.
    IF has_function_privilege('public', 'admin.get_device_workspace(bigint,uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: admin.get_device_workspace is executable by PUBLIC.';
    END IF;
    IF NOT has_function_privilege('ems_app', 'admin.get_device_workspace(bigint,uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 261 postcondition failed: admin.get_device_workspace is not executable by ems_app.';
    END IF;

    RAISE NOTICE 'Migration 261: all postconditions passed (device_profiles now LEFT JOINed; access predicate and grants unchanged).';
END;
$post$;
