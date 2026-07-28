-- Canonical Epic 8 asset-device relationship management contract

CREATE TABLE IF NOT EXISTS config.asset_device_relationship_types (
    code TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    exclusivity_policy TEXT NOT NULL CHECK (exclusivity_policy IN ('NON_EXCLUSIVE','ASSET_AND_DEVICE_UNIQUE')),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    display_order INTEGER NOT NULL
);

INSERT INTO config.asset_device_relationship_types(code,name,description,exclusivity_policy,is_active,display_order) VALUES
('PRIMARY_METER','Primary meter','Authoritative energy meter for one asset.','ASSET_AND_DEVICE_UNIQUE',TRUE,10),
('SECONDARY_METER','Secondary meter','Additional energy meter associated with an asset.','NON_EXCLUSIVE',TRUE,20),
('TEMPERATURE_SENSOR','Temperature sensor','Temperature measurement associated with an asset.','NON_EXCLUSIVE',TRUE,30),
('PRESSURE_SENSOR','Pressure sensor','Pressure measurement associated with an asset.','NON_EXCLUSIVE',TRUE,40),
('FLOW_SENSOR','Flow sensor','Flow measurement associated with an asset.','NON_EXCLUSIVE',TRUE,50),
('VIBRATION_SENSOR','Vibration sensor','Vibration measurement associated with an asset.','NON_EXCLUSIVE',TRUE,60),
('RUN_STATUS','Run status','Binary running-state input associated with an asset.','NON_EXCLUSIVE',TRUE,70),
('FAULT_STATUS','Fault status','Binary fault-state input associated with an asset.','NON_EXCLUSIVE',TRUE,80),
('STATUS_INPUT','Status input','General binary status input associated with an asset.','NON_EXCLUSIVE',TRUE,90)
ON CONFLICT (code) DO UPDATE SET name=EXCLUDED.name,description=EXCLUDED.description,exclusivity_policy=EXCLUDED.exclusivity_policy,is_active=EXCLUDED.is_active,display_order=EXCLUDED.display_order;

-- Preserve pre-existing legacy values for readability, but prevent new use.
INSERT INTO config.asset_device_relationship_types(code,name,description,exclusivity_policy,is_active,display_order)
SELECT DISTINCT upper(btrim(ad.relationship_type)), initcap(replace(lower(btrim(ad.relationship_type)),'_',' ')), 'Legacy relationship retained for historical compatibility.', 'NON_EXCLUSIVE', FALSE, 1000
FROM metadata.asset_devices ad
WHERE nullif(btrim(ad.relationship_type),'') IS NOT NULL
ON CONFLICT (code) DO NOTHING;

INSERT INTO config.device_categories(name,description) VALUES
('Vibration Sensor','Dedicated vibration measurement device')
ON CONFLICT (name) DO NOTHING;

CREATE TABLE IF NOT EXISTS config.asset_device_relationship_category_compatibility (
    relationship_type TEXT NOT NULL REFERENCES config.asset_device_relationship_types(code),
    device_category_id UUID NOT NULL REFERENCES config.device_categories(id),
    PRIMARY KEY (relationship_type,device_category_id)
);

INSERT INTO config.asset_device_relationship_category_compatibility(relationship_type,device_category_id)
SELECT mapping.relationship_type, dc.id
FROM (VALUES
 ('PRIMARY_METER','Energy Meter'),('SECONDARY_METER','Energy Meter'),
 ('TEMPERATURE_SENSOR','Temperature Sensor'),('TEMPERATURE_SENSOR','Environmental Sensor'),
 ('PRESSURE_SENSOR','Pressure Sensor'),('FLOW_SENSOR','Flow Meter'),('VIBRATION_SENSOR','Vibration Sensor'),
 ('RUN_STATUS','Digital Input Module'),('RUN_STATUS','PLC'),('RUN_STATUS','BMS Controller'),
 ('FAULT_STATUS','Digital Input Module'),('FAULT_STATUS','PLC'),('FAULT_STATUS','BMS Controller'),
 ('STATUS_INPUT','Digital Input Module'),('STATUS_INPUT','PLC'),('STATUS_INPUT','BMS Controller')
) AS mapping(relationship_type,category_name)
JOIN config.device_categories dc ON lower(dc.name)=lower(mapping.category_name)
ON CONFLICT DO NOTHING;

