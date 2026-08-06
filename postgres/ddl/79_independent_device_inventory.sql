-- Epic 7: independent device inventory (Stories 7.1, 7.2, 7.3)

ALTER TABLE metadata.devices
    ADD COLUMN IF NOT EXISTS building_id UUID REFERENCES metadata.buildings(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS floor_id UUID REFERENCES metadata.floors(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS space_id UUID REFERENCES metadata.spaces(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS devices_building_id_idx ON metadata.devices(building_id);
CREATE INDEX IF NOT EXISTS devices_floor_id_idx ON metadata.devices(floor_id);
CREATE INDEX IF NOT EXISTS devices_space_id_idx ON metadata.devices(space_id);

CREATE OR REPLACE FUNCTION metadata.validate_device_physical_location()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path TO pg_catalog, metadata, admin
AS $function$
DECLARE v_gateway metadata.gateways%ROWTYPE;
BEGIN
    SELECT * INTO v_gateway FROM metadata.gateways WHERE id=NEW.gateway_id;
    IF NOT FOUND OR v_gateway.organization_id IS DISTINCT FROM NEW.organization_id THEN
        RAISE EXCEPTION 'Device organization must match its gateway.' USING ERRCODE='23514';
    END IF;
    IF NEW.building_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.buildings b
        WHERE b.id=NEW.building_id AND b.site_id=v_gateway.site_id
          AND b.organization_id=NEW.organization_id
    ) THEN RAISE EXCEPTION 'Device building does not belong to the gateway site.' USING ERRCODE='23514'; END IF;
    IF NEW.floor_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.floors f JOIN metadata.buildings b ON b.id=f.building_id
        WHERE f.id=NEW.floor_id AND b.site_id=v_gateway.site_id
          AND f.organization_id=NEW.organization_id
          AND (NEW.building_id IS NULL OR b.id=NEW.building_id)
    ) THEN RAISE EXCEPTION 'Device floor does not belong to the selected building and gateway site.' USING ERRCODE='23514'; END IF;
    IF NEW.space_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM metadata.spaces sp JOIN metadata.floors f ON f.id=sp.floor_id
        JOIN metadata.buildings b ON b.id=f.building_id
        WHERE sp.id=NEW.space_id AND b.site_id=v_gateway.site_id
          AND sp.organization_id=NEW.organization_id
          AND (NEW.floor_id IS NULL OR f.id=NEW.floor_id)
          AND (NEW.building_id IS NULL OR b.id=NEW.building_id)
    ) THEN RAISE EXCEPTION 'Device space does not belong to the selected floor and gateway site.' USING ERRCODE='23514'; END IF;
    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validate_device_physical_location ON metadata.devices;
CREATE TRIGGER trg_validate_device_physical_location
BEFORE INSERT OR UPDATE OF organization_id,gateway_id,building_id,floor_id,space_id
ON metadata.devices FOR EACH ROW EXECUTE FUNCTION metadata.validate_device_physical_location();

