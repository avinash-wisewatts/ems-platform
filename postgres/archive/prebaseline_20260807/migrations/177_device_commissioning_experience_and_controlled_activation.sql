-- Device commissioning UX support and secure controlled activation repair.
-- Keeps direct ACTIVE transitions blocked while allowing admin.commission_device().

CREATE OR REPLACE FUNCTION metadata.reject_uncommissioned_active_device()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.lifecycle_status = 'ACTIVE'
       AND (TG_OP = 'INSERT' OR OLD.lifecycle_status IS DISTINCT FROM 'ACTIVE')
       AND NOT (
           current_user = 'ems_admin'
           AND current_setting('ems.controlled_device_commissioning_id', TRUE) = NEW.id::text
       )
    THEN
        RAISE EXCEPTION 'Use the controlled commissioning action to activate a device.'
            USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END;
$function$;

DO $migration$
BEGIN
    -- Baseline-only test databases may intentionally omit the portal-user
    -- subsystem. In a full portal database, replace the controlled action.
    IF to_regclass('admin.portal_users') IS NOT NULL
       AND to_regprocedure('admin.portal_user_has_permission(bigint,text)') IS NOT NULL
       AND to_regprocedure('admin.portal_user_can_access_site(bigint,uuid)') IS NOT NULL
    THEN
        EXECUTE $commission$
CREATE OR REPLACE FUNCTION admin.commission_device(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
DECLARE
    v_actor_username TEXT;
    v_site_id UUID;
    v_old_lifecycle TEXT;
    v_readiness BOOLEAN;
    v_blockers TEXT[];
    v_warnings TEXT[];
    v_policy TEXT;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username
    INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id = p_actor_portal_user_id
      AND is_active = TRUE;

    IF NOT FOUND
       OR NOT admin.portal_user_has_permission(
           p_actor_portal_user_id,
           'device.manage'
       )
    THEN
        RAISE EXCEPTION 'Portal actor is not authorized to commission devices.'
            USING ERRCODE = '42501';
    END IF;

    SELECT g.site_id, d.lifecycle_status, d.operational_policy
    INTO v_site_id, v_old_lifecycle, v_policy
    FROM metadata.devices d
    JOIN metadata.gateways g ON g.id = d.gateway_id
    WHERE d.id = p_device_id
    FOR UPDATE OF d;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device was not found.' USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,
        v_site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the selected device.'
            USING ERRCODE = '42501';
    END IF;

    IF v_old_lifecycle = 'ACTIVE' THEN
        RAISE EXCEPTION 'The device is already commissioned.'
            USING ERRCODE = '23514';
    END IF;

    IF v_old_lifecycle = 'DECOMMISSIONED' THEN
        RAISE EXCEPTION 'A decommissioned device cannot be commissioned.'
            USING ERRCODE = '23514';
    END IF;

    SELECT is_ready, blocking_reason_codes, warning_reason_codes
    INTO v_readiness, v_blockers, v_warnings
    FROM analytics.v_commissioning_readiness
    WHERE entity_type = 'DEVICE'
      AND entity_id = p_device_id;

    IF NOT FOUND OR NOT COALESCE(v_readiness, FALSE) THEN
        RAISE EXCEPTION 'Device commissioning is blocked: %',
            array_to_string(
                COALESCE(
                    v_blockers,
                    ARRAY['READINESS_UNAVAILABLE']::TEXT[]
                ),
                ', '
            )
            USING ERRCODE = '23514';
    END IF;

    PERFORM set_config(
        'ems.controlled_device_commissioning_id',
        p_device_id::text,
        TRUE
    );

    UPDATE metadata.devices
    SET lifecycle_status = 'ACTIVE',
        updated_at = now()
    WHERE id = p_device_id;

    PERFORM set_config(
        'ems.controlled_device_commissioning_id',
        '',
        TRUE
    );

    v_result := jsonb_build_object(
        'success', TRUE,
        'entity_type', 'DEVICE',
        'entity_id', p_device_id,
        'device_id', p_device_id,
        'lifecycle_status', 'ACTIVE',
        'commissioning_status', 'COMMISSIONED',
        'validation_warnings',
            to_jsonb(COALESCE(v_warnings, ARRAY[]::TEXT[])),
        'blocking_conditions', '[]'::jsonb,
        'audit_transaction_id', v_audit_id
    );

    INSERT INTO admin.onboarding_audit(
        id,
        requested_by,
        request_payload,
        result_payload
    )
    VALUES (
        v_audit_id,
        v_actor_username,
        jsonb_build_object(
            'operation', 'COMMISSION_DEVICE',
            'device_id', p_device_id,
            'previous_lifecycle_status', v_old_lifecycle,
            'operational_policy', v_policy,
            'readiness_source', 'analytics.v_commissioning_readiness'
        ),
        v_result
    );

    RETURN v_result;
END;
$function$;
$commission$;
    END IF;
END;
$migration$;

ALTER FUNCTION metadata.reject_uncommissioned_active_device()
    OWNER TO ems_admin;
DO $permissions$
BEGIN
    IF to_regprocedure('admin.commission_device(bigint,uuid)') IS NOT NULL THEN
        ALTER FUNCTION admin.commission_device(BIGINT, UUID) OWNER TO ems_admin;
        REVOKE ALL ON FUNCTION admin.commission_device(BIGINT, UUID) FROM PUBLIC;
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
            GRANT EXECUTE ON FUNCTION admin.commission_device(BIGINT, UUID) TO ems_app;
        END IF;
    END IF;
END;
$permissions$;