ALTER TABLE metadata.asset_devices DROP CONSTRAINT IF EXISTS asset_devices_relationship_type_fkey;
ALTER TABLE metadata.asset_devices ADD CONSTRAINT asset_devices_relationship_type_fkey FOREIGN KEY (relationship_type) REFERENCES config.asset_device_relationship_types(code);

CREATE UNIQUE INDEX IF NOT EXISTS asset_devices_primary_meter_asset_uq ON metadata.asset_devices(asset_id) WHERE relationship_type='PRIMARY_METER';
CREATE UNIQUE INDEX IF NOT EXISTS asset_devices_primary_meter_device_uq ON metadata.asset_devices(device_id) WHERE relationship_type='PRIMARY_METER';

CREATE OR REPLACE FUNCTION metadata.validate_asset_device_relationship() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path TO pg_catalog,metadata,config AS $function$
DECLARE v_asset metadata.assets%ROWTYPE; v_device metadata.devices%ROWTYPE; v_category UUID; v_type config.asset_device_relationship_types%ROWTYPE;
BEGIN
 NEW.relationship_type:=upper(btrim(NEW.relationship_type));
 SELECT * INTO v_type FROM config.asset_device_relationship_types WHERE code=NEW.relationship_type AND is_active=TRUE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Select a valid controlled relationship type.' USING ERRCODE='23514'; END IF;
 SELECT * INTO v_asset FROM metadata.assets WHERE id=NEW.asset_id;
 SELECT * INTO v_device FROM metadata.devices WHERE id=NEW.device_id;
 IF v_asset.id IS NULL OR v_device.id IS NULL THEN RAISE EXCEPTION 'Select an existing asset and device.' USING ERRCODE='23514'; END IF;
 IF v_asset.organization_id IS DISTINCT FROM v_device.organization_id THEN RAISE EXCEPTION 'Asset and device must belong to the same organization.' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS (SELECT 1 FROM metadata.gateways g WHERE g.id=v_device.gateway_id AND g.site_id=v_asset.site_id) THEN RAISE EXCEPTION 'Asset and device must belong to the same site.' USING ERRCODE='23514'; END IF;
 SELECT dm.device_category_id INTO v_category FROM metadata.device_models dm WHERE dm.id=v_device.device_model_id;
 IF NOT EXISTS (SELECT 1 FROM config.asset_device_relationship_category_compatibility c WHERE c.relationship_type=NEW.relationship_type AND c.device_category_id=v_category) THEN RAISE EXCEPTION 'Device category is not compatible with the selected relationship type.' USING ERRCODE='23514'; END IF;
 IF NEW.relationship_type='PRIMARY_METER' AND NOT EXISTS (SELECT 1 FROM config.device_categories dc WHERE dc.id=v_category AND lower(dc.name)='energy meter') THEN RAISE EXCEPTION 'A PRIMARY_METER must use a qualifying Energy Meter device.' USING ERRCODE='23514'; END IF;
 RETURN NEW;
END;$function$;

DROP TRIGGER IF EXISTS trg_validate_asset_device_relationship ON metadata.asset_devices;
CREATE TRIGGER trg_validate_asset_device_relationship BEFORE INSERT OR UPDATE OF asset_id,device_id,relationship_type ON metadata.asset_devices FOR EACH ROW EXECUTE FUNCTION metadata.validate_asset_device_relationship();

