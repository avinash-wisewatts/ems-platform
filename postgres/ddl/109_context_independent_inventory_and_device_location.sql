-- Context-independent inventories and explicit device location inheritance.

ALTER TABLE metadata.devices
    ADD COLUMN IF NOT EXISTS location_mode TEXT;

UPDATE metadata.devices AS device
SET location_mode = CASE
    WHEN device.building_id IS NOT DISTINCT FROM gateway.building_id
     AND device.floor_id IS NOT DISTINCT FROM gateway.floor_id
     AND device.space_id IS NOT DISTINCT FROM gateway.space_id
    THEN 'GATEWAY'
    ELSE 'DEVICE'
END
FROM metadata.gateways AS gateway
WHERE gateway.id = device.gateway_id
  AND device.location_mode IS NULL;

UPDATE metadata.devices
SET location_mode = 'DEVICE'
WHERE location_mode IS NULL;

ALTER TABLE metadata.devices
    ALTER COLUMN location_mode SET DEFAULT 'DEVICE',
    ALTER COLUMN location_mode SET NOT NULL;

ALTER TABLE metadata.devices
    DROP CONSTRAINT IF EXISTS devices_location_mode_chk;
ALTER TABLE metadata.devices
    ADD CONSTRAINT devices_location_mode_chk
    CHECK (location_mode IN ('GATEWAY', 'DEVICE'));

-- Inherited devices keep no explicit override. Their effective location is
-- resolved dynamically from the gateway, so later gateway moves propagate.
UPDATE metadata.devices
SET building_id = NULL,
    floor_id = NULL,
    space_id = NULL,
    updated_at = now()
WHERE location_mode = 'GATEWAY'
  AND (building_id IS NOT NULL OR floor_id IS NOT NULL OR space_id IS NOT NULL);