CREATE OR REPLACE FUNCTION admin.create_device(
    p_actor_portal_user_id BIGINT, p_gateway_id UUID, p_name TEXT,
    p_external_id TEXT, p_device_category_id UUID, p_device_model_id UUID,
    p_profile_id UUID, p_protocol TEXT, p_lifecycle_status TEXT,
    p_firmware_version TEXT DEFAULT NULL, p_use_gateway_location BOOLEAN DEFAULT FALSE,
    p_building_id UUID DEFAULT NULL, p_floor_id UUID DEFAULT NULL, p_space_id UUID DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog,admin,metadata,config
AS $function$
DECLARE
    v_actor_username TEXT; v_gateway metadata.gateways%ROWTYPE;
    v_name TEXT:=btrim(p_name); v_external_id TEXT:=upper(btrim(p_external_id));
    v_protocol TEXT:=upper(btrim(p_protocol)); v_lifecycle TEXT:=upper(btrim(p_lifecycle_status));
    v_building UUID:=p_building_id; v_floor UUID:=p_floor_id; v_space UUID:=p_space_id;
    v_device_id UUID; v_audit_id UUID:=gen_random_uuid(); v_result JSONB;
BEGIN
    SELECT username INTO v_actor_username FROM admin.portal_users
    WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
    IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'device.manage') THEN
        RAISE EXCEPTION 'Portal actor is not authorized to create devices.' USING ERRCODE='42501';
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
    IF v_lifecycle NOT IN ('REGISTERED','ACTIVE','INACTIVE','DECOMMISSIONED') THEN
        RAISE EXCEPTION 'Select a valid device lifecycle status.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.device_models dm
                   WHERE dm.id=p_device_model_id AND dm.device_category_id=p_device_category_id) THEN
        RAISE EXCEPTION 'Device model does not match the selected category.' USING ERRCODE='22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM config.device_profiles dp
                   JOIN config.device_profile_categories dpc ON dpc.profile_id=dp.id
                   WHERE dp.id=p_profile_id AND dp.is_active=TRUE
                     AND dpc.device_category_id=p_device_category_id) THEN
        RAISE EXCEPTION 'Device profile is not compatible with the selected category.' USING ERRCODE='22023';
    END IF;
    IF p_use_gateway_location THEN
        IF p_building_id IS NOT NULL OR p_floor_id IS NOT NULL OR p_space_id IS NOT NULL THEN
            RAISE EXCEPTION 'Do not submit a device location when using the gateway location.' USING ERRCODE='22023';
        END IF;
        v_building:=v_gateway.building_id; v_floor:=v_gateway.floor_id; v_space:=v_gateway.space_id;
    END IF;
    INSERT INTO metadata.devices(
        organization_id,gateway_id,device_model_id,profile_id,name,external_id,
        firmware_version,protocol,lifecycle_status,building_id,floor_id,space_id
    ) VALUES (
        v_gateway.organization_id,p_gateway_id,p_device_model_id,p_profile_id,v_name,
        v_external_id,nullif(btrim(p_firmware_version),''),v_protocol,v_lifecycle,
        v_building,v_floor,v_space
    ) RETURNING id INTO v_device_id;
    v_result:=jsonb_build_object(
        'success',TRUE,'entity_type','DEVICE','entity_id',v_device_id,'device_id',v_device_id,
        'organization_id',v_gateway.organization_id,'site_id',v_gateway.site_id,'gateway_id',p_gateway_id,
        'device_name',v_name,'external_id',v_external_id,'device_category_id',p_device_category_id,
        'device_model_id',p_device_model_id,'profile_id',p_profile_id,'protocol',v_protocol,
        'building_id',v_building,'floor_id',v_floor,'space_id',v_space,
        'location_source',CASE WHEN p_use_gateway_location THEN 'GATEWAY_EXPLICIT' ELSE 'DEVICE' END,
        'lifecycle_status',v_lifecycle,'commissioning_status','NOT_STARTED',
        'validation_warnings','[]'::jsonb,'blocking_conditions','[]'::jsonb,
        'audit_transaction_id',v_audit_id
    );
    INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload)
    VALUES(v_audit_id,v_actor_username,jsonb_build_object(
        'operation','CREATE_DEVICE','actor_portal_user_id',p_actor_portal_user_id,
        'gateway_id',p_gateway_id,'organization_id',v_gateway.organization_id,'site_id',v_gateway.site_id,
        'name',v_name,'external_id',v_external_id,'device_category_id',p_device_category_id,
        'device_model_id',p_device_model_id,'profile_id',p_profile_id,'protocol',v_protocol,
        'lifecycle_status',v_lifecycle,'use_gateway_location',p_use_gateway_location,
        'building_id',v_building,'floor_id',v_floor,'space_id',v_space),v_result);
    RETURN v_result;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'A device with this external ID already exists in the organization.' USING ERRCODE='23505';
END;
$function$;

DROP FUNCTION IF EXISTS admin.list_accessible_devices(BIGINT);
CREATE FUNCTION admin.list_accessible_devices(p_actor_portal_user_id BIGINT)
RETURNS TABLE(
    organization_id UUID,site_id UUID,site_name TEXT,gateway_id UUID,gateway_name TEXT,
    gateway_external_id TEXT,device_id UUID,device_name TEXT,external_id TEXT,
    device_category_id UUID,device_category_name TEXT,device_model_id UUID,
    device_vendor TEXT,device_model TEXT,profile_id UUID,profile_code TEXT,
    protocol TEXT,lifecycle_status TEXT,building_id UUID,building_name TEXT,
    floor_id UUID,floor_name TEXT,space_id UUID,space_name TEXT
) LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog,admin,metadata,config
AS $function$
SELECT d.organization_id,g.site_id,s.name,g.id,g.name,g.external_id,d.id,d.name,d.external_id,
       dm.device_category_id,dc.name,d.device_model_id,dm.vendor,dm.model,d.profile_id,dp.profile_code,
       d.protocol,d.lifecycle_status,d.building_id,b.name,d.floor_id,f.name,d.space_id,sp.name
FROM metadata.devices d JOIN metadata.gateways g ON g.id=d.gateway_id
JOIN metadata.sites s ON s.id=g.site_id
JOIN metadata.device_models dm ON dm.id=d.device_model_id
JOIN config.device_categories dc ON dc.id=dm.device_category_id
JOIN config.device_profiles dp ON dp.id=d.profile_id
LEFT JOIN metadata.buildings b ON b.id=d.building_id
LEFT JOIN metadata.floors f ON f.id=d.floor_id
LEFT JOIN metadata.spaces sp ON sp.id=d.space_id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,g.site_id)
ORDER BY s.name,g.name,d.name;
$function$;

ALTER FUNCTION metadata.validate_device_physical_location() OWNER TO ems_admin;
ALTER FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_devices(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION metadata.validate_device_physical_location() FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_devices(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.create_device(BIGINT,UUID,TEXT,TEXT,UUID,UUID,UUID,TEXT,TEXT,TEXT,BOOLEAN,UUID,UUID,UUID) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_devices(BIGINT) TO ems_app;