CREATE OR REPLACE FUNCTION admin.assign_device_to_asset(p_actor_portal_user_id BIGINT,p_asset_id UUID,p_device_id UUID,p_relationship_type TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata,config AS $function$
DECLARE v_actor TEXT; v_asset metadata.assets%ROWTYPE; v_device metadata.devices%ROWTYPE; v_site UUID; v_relationship UUID; v_audit UUID:=gen_random_uuid(); v_type TEXT:=upper(btrim(p_relationship_type)); v_result JSONB;
BEGIN
 SELECT username INTO v_actor FROM admin.portal_users WHERE portal_user_id=p_actor_portal_user_id AND is_active=TRUE;
 IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'asset.manage') THEN RAISE EXCEPTION 'Portal actor is not authorized to manage asset relationships.' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_asset FROM metadata.assets WHERE id=p_asset_id; IF NOT FOUND THEN RAISE EXCEPTION 'Asset was not found.' USING ERRCODE='22023'; END IF;
 SELECT d.* INTO v_device FROM metadata.devices d WHERE d.id=p_device_id; IF NOT FOUND THEN RAISE EXCEPTION 'Device was not found.' USING ERRCODE='22023'; END IF;
 SELECT g.site_id INTO v_site FROM metadata.gateways g WHERE g.id=v_device.gateway_id;
 IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_asset.site_id) OR NOT admin.portal_user_can_access_site(p_actor_portal_user_id,v_site) THEN RAISE EXCEPTION 'Portal actor cannot access the selected asset and device site.' USING ERRCODE='42501'; END IF;
 INSERT INTO metadata.asset_devices(asset_id,device_id,relationship_type) VALUES(p_asset_id,p_device_id,v_type) RETURNING id INTO v_relationship;
 v_result:=jsonb_build_object('success',TRUE,'entity_type','ASSET_DEVICE_RELATIONSHIP','entity_id',v_relationship,'relationship_id',v_relationship,'asset_id',p_asset_id,'device_id',p_device_id,'relationship_type',v_type,'organization_id',v_asset.organization_id,'site_id',v_asset.site_id,'audit_transaction_id',v_audit);
 INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload) VALUES(v_audit,v_actor,jsonb_build_object('operation','ASSIGN_DEVICE_TO_ASSET','actor_portal_user_id',p_actor_portal_user_id,'asset_id',p_asset_id,'device_id',p_device_id,'relationship_type',v_type),v_result);
 RETURN v_result;
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'This relationship already exists, or the asset/device already has a PRIMARY_METER assignment.' USING ERRCODE='23505';
END;$function$;

DROP FUNCTION IF EXISTS admin.list_accessible_asset_device_relationships(BIGINT);
CREATE FUNCTION admin.list_accessible_asset_device_relationships(p_actor_portal_user_id BIGINT) RETURNS TABLE(relationship_id UUID,organization_id UUID,site_id UUID,site_name TEXT,asset_id UUID,asset_name TEXT,device_id UUID,device_name TEXT,device_external_id TEXT,device_category_name TEXT,relationship_type TEXT,relationship_name TEXT,exclusivity_policy TEXT,created_at TIMESTAMPTZ)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata,config AS $function$
SELECT ad.id,a.organization_id,a.site_id,s.name,a.id,a.name,d.id,d.name,d.external_id,dc.name,ad.relationship_type,rt.name,rt.exclusivity_policy,ad.created_at
FROM metadata.asset_devices ad JOIN metadata.assets a ON a.id=ad.asset_id JOIN metadata.sites s ON s.id=a.site_id JOIN metadata.devices d ON d.id=ad.device_id JOIN metadata.device_models dm ON dm.id=d.device_model_id JOIN config.device_categories dc ON dc.id=dm.device_category_id JOIN config.asset_device_relationship_types rt ON rt.code=ad.relationship_type
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,a.site_id) ORDER BY s.name,a.name,rt.display_order,d.name;$function$;