DROP FUNCTION IF EXISTS admin.create_device(
    BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT
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
    IF v_external_id IS NULL OR v_external_id='' OR v_external_id !~ '^[A-Z0-9_]+$' OR length(v_external_id)>100 THEN
        RAISE EXCEPTION 'Device external ID may contain only letters, numbers, and underscores.' USING ERRCODE='22023';
    END IF;
    IF v_protocol NOT IN ('MQTT','MODBUS TCP','MODBUS RTU','BACNET IP','BACNET MS/TP','OPC-UA','HTTP API') THEN
        RAISE EXCEPTION 'Select a supported device communication protocol.' USING ERRCODE='22023';
    END IF;
    IF v_lifecycle NOT IN ('REGISTERED','INACTIVE','DECOMMISSIONED') THEN
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
    lifecycle_status TEXT, operational_policy TEXT, location_mode TEXT,
    building_id UUID, building_name TEXT,
    floor_id UUID, floor_name TEXT,
    space_id UUID, space_name TEXT,
    explicit_building_id UUID, explicit_building_name TEXT,
    explicit_floor_id UUID, explicit_floor_name TEXT,
    explicit_space_id UUID, explicit_space_name TEXT,
    gateway_building_id UUID, gateway_building_name TEXT,
    gateway_floor_id UUID, gateway_floor_name TEXT,
    gateway_space_id UUID, gateway_space_name TEXT,
    location_path TEXT, gateway_location_path TEXT, explicit_location_path TEXT,
    telemetry_state TEXT, configuration_state TEXT,
    latest_received_timestamp TIMESTAMPTZ,
    created_at TIMESTAMPTZ, updated_at TIMESTAMPTZ
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config, analytics
AS $function$
SELECT
    d.organization_id,o.name,g.site_id,s.name,g.id,g.name,g.external_id,
    d.id,d.name,d.external_id,dm.device_category_id,dc.name,d.device_model_id,
    dm.vendor,dm.model,d.profile_id,dp.profile_code,dp.profile_name,
    ident.identifier_type,ident.identifier_value,d.protocol,d.firmware_version,
    d.serial_number,d.lifecycle_status,d.operational_policy,d.location_mode,
    CASE WHEN d.location_mode='GATEWAY' THEN g.building_id ELSE d.building_id END,
    CASE WHEN d.location_mode='GATEWAY' THEN gb.name ELSE db.name END,
    CASE WHEN d.location_mode='GATEWAY' THEN g.floor_id ELSE d.floor_id END,
    CASE WHEN d.location_mode='GATEWAY' THEN gf.name ELSE df.name END,
    CASE WHEN d.location_mode='GATEWAY' THEN g.space_id ELSE d.space_id END,
    CASE WHEN d.location_mode='GATEWAY' THEN gs.name ELSE ds.name END,
    d.building_id,db.name,d.floor_id,df.name,d.space_id,ds.name,
    g.building_id,gb.name,g.floor_id,gf.name,g.space_id,gs.name,
    concat_ws(' / ',o.name,s.name,
        CASE WHEN d.location_mode='GATEWAY' THEN gb.name ELSE db.name END,
        CASE WHEN d.location_mode='GATEWAY' THEN gf.name ELSE df.name END,
        CASE WHEN d.location_mode='GATEWAY' THEN gs.name ELSE ds.name END),
    concat_ws(' / ',o.name,s.name,gb.name,gf.name,gs.name),
    concat_ws(' / ',o.name,s.name,db.name,df.name,ds.name),
    tv.telemetry_state,tv.configuration_state,tv.latest_received_timestamp,
    d.created_at,d.updated_at
FROM metadata.devices d
JOIN metadata.organizations o ON o.id=d.organization_id
JOIN metadata.gateways g ON g.id=d.gateway_id
JOIN metadata.sites s ON s.id=g.site_id
JOIN metadata.device_models dm ON dm.id=d.device_model_id
JOIN config.device_categories dc ON dc.id=dm.device_category_id
JOIN config.device_profiles dp ON dp.id=d.profile_id
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
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY o.name,s.name,
    CASE WHEN d.location_mode='GATEWAY' THEN gb.name ELSE db.name END,
    CASE WHEN d.location_mode='GATEWAY' THEN gf.name ELSE df.name END,
    CASE WHEN d.location_mode='GATEWAY' THEN gs.name ELSE ds.name END,
    d.name,d.lifecycle_status;
$function$;

CREATE OR REPLACE FUNCTION admin.get_device_workspace(
    p_actor_portal_user_id BIGINT,p_device_id UUID
)
RETURNS JSONB
LANGUAGE SQL SECURITY DEFINER STABLE
SET search_path TO pg_catalog, admin, metadata, config, analytics
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
    JOIN config.device_profiles dp ON dp.id=d.profile_id
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

DROP FUNCTION IF EXISTS admin.update_device_workspace(
    BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,
    BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT
);
CREATE FUNCTION admin.update_device_workspace(
    p_actor_portal_user_id BIGINT,p_device_id UUID,p_device_name TEXT,
    p_device_category_id UUID,p_device_model_id UUID,p_profile_id UUID,
    p_protocol TEXT,p_lifecycle_status TEXT,p_firmware_version TEXT,p_serial_number TEXT,
    p_use_gateway_location BOOLEAN,p_building_id UUID,p_floor_id UUID,p_space_id UUID,
    p_identifier_type TEXT,p_identifier_value TEXT,p_operational_policy TEXT,p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
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
    v_identifier_value TEXT:=lower(btrim(p_identifier_value));
    v_policy TEXT:=upper(btrim(p_operational_policy));
    v_reason TEXT:=btrim(p_change_reason);
    v_location_mode TEXT:=CASE WHEN p_use_gateway_location THEN 'GATEWAY' ELSE 'DEVICE' END;
    v_building UUID:=CASE WHEN p_use_gateway_location THEN NULL ELSE p_building_id END;
    v_floor UUID:=CASE WHEN p_use_gateway_location THEN NULL ELSE p_floor_id END;
    v_space UUID:=CASE WHEN p_use_gateway_location THEN NULL ELSE p_space_id END;
    v_audit_id UUID:=gen_random_uuid();
    v_lifecycle JSONB;
    v_result JSONB;
BEGIN
    SELECT pu.username INTO v_actor_username FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id AND pu.is_active;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'device.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update devices.' USING ERRCODE='42501';
    END IF;
    SELECT * INTO v_before FROM metadata.devices WHERE id=p_device_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Device was not found.' USING ERRCODE='22023'; END IF;
    SELECT * INTO v_gateway FROM metadata.gateways WHERE id=v_before.gateway_id;
    IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_gateway.site_id) THEN
        RAISE EXCEPTION 'Portal actor cannot access this device.' USING ERRCODE='42501';
    END IF;
    IF v_name='' OR length(v_name)>200 THEN RAISE EXCEPTION 'Device name is required and must not exceed 200 characters.' USING ERRCODE='22023'; END IF;
    IF v_protocol NOT IN ('MQTT','MODBUS TCP','MODBUS RTU','BACNET IP','BACNET MS/TP','OPC-UA','HTTP API') THEN RAISE EXCEPTION 'Select a supported device communication protocol.' USING ERRCODE='22023'; END IF;
    IF v_status NOT IN ('REGISTERED','ACTIVE','INACTIVE','DECOMMISSIONED') THEN RAISE EXCEPTION 'Select a valid device lifecycle status.' USING ERRCODE='22023'; END IF;
    IF v_status='ACTIVE' AND v_before.lifecycle_status<>'ACTIVE' THEN RAISE EXCEPTION 'Use the controlled commissioning action to activate a device.' USING ERRCODE='23514'; END IF;
    IF v_policy NOT IN ('STANDALONE','ASSET_ASSIGNED') THEN RAISE EXCEPTION 'Select a valid operational policy.' USING ERRCODE='22023'; END IF;
    IF v_reason='' OR length(v_reason)>1000 THEN RAISE EXCEPTION 'Change reason is required and must not exceed 1000 characters.' USING ERRCODE='22023'; END IF;
    IF length(coalesce(v_firmware,''))>100 OR length(coalesce(v_serial,''))>200 THEN RAISE EXCEPTION 'Firmware or serial number exceeds the supported length.' USING ERRCODE='22023'; END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.device_models dm WHERE dm.id=p_device_model_id AND dm.device_category_id=p_device_category_id) THEN RAISE EXCEPTION 'Device model does not match the selected category.' USING ERRCODE='22023'; END IF;
    IF NOT EXISTS (SELECT 1 FROM config.device_profiles dp JOIN config.device_profile_categories dpc ON dpc.profile_id=dp.id WHERE dp.id=p_profile_id AND dp.is_active AND dpc.device_category_id=p_device_category_id) THEN RAISE EXCEPTION 'Device profile is not compatible with the selected category.' USING ERRCODE='22023'; END IF;
    IF v_identifier_type<>'MQTT_UID' OR v_identifier_value !~ '^[0-9a-f]{2}(:[0-9a-f]{2}){7}$' THEN RAISE EXCEPTION 'Enter a valid MQTT UID.' USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM metadata.device_identifiers di WHERE di.device_id<>p_device_id AND upper(di.identifier_type)=v_identifier_type AND lower(di.identifier_value)=v_identifier_value) THEN RAISE EXCEPTION 'This device identifier is already assigned.' USING ERRCODE='23505'; END IF;
    IF v_floor IS NOT NULL AND v_building IS NULL THEN RAISE EXCEPTION 'A selected floor requires its building.' USING ERRCODE='22023'; END IF;
    IF v_space IS NOT NULL AND v_floor IS NULL THEN RAISE EXCEPTION 'A selected space requires its floor.' USING ERRCODE='22023'; END IF;
    IF v_building IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.buildings b WHERE b.id=v_building AND b.site_id=v_gateway.site_id) THEN RAISE EXCEPTION 'Selected building is not in the gateway site.' USING ERRCODE='22023'; END IF;
    IF v_floor IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.floors f JOIN metadata.buildings b ON b.id=f.building_id WHERE f.id=v_floor AND f.building_id=v_building AND b.site_id=v_gateway.site_id) THEN RAISE EXCEPTION 'Selected floor is not in the selected building.' USING ERRCODE='22023'; END IF;
    IF v_space IS NOT NULL AND NOT EXISTS (SELECT 1 FROM metadata.spaces sp WHERE sp.id=v_space AND sp.floor_id=v_floor) THEN RAISE EXCEPTION 'Selected space is not in the selected floor.' USING ERRCODE='22023'; END IF;

    SELECT * INTO v_old_identifier FROM metadata.device_identifiers di
    WHERE di.device_id=p_device_id
    ORDER BY CASE WHEN di.identifier_type='MQTT_UID' THEN 0 ELSE 1 END,di.created_at
    LIMIT 1 FOR UPDATE;

    UPDATE metadata.devices
    SET name=v_name,device_model_id=p_device_model_id,profile_id=p_profile_id,
        protocol=v_protocol,firmware_version=v_firmware,serial_number=v_serial,
        operational_policy=v_policy,location_mode=v_location_mode,
        building_id=v_building,floor_id=v_floor,space_id=v_space,updated_at=now()
    WHERE id=p_device_id;

    IF v_old_identifier.id IS NOT NULL THEN
        UPDATE metadata.device_identifiers SET identifier_type=v_identifier_type,identifier_value=v_identifier_value WHERE id=v_old_identifier.id;
    ELSE
        INSERT INTO metadata.device_identifiers(device_id,identifier_type,identifier_value) VALUES (p_device_id,v_identifier_type,v_identifier_value);
    END IF;

    IF v_status IS DISTINCT FROM v_before.lifecycle_status THEN
        v_lifecycle:=admin.transition_entity_lifecycle(p_actor_portal_user_id,'DEVICE',p_device_id,v_status,v_reason,FALSE);
        IF NOT coalesce((v_lifecycle->>'success')::boolean,FALSE) THEN
            RAISE EXCEPTION '%',coalesce(v_lifecycle->>'failure_reason','Lifecycle transition was rejected.') USING ERRCODE='22023';
        END IF;
    END IF;

    v_result:=jsonb_build_object('success',TRUE,'device_id',p_device_id,
        'lifecycle_status',v_status,'operational_policy',v_policy,
        'location_mode',v_location_mode,'identifier_type',v_identifier_type,
        'identifier_value',v_identifier_value,'audit_transaction_id',v_audit_id);
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES (v_audit_id,v_actor_username,jsonb_build_object(
        'operation','UPDATE_DEVICE','actor_portal_user_id',p_actor_portal_user_id,
        'device_id',p_device_id,'old_name',v_before.name,'new_name',v_name,
        'old_device_model_id',v_before.device_model_id,'new_device_model_id',p_device_model_id,
        'old_profile_id',v_before.profile_id,'new_profile_id',p_profile_id,
        'old_protocol',v_before.protocol,'new_protocol',v_protocol,
        'old_operational_policy',v_before.operational_policy,'new_operational_policy',v_policy,
        'old_location_mode',v_before.location_mode,'new_location_mode',v_location_mode,
        'old_identifier_type',v_old_identifier.identifier_type,'new_identifier_type',v_identifier_type,
        'old_identifier_value',v_old_identifier.identifier_value,'new_identifier_value',v_identifier_value,
        'old_building_id',v_before.building_id,'new_building_id',v_building,
        'old_floor_id',v_before.floor_id,'new_floor_id',v_floor,
        'old_space_id',v_before.space_id,'new_space_id',v_space,
        'change_reason',v_reason),v_result);
    RETURN v_result;
