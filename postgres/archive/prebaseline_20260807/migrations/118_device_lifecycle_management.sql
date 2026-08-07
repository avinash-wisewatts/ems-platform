-- Epic 7: controlled device lifecycle management (Story 7.4)

CREATE OR REPLACE FUNCTION admin.update_device_lifecycle(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID,
    p_lifecycle_status TEXT,
    p_change_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_device metadata.devices%ROWTYPE;
    v_gateway_site_id UUID;
    v_new_status TEXT := upper(btrim(p_lifecycle_status));
    v_reason TEXT := nullif(btrim(p_change_reason), '');
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT username INTO v_actor_username
    FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'device.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to manage devices.' USING ERRCODE='42501';
    END IF;

    SELECT d.* INTO v_device
    FROM metadata.devices d
    WHERE d.id=p_device_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device was not found.' USING ERRCODE='22023';
    END IF;

    SELECT g.site_id INTO v_gateway_site_id
    FROM metadata.gateways g
    WHERE g.id=v_device.gateway_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'The device gateway was not found.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_gateway_site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the device site.' USING ERRCODE='42501';
    END IF;
    IF v_new_status NOT IN ('DISCOVERED','REGISTERED','UNASSIGNED','COMMISSIONING','ACTIVE','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid device lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF v_device.lifecycle_status='DECOMMISSIONED' AND v_new_status<>'DECOMMISSIONED' THEN
        RAISE EXCEPTION 'A decommissioned device cannot be reactivated through routine administration.' USING ERRCODE='22023';
    END IF;
    IF v_device.lifecycle_status=v_new_status THEN
        RAISE EXCEPTION 'Select a lifecycle status different from the current status.' USING ERRCODE='22023';
    END IF;
    IF v_new_status='ACTIVE' THEN
        RAISE EXCEPTION 'Use the controlled commissioning action to activate a device.' USING ERRCODE='22023';
    END IF;

    IF v_device.lifecycle_status='DISCOVERED' AND v_new_status NOT IN ('REGISTERED','UNASSIGNED','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    ELSIF v_device.lifecycle_status='REGISTERED' AND v_new_status NOT IN ('UNASSIGNED','COMMISSIONING','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    ELSIF v_device.lifecycle_status='UNASSIGNED' AND v_new_status NOT IN ('REGISTERED','COMMISSIONING','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    ELSIF v_device.lifecycle_status='COMMISSIONING' AND v_new_status NOT IN ('REGISTERED','UNASSIGNED','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    ELSIF v_device.lifecycle_status='ACTIVE' AND v_new_status NOT IN ('INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    ELSIF v_device.lifecycle_status='INACTIVE' AND v_new_status NOT IN ('REGISTERED','UNASSIGNED','COMMISSIONING','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Invalid device lifecycle transition.' USING ERRCODE='22023';
    END IF;

    IF v_new_status='DECOMMISSIONED' AND EXISTS (
        SELECT 1 FROM metadata.asset_devices ad WHERE ad.device_id=p_device_id
    ) THEN
        RAISE EXCEPTION 'Remove active asset relationships before decommissioning this device.' USING ERRCODE='22023';
    END IF;
    IF v_new_status='DECOMMISSIONED' AND EXISTS (
        SELECT 1 FROM config.site_energy_meter_roles r
        WHERE r.device_id=p_device_id AND r.is_active=TRUE
          AND (r.effective_to IS NULL OR r.effective_to>now())
    ) THEN
        RAISE EXCEPTION 'Remove active site energy roles before decommissioning this device.' USING ERRCODE='22023';
    END IF;

    UPDATE metadata.devices SET lifecycle_status=v_new_status, updated_at=now()
    WHERE id=p_device_id;

    v_result:=jsonb_build_object(
        'success',TRUE,'entity_type','DEVICE','entity_id',p_device_id,'device_id',p_device_id,
        'organization_id',v_device.organization_id,'gateway_id',v_device.gateway_id,'site_id',v_gateway_site_id,
        'previous_lifecycle_status',v_device.lifecycle_status,'lifecycle_status',v_new_status,
        'change_reason',v_reason,'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object(
        'operation','UPDATE_DEVICE_LIFECYCLE','actor_portal_user_id',p_actor_portal_user_id,
        'device_id',p_device_id,'organization_id',v_device.organization_id,'gateway_id',v_device.gateway_id,
        'site_id',v_gateway_site_id,'previous_lifecycle_status',v_device.lifecycle_status,
        'lifecycle_status',v_new_status,'change_reason',v_reason),v_result);
    RETURN v_result;
END;
$function$;

-- Creation may stage devices in any non-operational lifecycle, but ACTIVE remains
-- reserved for a later commissioning action.
CREATE OR REPLACE FUNCTION metadata.reject_uncommissioned_active_device()
RETURNS TRIGGER LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.lifecycle_status='ACTIVE' AND (TG_OP='INSERT' OR OLD.lifecycle_status IS DISTINCT FROM 'ACTIVE') THEN
        RAISE EXCEPTION 'Use the controlled commissioning action to activate a device.' USING ERRCODE='22023';
    END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_reject_uncommissioned_active_device ON metadata.devices;
CREATE TRIGGER trg_reject_uncommissioned_active_device
BEFORE INSERT OR UPDATE OF lifecycle_status ON metadata.devices FOR EACH ROW
EXECUTE FUNCTION metadata.reject_uncommissioned_active_device();

ALTER FUNCTION admin.update_device_lifecycle(BIGINT,UUID,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION metadata.reject_uncommissioned_active_device() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.update_device_lifecycle(BIGINT,UUID,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION metadata.reject_uncommissioned_active_device() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.update_device_lifecycle(BIGINT,UUID,TEXT,TEXT) TO ems_app;
