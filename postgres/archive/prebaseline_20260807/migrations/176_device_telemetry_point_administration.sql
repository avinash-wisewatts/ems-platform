-- Device telemetry-point administration API.
-- Migration 175 owns the device-level enabled/disabled configuration table.



-- --------------------------------------------------------------------------
-- Authorization adapters
--
-- Some baseline-only validation databases record historical portal migrations
-- without materializing the portal authentication tables/functions. These
-- adapters use dynamic SQL so this migration can compile there while remaining
-- fail-closed. In production they delegate to the canonical portal APIs.
-- --------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.device_point_actor_username(
    p_actor_portal_user_id BIGINT
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_username TEXT;
BEGIN
    IF to_regclass('admin.portal_users') IS NULL THEN
        RAISE EXCEPTION
            'Portal authentication infrastructure is unavailable.'
            USING ERRCODE = '55000';
    END IF;

    EXECUTE
        'SELECT username
           FROM admin.portal_users
          WHERE portal_user_id = $1
            AND is_active = TRUE'
    INTO v_username
    USING p_actor_portal_user_id;

    RETURN v_username;
END;
$function$;


CREATE OR REPLACE FUNCTION admin.device_point_actor_has_permission(
    p_actor_portal_user_id BIGINT,
    p_permission_code TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_allowed BOOLEAN := FALSE;
BEGIN
    IF to_regprocedure(
        'admin.portal_user_has_permission(bigint,text)'
    ) IS NULL THEN
        RETURN FALSE;
    END IF;

    EXECUTE
        'SELECT admin.portal_user_has_permission($1, $2)'
    INTO v_allowed
    USING p_actor_portal_user_id, p_permission_code;

    RETURN COALESCE(v_allowed, FALSE);
END;
$function$;


CREATE OR REPLACE FUNCTION admin.device_point_actor_can_access_site(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin
AS $function$
DECLARE
    v_allowed BOOLEAN := FALSE;
BEGIN
    IF to_regprocedure(
        'admin.portal_user_can_access_site(bigint,uuid)'
    ) IS NULL THEN
        RETURN FALSE;
    END IF;

    EXECUTE
        'SELECT admin.portal_user_can_access_site($1, $2)'
    INTO v_allowed
    USING p_actor_portal_user_id, p_site_id;

    RETURN COALESCE(v_allowed, FALSE);
END;
$function$;


ALTER FUNCTION admin.device_point_actor_username(BIGINT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.device_point_actor_has_permission(BIGINT, TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.device_point_actor_can_access_site(BIGINT, UUID)
    OWNER TO ems_admin;

REVOKE ALL
ON FUNCTION admin.device_point_actor_username(BIGINT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.device_point_actor_has_permission(BIGINT, TEXT)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION admin.device_point_actor_can_access_site(BIGINT, UUID)
FROM PUBLIC;


CREATE OR REPLACE FUNCTION admin.list_device_point_configuration(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID
)
RETURNS TABLE(
    logical_point_id UUID,
    logical_point_name TEXT,
    logical_point_description TEXT,
    engineering_unit TEXT,
    data_type TEXT,
    raw_field_name TEXT,
    mapping_source TEXT,
    display_order INTEGER,
    is_enabled BOOLEAN
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
WITH accessible_device AS (
    SELECT d.id, d.profile_id
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.id = p_device_id
      AND admin.device_point_actor_can_access_site(
          p_actor_portal_user_id,
          g.site_id
      )
), candidate_mappings AS (
    SELECT
        pfm.logical_point_id,
        pfm.raw_field_name,
        'DEVICE_PROFILE'::TEXT AS mapping_source,
        pfm.display_order,
        1 AS mapping_priority
    FROM accessible_device ad
    JOIN config.profile_field_mapping pfm
      ON pfm.profile_id = ad.profile_id

    UNION ALL

    SELECT
        dfm.logical_point_id,
        dfm.raw_field_name,
        'DEVICE_OVERRIDE'::TEXT AS mapping_source,
        0 AS display_order,
        2 AS mapping_priority
    FROM accessible_device ad
    JOIN metadata.device_field_mapping dfm
      ON dfm.device_id = ad.id
), preferred_mappings AS (
    SELECT DISTINCT ON (cm.logical_point_id)
        cm.logical_point_id,
        cm.raw_field_name,
        cm.mapping_source,
        cm.display_order
    FROM candidate_mappings cm
    ORDER BY cm.logical_point_id, cm.mapping_priority
)
SELECT
    lp.id,
    lp.name,
    lp.description,
    eu.symbol,
    lp.data_type,
    pm.raw_field_name,
    pm.mapping_source,
    pm.display_order,
    dpc.is_enabled
FROM accessible_device ad
JOIN config.device_point_configuration dpc
  ON dpc.device_id = ad.id
JOIN preferred_mappings pm
  ON pm.logical_point_id = dpc.logical_point_id
JOIN metadata.logical_points lp
  ON lp.id = dpc.logical_point_id
LEFT JOIN config.engineering_units eu
  ON eu.id = lp.unit_id
ORDER BY pm.display_order, lp.name;
$function$;

COMMENT ON FUNCTION admin.list_device_point_configuration(BIGINT, UUID) IS
'Returns the explicit enabled/disabled telemetry-point contract for one device when the actor can access its site.';


CREATE OR REPLACE FUNCTION admin.update_device_point_configuration(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID,
    p_enabled_logical_point_ids UUID[],
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_device_name TEXT;
    v_site_id UUID;
    v_reason TEXT := NULLIF(btrim(p_change_reason), '');
    v_enabled_ids UUID[] := COALESCE(p_enabled_logical_point_ids, ARRAY[]::UUID[]);
    v_unknown_count INTEGER;
    v_before JSONB;
    v_after JSONB;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    v_actor_username :=
        admin.device_point_actor_username(
            p_actor_portal_user_id
        );

    IF v_actor_username IS NULL
       OR NOT admin.device_point_actor_has_permission(
           p_actor_portal_user_id,
           'device.manage'
       )
    THEN
        RAISE EXCEPTION
            'Portal actor is not authorized to manage device telemetry points.'
            USING ERRCODE = '42501';
    END IF;

    SELECT d.name, g.site_id
    INTO v_device_name, v_site_id
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.id = p_device_id
    FOR UPDATE OF d;

    IF NOT FOUND OR NOT admin.device_point_actor_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION
            'Portal actor cannot access this device.'
            USING ERRCODE = '42501';
    END IF;

    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'Change reason is required.'
            USING ERRCODE = '22023';
    END IF;

    IF length(v_reason) > 1000 THEN
        RAISE EXCEPTION
            'Change reason must not exceed 1000 characters.'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*)
    INTO v_unknown_count
    FROM unnest(v_enabled_ids) selected(logical_point_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM config.device_point_configuration dpc
        WHERE dpc.device_id = p_device_id
          AND dpc.logical_point_id = selected.logical_point_id
    );

    IF v_unknown_count > 0 THEN
        RAISE EXCEPTION
            'One or more selected telemetry points do not belong to this device.'
            USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'logical_point_id', dpc.logical_point_id,
            'is_enabled', dpc.is_enabled
        )
        ORDER BY dpc.logical_point_id
    )
    INTO v_before
    FROM config.device_point_configuration dpc
    WHERE dpc.device_id = p_device_id;

    UPDATE config.device_point_configuration dpc
    SET is_enabled = dpc.logical_point_id = ANY(v_enabled_ids)
    WHERE dpc.device_id = p_device_id
      AND dpc.is_enabled IS DISTINCT FROM
          (dpc.logical_point_id = ANY(v_enabled_ids));

    SELECT jsonb_agg(
        jsonb_build_object(
            'logical_point_id', dpc.logical_point_id,
            'is_enabled', dpc.is_enabled
        )
        ORDER BY dpc.logical_point_id
    )
    INTO v_after
    FROM config.device_point_configuration dpc
    WHERE dpc.device_id = p_device_id;

    v_result := jsonb_build_object(
        'success', TRUE,
        'device_id', p_device_id,
        'device_name', v_device_name,
        'enabled_point_count', (
            SELECT count(*)
            FROM config.device_point_configuration dpc
            WHERE dpc.device_id = p_device_id
              AND dpc.is_enabled
        ),
        'configured_point_count', (
            SELECT count(*)
            FROM config.device_point_configuration dpc
            WHERE dpc.device_id = p_device_id
        ),
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(
        id,
        requested_by,
        request_payload,
        result_payload
    ) VALUES (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'UPDATE_DEVICE_POINT_CONFIGURATION',
            'actor_portal_user_id', p_actor_portal_user_id,
            'device_id', p_device_id,
            'site_id', v_site_id,
            'change_reason', v_reason,
            'before', COALESCE(v_before, '[]'::JSONB),
            'after', COALESCE(v_after, '[]'::JSONB)
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;

COMMENT ON FUNCTION admin.update_device_point_configuration(BIGINT, UUID, UUID[], TEXT) IS
'Replaces the enabled telemetry-point set for one accessible device and writes an audit record. Empty UUID arrays intentionally disable all points.';


CREATE OR REPLACE FUNCTION admin.reset_device_point_configuration(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID,
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_all_point_ids UUID[];
BEGIN
    SELECT COALESCE(array_agg(dpc.logical_point_id), ARRAY[]::UUID[])
    INTO v_all_point_ids
    FROM config.device_point_configuration dpc
    WHERE dpc.device_id = p_device_id;

    RETURN admin.update_device_point_configuration(
        p_actor_portal_user_id,
        p_device_id,
        v_all_point_ids,
        p_change_reason
    );
END;
$function$;

COMMENT ON FUNCTION admin.reset_device_point_configuration(BIGINT, UUID, TEXT) IS
'Enables all points in the device configuration previously synchronized from its current profile and device mappings, then records the audited change.';

ALTER FUNCTION admin.list_device_point_configuration(BIGINT, UUID)
    OWNER TO ems_admin;
ALTER FUNCTION admin.update_device_point_configuration(BIGINT, UUID, UUID[], TEXT)
    OWNER TO ems_admin;
ALTER FUNCTION admin.reset_device_point_configuration(BIGINT, UUID, TEXT)
    OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.list_device_point_configuration(BIGINT, UUID)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_device_point_configuration(BIGINT, UUID, UUID[], TEXT)
    FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.reset_device_point_configuration(BIGINT, UUID, TEXT)
    FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.list_device_point_configuration(BIGINT, UUID)
    TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_device_point_configuration(BIGINT, UUID, UUID[], TEXT)
    TO ems_app;
GRANT EXECUTE ON FUNCTION admin.reset_device_point_configuration(BIGINT, UUID, TEXT)
    TO ems_app;