END;
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
SET search_path TO pg_catalog, admin, metadata, telemetry, config
AS $function$
WITH policy AS (
    SELECT online_threshold_seconds FROM config.gateway_connectivity_policy WHERE policy_id=1
), last_seen AS (
    SELECT ds.gateway_id,max(coalesce(ds.last_successful_communication,ds.source_timestamp,ds.received_at)) AS last_seen_at
    FROM telemetry.device_status ds WHERE ds.gateway_id IS NOT NULL GROUP BY ds.gateway_id
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

-- Add useful immutable record metadata and readable location to the asset list.
DROP FUNCTION IF EXISTS admin.list_accessible_assets(BIGINT);
CREATE FUNCTION admin.list_accessible_assets(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID,organization_code TEXT,organization_name TEXT,
    site_id UUID,site_code TEXT,site_name TEXT,
    asset_id UUID,asset_name TEXT,external_id TEXT,
    asset_type_id UUID,asset_type_name TEXT,parent_asset_id UUID,parent_asset_name TEXT,
    building_id UUID,building_name TEXT,floor_id UUID,floor_name TEXT,
    space_id UUID,space_name TEXT,location_path TEXT,
    lifecycle_status TEXT,metering_requirement TEXT,coverage_status TEXT,
    created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ
)
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
SELECT a.organization_id,o.code,o.name,a.site_id,s.code,s.name,
       a.id,a.name,a.external_id,a.asset_type_id,at.name,a.parent_asset_id,parent.name,
       a.building_id,b.name,a.floor_id,f.name,a.space_id,sp.name,
       concat_ws(' / ',o.name,s.name,b.name,f.name,sp.name),
       a.lifecycle_status,a.metering_requirement,c.coverage_status,a.created_at,a.updated_at
FROM metadata.assets a
JOIN metadata.organizations o ON o.id=a.organization_id
JOIN metadata.sites s ON s.id=a.site_id
LEFT JOIN metadata.asset_types at ON at.id=a.asset_type_id
LEFT JOIN metadata.assets parent ON parent.id=a.parent_asset_id
LEFT JOIN metadata.buildings b ON b.id=a.building_id
LEFT JOIN metadata.floors f ON f.id=a.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=a.space_id
LEFT JOIN analytics.v_asset_meter_coverage_configuration c ON c.asset_id=a.id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,a.site_id)
ORDER BY o.name,s.name,b.name,f.name,sp.name,a.name,a.lifecycle_status;
$function$;

