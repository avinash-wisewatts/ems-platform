-- Device administration workspace with telemetry identity and profile controls.

DROP FUNCTION IF EXISTS admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID
);
DROP FUNCTION IF EXISTS admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT
);

CREATE FUNCTION admin.create_device(
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
    p_identifier_value TEXT
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
    v_identifier_value TEXT := btrim(p_identifier_value);
    v_building UUID := p_building_id;
    v_floor UUID := p_floor_id;
    v_space UUID := p_space_id;
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

    SELECT * INTO v_gateway
    FROM metadata.gateways g
    WHERE g.id=p_gateway_id;
    IF NOT FOUND OR v_gateway.lifecycle_status='DECOMMISSIONED' THEN
        RAISE EXCEPTION 'Select an available gateway.' USING ERRCODE='22023';
    END IF;
    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,v_gateway.site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access the gateway site.'
            USING ERRCODE='42501';
    END IF;

    IF v_name IS NULL OR v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 200 characters.'
            USING ERRCODE='22023';
    END IF;
    IF v_external_id IS NULL OR v_external_id='' OR
       v_external_id !~ '^[A-Z0-9_]+$' OR length(v_external_id)>100 THEN
        RAISE EXCEPTION 'Device external ID may contain only letters, numbers, and underscores.'
            USING ERRCODE='22023';
    END IF;
    IF v_protocol NOT IN (
        'MQTT','MODBUS TCP','MODBUS RTU','BACNET IP','BACNET MS/TP',
        'OPC-UA','HTTP API'
    ) THEN
        RAISE EXCEPTION 'Select a supported device communication protocol.'
            USING ERRCODE='22023';
    END IF;
    IF v_lifecycle NOT IN (
        'DISCOVERED','REGISTERED','UNASSIGNED','COMMISSIONING',
        'INACTIVE','DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION 'Select a valid initial device lifecycle status.'
            USING ERRCODE='22023';
    END IF;
    IF length(coalesce(v_firmware,''))>100 THEN
        RAISE EXCEPTION 'Firmware version must not exceed 100 characters.'
            USING ERRCODE='22023';
    END IF;
    IF length(coalesce(v_serial,''))>200 THEN
        RAISE EXCEPTION 'Serial number must not exceed 200 characters.'
            USING ERRCODE='22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models dm
        WHERE dm.id=p_device_model_id
          AND dm.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device model does not match the selected category.'
            USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id=dp.id
        WHERE dp.id=p_profile_id AND dp.is_active
          AND dpc.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device profile is not compatible with the selected category.'
            USING ERRCODE='22023';
    END IF;

    IF v_identifier_type <> 'MQTT_UID' THEN
        RAISE EXCEPTION 'Select a supported device identifier type.'
            USING ERRCODE='22023';
    END IF;
    IF v_identifier_value IS NULL OR
       v_identifier_value !~ '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){7}$' THEN
        RAISE EXCEPTION 'MQTT UID must contain eight hexadecimal byte pairs separated by colons.'
            USING ERRCODE='22023';
    END IF;
    v_identifier_value := lower(v_identifier_value);
    IF EXISTS (
        SELECT 1 FROM metadata.device_identifiers di
        WHERE upper(di.identifier_type)=v_identifier_type
          AND lower(di.identifier_value)=v_identifier_value
    ) THEN
        RAISE EXCEPTION 'This device identifier is already assigned.'
            USING ERRCODE='23505';
    END IF;

    IF p_use_gateway_location THEN
        IF p_building_id IS NOT NULL OR p_floor_id IS NOT NULL OR p_space_id IS NOT NULL THEN
            RAISE EXCEPTION 'Do not submit a device location when using the gateway location.'
                USING ERRCODE='22023';
        END IF;
        v_building:=v_gateway.building_id;
        v_floor:=v_gateway.floor_id;
        v_space:=v_gateway.space_id;
    END IF;

    INSERT INTO metadata.devices(
        organization_id,gateway_id,device_model_id,profile_id,name,external_id,
        serial_number,firmware_version,protocol,lifecycle_status,
        building_id,floor_id,space_id
    ) VALUES (
        v_gateway.organization_id,p_gateway_id,p_device_model_id,p_profile_id,
        v_name,v_external_id,v_serial,v_firmware,v_protocol,v_lifecycle,
        v_building,v_floor,v_space
    ) RETURNING id INTO v_device_id;

    INSERT INTO metadata.device_identifiers(
        device_id,identifier_type,identifier_value
    ) VALUES (v_device_id,v_identifier_type,v_identifier_value);

    v_result:=jsonb_build_object(
        'success',TRUE,'entity_type','DEVICE','entity_id',v_device_id,
        'device_id',v_device_id,'organization_id',v_gateway.organization_id,
        'site_id',v_gateway.site_id,'gateway_id',p_gateway_id,
        'device_name',v_name,'external_id',v_external_id,
        'device_category_id',p_device_category_id,
        'device_model_id',p_device_model_id,'profile_id',p_profile_id,
        'protocol',v_protocol,'identifier_type',v_identifier_type,
        'identifier_value',v_identifier_value,'building_id',v_building,
        'floor_id',v_floor,'space_id',v_space,
        'location_source',CASE WHEN p_use_gateway_location THEN 'GATEWAY' ELSE 'DEVICE' END,
        'lifecycle_status',v_lifecycle,'commissioning_status','NOT_STARTED',
        'validation_warnings','[]'::jsonb,'blocking_conditions','[]'::jsonb,
        'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(
        id,requested_by,request_payload,result_payload
    ) VALUES (
        v_audit_id,v_actor_username,jsonb_build_object(
            'operation','CREATE_DEVICE','actor_portal_user_id',p_actor_portal_user_id,
            'gateway_id',p_gateway_id,'organization_id',v_gateway.organization_id,
            'site_id',v_gateway.site_id,'name',v_name,'external_id',v_external_id,
            'device_category_id',p_device_category_id,
            'device_model_id',p_device_model_id,'profile_id',p_profile_id,
            'protocol',v_protocol,'serial_number',v_serial,
            'firmware_version',v_firmware,'identifier_type',v_identifier_type,
            'identifier_value',v_identifier_value,
            'use_gateway_location',p_use_gateway_location,
            'building_id',v_building,'floor_id',v_floor,'space_id',v_space
        ),v_result
    );
    RETURN v_result;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'A device external ID or telemetry identifier already exists.'
            USING ERRCODE='23505';
END;
$function$;

DROP FUNCTION IF EXISTS admin.list_accessible_devices(BIGINT);
CREATE FUNCTION admin.list_accessible_devices(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID, organization_name TEXT,
    site_id UUID, site_name TEXT,
    gateway_id UUID, gateway_name TEXT, gateway_external_id TEXT,
    device_id UUID, device_name TEXT, external_id TEXT,
    device_category_id UUID, device_category_name TEXT,
    device_model_id UUID, device_vendor TEXT, device_model TEXT,
    profile_id UUID, profile_code TEXT, profile_name TEXT,
    identifier_type TEXT, identifier_value TEXT,
    protocol TEXT, firmware_version TEXT, serial_number TEXT,
    lifecycle_status TEXT, operational_policy TEXT,
    building_id UUID, building_name TEXT,
    floor_id UUID, floor_name TEXT,
    space_id UUID, space_name TEXT,
    telemetry_state TEXT, configuration_state TEXT,
    latest_received_timestamp TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config, analytics
AS $function$
SELECT
    d.organization_id,o.name,g.site_id,s.name,g.id,g.name,g.external_id,
    d.id,d.name,d.external_id,dm.device_category_id,dc.name,d.device_model_id,
    dm.vendor,dm.model,d.profile_id,dp.profile_code,dp.profile_name,
    ident.identifier_type,ident.identifier_value,d.protocol,d.firmware_version,
    d.serial_number,d.lifecycle_status,d.operational_policy,
    d.building_id,b.name,d.floor_id,f.name,d.space_id,sp.name,
    tv.telemetry_state,tv.configuration_state,tv.latest_received_timestamp
FROM metadata.devices d
JOIN metadata.organizations o ON o.id=d.organization_id
JOIN metadata.gateways g ON g.id=d.gateway_id
JOIN metadata.sites s ON s.id=g.site_id
JOIN metadata.device_models dm ON dm.id=d.device_model_id
JOIN config.device_categories dc ON dc.id=dm.device_category_id
JOIN config.device_profiles dp ON dp.id=d.profile_id
LEFT JOIN metadata.buildings b ON b.id=d.building_id
LEFT JOIN metadata.floors f ON f.id=d.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=d.space_id
LEFT JOIN LATERAL (
    SELECT di.identifier_type,di.identifier_value
    FROM metadata.device_identifiers di
    WHERE di.device_id=d.id
    ORDER BY CASE WHEN di.identifier_type='MQTT_UID' THEN 0 ELSE 1 END,
             di.identifier_type,di.created_at
    LIMIT 1
) ident ON TRUE
LEFT JOIN analytics.v_device_telemetry_availability tv ON tv.device_id=d.id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY o.name,s.name,b.name,f.name,sp.name,d.name,d.lifecycle_status;
$function$;

CREATE OR REPLACE FUNCTION admin.get_device_workspace(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID
)
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, admin, metadata, config, analytics
AS $function$
WITH device_row AS (
    SELECT
        d.id AS device_id,d.organization_id,o.code AS organization_code,
        o.name AS organization_name,g.site_id,s.code AS site_code,
        s.name AS site_name,d.gateway_id,g.name AS gateway_name,
        g.external_id AS gateway_external_id,d.building_id,b.name AS building_name,
        d.floor_id,f.name AS floor_name,d.space_id,sp.name AS space_name,
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
        cr.commissioning_status,cr.is_ready,
        cr.blocking_reason_codes,cr.warning_reason_codes,
        (SELECT count(*) FROM metadata.asset_devices ad WHERE ad.device_id=d.id) AS relationship_count
    FROM metadata.devices d
    JOIN metadata.organizations o ON o.id=d.organization_id
    JOIN metadata.gateways g ON g.id=d.gateway_id
    JOIN metadata.sites s ON s.id=g.site_id
    JOIN metadata.device_models dm ON dm.id=d.device_model_id
    JOIN config.device_categories dc ON dc.id=dm.device_category_id
    JOIN config.device_profiles dp ON dp.id=d.profile_id
    LEFT JOIN metadata.buildings b ON b.id=d.building_id
    LEFT JOIN metadata.floors f ON f.id=d.floor_id
    LEFT JOIN metadata.spaces sp ON sp.id=d.space_id
    LEFT JOIN LATERAL (
        SELECT di.identifier_type,di.identifier_value
        FROM metadata.device_identifiers di
        WHERE di.device_id=d.id
        ORDER BY CASE WHEN di.identifier_type='MQTT_UID' THEN 0 ELSE 1 END,
                 di.identifier_type,di.created_at
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

CREATE OR REPLACE FUNCTION admin.update_device_workspace(
    p_actor_portal_user_id BIGINT,
    p_device_id UUID,
    p_device_name TEXT,
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
    p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE
    v_before metadata.devices%ROWTYPE;
    v_gateway metadata.gateways%ROWTYPE;
    v_old_identifier metadata.device_identifiers%ROWTYPE;
    v_actor_username TEXT;
    v_name TEXT:=btrim(p_device_name);
    v_protocol TEXT:=upper(btrim(p_protocol));
    v_status TEXT:=upper(btrim(p_lifecycle_status));
    v_firmware TEXT:=nullif(btrim(p_firmware_version),'');
    v_serial TEXT:=nullif(btrim(p_serial_number),'');
    v_identifier_type TEXT:=upper(btrim(p_identifier_type));
    v_identifier_value TEXT:=btrim(p_identifier_value);
    v_reason TEXT:=btrim(p_change_reason);
    v_building UUID:=p_building_id;
    v_floor UUID:=p_floor_id;
    v_space UUID:=p_space_id;
    v_audit_id UUID:=gen_random_uuid();
    v_lifecycle JSONB;
    v_result JSONB;
BEGIN
    SELECT pu.username INTO v_actor_username
    FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id AND pu.is_active;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(
        p_actor_portal_user_id,'device.manage'
    ) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update devices.'
            USING ERRCODE='42501';
    END IF;

    SELECT * INTO v_before FROM metadata.devices d
    WHERE d.id=p_device_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Device was not found.' USING ERRCODE='22023';
    END IF;
    SELECT * INTO v_gateway FROM metadata.gateways g
    WHERE g.id=v_before.gateway_id;
    IF NOT admin.portal_user_can_access_site(
        p_actor_portal_user_id,v_gateway.site_id
    ) THEN
        RAISE EXCEPTION 'Portal actor cannot access this device.'
            USING ERRCODE='42501';
    END IF;

    IF v_name='' OR length(v_name)>200 THEN
        RAISE EXCEPTION 'Device name is required and must not exceed 200 characters.'
            USING ERRCODE='22023';
    END IF;
    IF v_protocol NOT IN (
        'MQTT','MODBUS TCP','MODBUS RTU','BACNET IP','BACNET MS/TP',
        'OPC-UA','HTTP API'
    ) THEN
        RAISE EXCEPTION 'Select a supported device communication protocol.'
            USING ERRCODE='22023';
    END IF;
    IF v_status NOT IN (
        'DISCOVERED','REGISTERED','UNASSIGNED','COMMISSIONING',
        'ACTIVE','INACTIVE','DECOMMISSIONED'
    ) THEN
        RAISE EXCEPTION 'Select a valid device lifecycle status.'
            USING ERRCODE='22023';
    END IF;
    IF v_status='ACTIVE' AND v_before.lifecycle_status<>'ACTIVE' THEN
        RAISE EXCEPTION 'Use the controlled commissioning action to activate a device.'
            USING ERRCODE='23514';
    END IF;
    IF v_reason='' OR length(v_reason)>1000 THEN
        RAISE EXCEPTION 'Change reason is required and must not exceed 1000 characters.'
            USING ERRCODE='22023';
    END IF;
    IF length(coalesce(v_firmware,''))>100 OR length(coalesce(v_serial,''))>200 THEN
        RAISE EXCEPTION 'Firmware or serial number exceeds the supported length.'
            USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models dm
        WHERE dm.id=p_device_model_id
          AND dm.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device model does not match the selected category.'
            USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id=dp.id
        WHERE dp.id=p_profile_id AND dp.is_active
          AND dpc.device_category_id=p_device_category_id
    ) THEN
        RAISE EXCEPTION 'Device profile is not compatible with the selected category.'
            USING ERRCODE='22023';
    END IF;

    IF v_identifier_type <> 'MQTT_UID' OR
       v_identifier_value !~ '^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){7}$' THEN
        RAISE EXCEPTION 'Enter a valid MQTT UID.' USING ERRCODE='22023';
    END IF;
    v_identifier_value:=lower(v_identifier_value);
    IF EXISTS (
        SELECT 1 FROM metadata.device_identifiers di
        WHERE di.device_id<>p_device_id
          AND upper(di.identifier_type)=v_identifier_type
          AND lower(di.identifier_value)=v_identifier_value
    ) THEN
        RAISE EXCEPTION 'This device identifier is already assigned.'
            USING ERRCODE='23505';
    END IF;

    IF p_use_gateway_location THEN
        IF p_building_id IS NOT NULL OR p_floor_id IS NOT NULL OR p_space_id IS NOT NULL THEN
            RAISE EXCEPTION 'Do not submit a device location when using the gateway location.'
                USING ERRCODE='22023';
        END IF;
        v_building:=v_gateway.building_id;
        v_floor:=v_gateway.floor_id;
        v_space:=v_gateway.space_id;
    END IF;

    SELECT * INTO v_old_identifier
    FROM metadata.device_identifiers di
    WHERE di.device_id=p_device_id
    ORDER BY CASE WHEN di.identifier_type='MQTT_UID' THEN 0 ELSE 1 END,
             di.created_at
    LIMIT 1 FOR UPDATE;

    UPDATE metadata.devices
    SET name=v_name,device_model_id=p_device_model_id,profile_id=p_profile_id,
        protocol=v_protocol,firmware_version=v_firmware,serial_number=v_serial,
        building_id=v_building,floor_id=v_floor,space_id=v_space,
        updated_at=now()
    WHERE id=p_device_id;

    IF v_old_identifier.id IS NOT NULL THEN
        UPDATE metadata.device_identifiers
        SET identifier_type=v_identifier_type,identifier_value=v_identifier_value
        WHERE id=v_old_identifier.id;
    ELSE
        INSERT INTO metadata.device_identifiers(
            device_id,identifier_type,identifier_value
        ) VALUES (p_device_id,v_identifier_type,v_identifier_value);
    END IF;

    IF v_status IS DISTINCT FROM v_before.lifecycle_status THEN
        v_lifecycle:=admin.transition_entity_lifecycle(
            p_actor_portal_user_id,'DEVICE',p_device_id,v_status,v_reason,FALSE
        );
        IF NOT coalesce((v_lifecycle->>'success')::boolean,FALSE) THEN
            RAISE EXCEPTION '%',coalesce(
                v_lifecycle->>'failure_reason','Lifecycle transition was rejected.'
            ) USING ERRCODE='22023';
        END IF;
    END IF;

    v_result:=jsonb_build_object(
        'success',TRUE,'device_id',p_device_id,'lifecycle_status',v_status,
        'identifier_type',v_identifier_type,'identifier_value',v_identifier_value,
        'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(
        id,requested_by,request_payload,result_payload
    ) VALUES (
        v_audit_id,v_actor_username,jsonb_build_object(
            'operation','UPDATE_DEVICE','actor_portal_user_id',p_actor_portal_user_id,
            'device_id',p_device_id,'old_name',v_before.name,'new_name',v_name,
            'old_device_model_id',v_before.device_model_id,
            'new_device_model_id',p_device_model_id,
            'old_profile_id',v_before.profile_id,'new_profile_id',p_profile_id,
            'old_protocol',v_before.protocol,'new_protocol',v_protocol,
            'old_identifier_type',v_old_identifier.identifier_type,
            'new_identifier_type',v_identifier_type,
            'old_identifier_value',v_old_identifier.identifier_value,
            'new_identifier_value',v_identifier_value,
            'old_building_id',v_before.building_id,'new_building_id',v_building,
            'old_floor_id',v_before.floor_id,'new_floor_id',v_floor,
            'old_space_id',v_before.space_id,'new_space_id',v_space,
            'change_reason',v_reason
        ),v_result
    );
    RETURN v_result;
END;
$function$;

ALTER FUNCTION admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT
) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_devices(BIGINT) OWNER TO ems_admin;
ALTER FUNCTION admin.get_device_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.update_device_workspace(
    BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT
) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT
) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_devices(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.get_device_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_device_workspace(
    BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT
) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_devices(BIGINT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.get_device_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_device_workspace(
    BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT
) TO ems_app;
