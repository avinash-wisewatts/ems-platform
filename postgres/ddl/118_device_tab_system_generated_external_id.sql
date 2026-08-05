-- Migration 166
-- Align direct Device Administration creation with onboarding-generated ID behavior.
-- External IDs are generated/resolved by the database; physical telemetry UID
-- conflicts remain hard failures.

CREATE OR REPLACE FUNCTION admin.create_device(
    p_actor_portal_user_id BIGINT,
    p_gateway_id UUID,
    p_name TEXT,
    p_external_id TEXT,
    p_device_category_id UUID,
    p_device_model_id UUID,
    p_profile_id UUID,
    p_protocol TEXT,
    p_lifecycle_status TEXT,
    p_firmware_version TEXT,
    p_serial_number TEXT,
    p_use_gateway_location BOOLEAN,
    p_building_id UUID,
    p_floor_id UUID,
    p_space_id UUID,
    p_identifier_type TEXT,
    p_identifier_value TEXT,
    p_operational_policy TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_actor_username TEXT;
    v_gateway metadata.gateways%ROWTYPE;
    v_name TEXT := btrim(p_name);
    v_external_id TEXT := upper(btrim(p_external_id));
    v_protocol TEXT := upper(btrim(p_protocol));
    v_lifecycle TEXT := upper(btrim(p_lifecycle_status));
    v_firmware TEXT := nullif(btrim(p_firmware_version),'');
    v_serial TEXT := nullif(btrim(p_serial_number),'');
    v_identifier_type TEXT := upper(btrim(p_identifier_type));
    v_identifier_value TEXT := lower(btrim(p_identifier_value));
    v_policy TEXT := upper(btrim(p_operational_policy));
    v_location_mode TEXT := CASE WHEN p_use_gateway_location THEN 'GATEWAY' ELSE 'DEVICE' END;
    v_building UUID := CASE WHEN p_use_gateway_location THEN NULL ELSE p_building_id END;
    v_floor UUID := CASE WHEN p_use_gateway_location THEN NULL ELSE p_floor_id END;
    v_space UUID := CASE WHEN p_use_gateway_location THEN NULL ELSE p_space_id END;
    v_device_id UUID;
    v_audit_id UUID := gen_random_uuid();
    v_result JSONB;
BEGIN
    SELECT pu.username INTO v_actor_username
    FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id AND pu.is_active;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,'device.manage'
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create devices.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_gateway FROM metadata.gateways WHERE id=p_gateway_id;
    IF NOT FOUND OR v_gateway.lifecycle_status='DECOMMISSIONED' THEN
        RAISE EXCEPTION 'Select an available gateway.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_gateway.site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access the gateway site.' USING ERRCODE='42501';
    END IF;

    IF v_name IS NULL OR v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 200 characters.' USING ERRCODE='22023';
    END IF;
    -- Device external IDs are system-managed. Accept the submitted value as a
    -- preferred base, fall back to the device name, normalize it, and resolve
    -- organization-scoped conflicts atomically in the database.
    v_external_id := admin.recommend_available_identifier(
        'DEVICE',
        coalesce(nullif(v_external_id, ''), v_name),
        v_gateway.organization_id,
        NULL,
        NULL,
        NULL,
        NULL
    );
    IF v_protocol NOT IN ('MQTT','MODBUS TCP','MODBUS RTU','BACNET IP','BACNET MS/TP','OPC-UA','HTTP API') THEN
        RAISE EXCEPTION 'Select a supported device communication protocol.' USING ERRCODE='22023';
    END IF;
    IF v_lifecycle NOT IN ('DISCOVERED','REGISTERED','UNASSIGNED','COMMISSIONING','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid initial device lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF v_policy NOT IN ('STANDALONE','ASSET_ASSIGNED') THEN
        RAISE EXCEPTION 'Select a valid operational policy.' USING ERRCODE='22023';
    END IF;
    IF length(coalesce(v_firmware,''))>100 OR length(coalesce(v_serial,''))>200 THEN
        RAISE EXCEPTION 'Firmware or serial number exceeds the supported length.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models dm
        WHERE dm.id=p_device_model_id AND dm.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device model does not match the selected category.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id=dp.id
        WHERE dp.id=p_profile_id AND dp.is_active
          AND dpc.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device profile is not compatible with the selected category.' USING ERRCODE='22023';
    END IF;
    IF v_identifier_type <> 'MQTT_UID' OR
       v_identifier_value !~ '^[0-9a-f]{2}(:[0-9a-f]{2}){7}$' THEN
        RAISE EXCEPTION 'MQTT UID must contain eight hexadecimal byte pairs separated by colons.' USING ERRCODE='22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM metadata.device_identifiers di
        WHERE upper(di.identifier_type)=v_identifier_type
          AND lower(di.identifier_value)=v_identifier_value
    ) THEN
        RAISE EXCEPTION 'This device identifier is already assigned.' USING ERRCODE='23505';
    END IF;

    IF v_floor IS NOT NULL AND v_building IS NULL THEN
        RAISE EXCEPTION 'A selected floor requires its building.' USING ERRCODE='22023';
    END IF;
    IF v_space IS NOT NULL AND v_floor IS NULL THEN
        RAISE EXCEPTION 'A selected space requires its floor.' USING ERRCODE='22023';
    END IF;
    IF v_building IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.buildings b
        WHERE b.id=v_building AND b.site_id=v_gateway.site_id
    ) THEN
        RAISE EXCEPTION 'Selected building is not in the gateway site.' USING ERRCODE='22023';
    END IF;
    IF v_floor IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.floors f
        JOIN metadata.buildings b ON b.id=f.building_id
        WHERE f.id=v_floor AND f.building_id=v_building AND b.site_id=v_gateway.site_id
    ) THEN
        RAISE EXCEPTION 'Selected floor is not in the selected building.' USING ERRCODE='22023';
    END IF;
    IF v_space IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.spaces sp WHERE sp.id=v_space AND sp.floor_id=v_floor
    ) THEN
        RAISE EXCEPTION 'Selected space is not in the selected floor.' USING ERRCODE='22023';
    END IF;

    INSERT INTO metadata.devices(
        organization_id,gateway_id,device_model_id,profile_id,name,external_id,
        serial_number,firmware_version,protocol,lifecycle_status,
        operational_policy,location_mode,building_id,floor_id,space_id
    ) VALUES (
        v_gateway.organization_id,p_gateway_id,p_device_model_id,p_profile_id,
        v_name,v_external_id,v_serial,v_firmware,v_protocol,v_lifecycle,
        v_policy,v_location_mode,v_building,v_floor,v_space
    ) RETURNING id INTO v_device_id;

    INSERT INTO metadata.device_identifiers(device_id,identifier_type,identifier_value)
    VALUES (v_device_id,v_identifier_type,v_identifier_value);

    v_result:=jsonb_build_object(
        'success',TRUE,'entity_type','DEVICE','entity_id',v_device_id,
        'device_id',v_device_id,'organization_id',v_gateway.organization_id,
        'site_id',v_gateway.site_id,'gateway_id',p_gateway_id,
        'device_name',v_name,'external_id',v_external_id,
        'device_category_id',p_device_category_id,'device_model_id',p_device_model_id,
        'profile_id',p_profile_id,'protocol',v_protocol,
        'identifier_type',v_identifier_type,'identifier_value',v_identifier_value,
        'operational_policy',v_policy,'location_mode',v_location_mode,
        'building_id',v_building,'floor_id',v_floor,'space_id',v_space,
        'lifecycle_status',v_lifecycle,'commissioning_status','NOT_STARTED',
        'validation_warnings','[]'::jsonb,'blocking_conditions','[]'::jsonb,
        'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES (v_audit_id,v_actor_username,jsonb_build_object(
        'operation','CREATE_DEVICE','actor_portal_user_id',p_actor_portal_user_id,
        'gateway_id',p_gateway_id,'name',v_name,'external_id',v_external_id,
        'device_category_id',p_device_category_id,'device_model_id',p_device_model_id,
        'profile_id',p_profile_id,'protocol',v_protocol,'identifier_type',v_identifier_type,
        'identifier_value',v_identifier_value,'operational_policy',v_policy,
        'location_mode',v_location_mode,'building_id',v_building,
        'floor_id',v_floor,'space_id',v_space),v_result);
    RETURN v_result;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'A device external ID or telemetry identifier already exists.' USING ERRCODE='23505';
END;
$function$;


COMMENT ON FUNCTION admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,
    UUID,UUID,UUID,TEXT,TEXT,TEXT
) IS 'Creates a device atomically. Resolves organization-scoped device external ID conflicts while preserving strict uniqueness for physical telemetry identifiers.';