ALTER FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_devices(BIGINT) OWNER TO ems_admin;
ALTER FUNCTION admin.get_device_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.update_device_workspace(BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_gateways(BIGINT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_assets(BIGINT) OWNER TO ems_admin;

REVOKE ALL ON FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_devices(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.get_device_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_device_workspace(BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_gateways(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_assets(BIGINT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_devices(BIGINT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.get_device_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_device_workspace(BIGINT,UUID,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_gateways(BIGINT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_assets(BIGINT) TO ems_app;

CREATE OR REPLACE FUNCTION admin.get_asset_workspace(
    p_actor_portal_user_id BIGINT,p_asset_id UUID
)
RETURNS JSONB
LANGUAGE SQL SECURITY DEFINER STABLE
SET search_path TO pg_catalog, admin, metadata, analytics
AS $function$
WITH asset_row AS (
    SELECT a.id AS asset_id,a.organization_id,o.code AS organization_code,o.name AS organization_name,
           a.site_id,s.code AS site_code,s.name AS site_name,a.external_id,
           a.name AS asset_name,a.asset_type_id,at.name AS asset_type_name,
           a.parent_asset_id,parent.name AS parent_asset_name,
           a.building_id,b.name AS building_name,a.floor_id,f.name AS floor_name,
           a.space_id,sp.name AS space_name,
           concat_ws(' / ',o.name,s.name,b.name,f.name,sp.name) AS location_path,
           a.lifecycle_status,a.metering_requirement,c.coverage_status,
           a.created_at,a.updated_at,
           cr.commissioning_status,cr.is_ready,cr.blocking_reason_codes,cr.warning_reason_codes,
           (SELECT count(*) FROM metadata.asset_devices ad WHERE ad.asset_id=a.id) AS relationship_count
    FROM metadata.assets a
    JOIN metadata.organizations o ON o.id=a.organization_id
    JOIN metadata.sites s ON s.id=a.site_id
    LEFT JOIN metadata.asset_types at ON at.id=a.asset_type_id
    LEFT JOIN metadata.assets parent ON parent.id=a.parent_asset_id
    LEFT JOIN metadata.buildings b ON b.id=a.building_id
    LEFT JOIN metadata.floors f ON f.id=a.floor_id
    LEFT JOIN metadata.spaces sp ON sp.id=a.space_id
    LEFT JOIN analytics.v_asset_meter_coverage_configuration c ON c.asset_id=a.id
    LEFT JOIN analytics.v_commissioning_readiness cr
      ON cr.entity_type='ASSET' AND cr.entity_id=a.id
    WHERE a.id=p_asset_id
      AND admin.portal_user_can_access_site(p_actor_portal_user_id,a.site_id)
)
SELECT to_jsonb(asset_row) FROM asset_row;
$function$;

CREATE OR REPLACE FUNCTION admin.update_asset_workspace(
    p_actor_portal_user_id BIGINT,p_asset_id UUID,p_name TEXT,p_asset_type_id UUID,
    p_lifecycle_status TEXT,p_metering_requirement TEXT,p_building_id UUID,
    p_floor_id UUID,p_space_id UUID,p_parent_asset_id UUID,p_change_reason TEXT
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_reason TEXT:=btrim(p_change_reason);
    v_actor_username TEXT;
    v_before JSONB;
    v_result JSONB;
    v_audit_id UUID:=gen_random_uuid();
BEGIN
    IF v_reason IS NULL OR v_reason='' OR length(v_reason)>1000 THEN
        RAISE EXCEPTION 'Change reason is required and must not exceed 1000 characters.' USING ERRCODE='22023';
    END IF;
    SELECT pu.username INTO v_actor_username FROM admin.portal_users pu
    WHERE pu.portal_user_id=p_actor_portal_user_id AND pu.is_active;
    IF NOT FOUND THEN RAISE EXCEPTION 'Active portal actor was not found.' USING ERRCODE='42501'; END IF;
    SELECT to_jsonb(a) INTO v_before FROM metadata.assets a WHERE a.id=p_asset_id;
    v_result:=admin.update_asset(p_actor_portal_user_id,p_asset_id,p_name,p_asset_type_id,
        p_lifecycle_status,p_metering_requirement,p_building_id,p_floor_id,p_space_id,p_parent_asset_id);
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object(
        'operation','UPDATE_ASSET_WORKSPACE','actor_portal_user_id',p_actor_portal_user_id,
        'asset_id',p_asset_id,'before',v_before,'change_reason',v_reason),
        coalesce(v_result,'{}'::jsonb)||jsonb_build_object('workspace_audit_transaction_id',v_audit_id));
    RETURN coalesce(v_result,'{}'::jsonb)||jsonb_build_object('workspace_audit_transaction_id',v_audit_id);
END;
$function$;

ALTER FUNCTION admin.get_asset_workspace(BIGINT,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.update_asset_workspace(BIGINT,UUID,TEXT,UUID,TEXT,TEXT,UUID,UUID,UUID,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.get_asset_workspace(BIGINT,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.update_asset_workspace(BIGINT,UUID,TEXT,UUID,TEXT,TEXT,UUID,UUID,UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.get_asset_workspace(BIGINT,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.update_asset_workspace(BIGINT,UUID,TEXT,UUID,TEXT,TEXT,UUID,UUID,UUID,UUID,TEXT) TO ems_app;