-- Coverage counts only category-compatible qualifying primary meters.
CREATE OR REPLACE VIEW analytics.v_asset_meter_coverage_configuration WITH (security_barrier=TRUE) AS
WITH direct_meter AS (
 SELECT ad.asset_id,count(*) AS direct_primary_meter_count,min(ad.device_id::text)::uuid AS direct_primary_meter_device_id
 FROM metadata.asset_devices ad JOIN metadata.devices d ON d.id=ad.device_id JOIN metadata.device_models dm ON dm.id=d.device_model_id JOIN config.device_categories dc ON dc.id=dm.device_category_id JOIN config.asset_device_relationship_category_compatibility c ON c.relationship_type=ad.relationship_type AND c.device_category_id=dc.id
 WHERE ad.relationship_type='PRIMARY_METER' AND lower(dc.name)='energy meter' GROUP BY ad.asset_id
), required_descendants AS (
 SELECT hc.ancestor_asset_id AS asset_id,count(*) AS required_descendant_count,count(*) FILTER (WHERE descendant_meter.asset_id IS NOT NULL) AS configured_required_descendant_count,count(*) FILTER (WHERE descendant_meter.asset_id IS NULL) AS missing_required_descendant_count
 FROM analytics.v_asset_hierarchy_closure hc JOIN metadata.assets descendant ON descendant.id=hc.descendant_asset_id AND descendant.organization_id=hc.organization_id AND descendant.site_id=hc.site_id LEFT JOIN direct_meter descendant_meter ON descendant_meter.asset_id=descendant.id
 WHERE hc.depth>0 AND descendant.status='active' AND descendant.metering_requirement='DIRECT_METER_REQUIRED' GROUP BY hc.ancestor_asset_id
)
SELECT asset.grafana_org_id,asset.organization_id,asset.site_id,asset.site_code,asset.site_name,asset.asset_id,asset.asset_name,asset.asset_type,asset.parent_asset_id,asset.parent_asset_name,asset.status AS asset_status,asset.metering_requirement,(asset.status='active' AND asset.metering_requirement<>'NOT_REQUIRED') AS is_coverage_in_scope,COALESCE(dm.direct_primary_meter_count,0) AS direct_primary_meter_count,dm.direct_primary_meter_device_id,COALESCE(rd.required_descendant_count,0) AS required_descendant_count,COALESCE(rd.configured_required_descendant_count,0) AS configured_required_descendant_count,COALESCE(rd.missing_required_descendant_count,0) AS missing_required_descendant_count,
CASE WHEN asset.status<>'active' THEN 'OUT_OF_SCOPE_INACTIVE' WHEN asset.metering_requirement='NOT_REQUIRED' THEN 'EXCLUDED' WHEN asset.metering_requirement='DIRECT_METER_REQUIRED' AND COALESCE(dm.direct_primary_meter_count,0)=1 THEN 'CONFIGURED' WHEN asset.metering_requirement='DIRECT_METER_REQUIRED' THEN 'MISSING_DIRECT_METER' WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' AND COALESCE(rd.required_descendant_count,0)=0 THEN 'NO_REQUIRED_DESCENDANTS' WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' AND COALESCE(rd.missing_required_descendant_count,0)=0 THEN 'CONFIGURED' WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' AND COALESCE(rd.configured_required_descendant_count,0)>0 THEN 'PARTIALLY_CONFIGURED' WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' THEN 'MISSING_DESCENDANT_COVERAGE' ELSE 'UNKNOWN_POLICY' END AS coverage_status,
CASE WHEN asset.status<>'active' OR asset.metering_requirement='NOT_REQUIRED' THEN NULL WHEN asset.metering_requirement='DIRECT_METER_REQUIRED' THEN CASE WHEN COALESCE(dm.direct_primary_meter_count,0)=1 THEN 100.0 ELSE 0.0 END WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' AND COALESCE(rd.required_descendant_count,0)=0 THEN NULL WHEN asset.metering_requirement='DESCENDANT_COVERAGE_ALLOWED' THEN round(100.0*COALESCE(rd.configured_required_descendant_count,0)/NULLIF(rd.required_descendant_count,0),2) ELSE NULL END AS configuration_coverage_percent
FROM analytics.v_assets asset LEFT JOIN direct_meter dm ON dm.asset_id=asset.asset_id LEFT JOIN required_descendants rd ON rd.asset_id=asset.asset_id;

ALTER FUNCTION metadata.validate_asset_device_relationship() OWNER TO ems_admin; ALTER FUNCTION admin.assign_device_to_asset(BIGINT,UUID,UUID,TEXT) OWNER TO ems_admin; ALTER FUNCTION admin.list_accessible_asset_device_relationships(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.assign_device_to_asset(BIGINT,UUID,UUID,TEXT) FROM PUBLIC; REVOKE ALL ON FUNCTION admin.list_accessible_asset_device_relationships(BIGINT) FROM PUBLIC; GRANT EXECUTE ON FUNCTION admin.assign_device_to_asset(BIGINT,UUID,UUID,TEXT) TO ems_app; GRANT EXECUTE ON FUNCTION admin.list_accessible_asset_device_relationships(BIGINT) TO ems_app; GRANT SELECT ON config.asset_device_relationship_types TO ems_app;
