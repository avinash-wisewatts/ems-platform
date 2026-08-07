-- Epic 8 completion: relationship metadata, safe removal, and atomic primary-meter replacement (Stories 8.4-8.6)

ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS panel_name TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS feeder_name TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS breaker_identifier TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS channel_identifier TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS ct_ratio NUMERIC(12,4);
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS phase_designation TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS mounting_point TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS engineering_notes TEXT;
ALTER TABLE metadata.asset_devices ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE metadata.asset_devices DROP CONSTRAINT IF EXISTS asset_devices_ct_ratio_ck;
ALTER TABLE metadata.asset_devices ADD CONSTRAINT asset_devices_ct_ratio_ck CHECK (ct_ratio IS NULL OR (ct_ratio>0 AND ct_ratio<=100000));
ALTER TABLE metadata.asset_devices DROP CONSTRAINT IF EXISTS asset_devices_phase_designation_ck;
ALTER TABLE metadata.asset_devices ADD CONSTRAINT asset_devices_phase_designation_ck CHECK (phase_designation IS NULL OR phase_designation IN ('L1','L2','L3','N','L1_L2','L2_L3','L3_L1','THREE_PHASE'));

CREATE TABLE IF NOT EXISTS metadata.asset_device_relationship_history (
 history_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), relationship_id UUID NOT NULL,
 asset_id UUID NOT NULL, device_id UUID NOT NULL, relationship_type TEXT NOT NULL,
 panel_name TEXT, feeder_name TEXT, breaker_identifier TEXT, channel_identifier TEXT,
 ct_ratio NUMERIC(12,4), phase_designation TEXT, mounting_point TEXT, engineering_notes TEXT,
 relationship_created_at TIMESTAMPTZ NOT NULL, archived_at TIMESTAMPTZ NOT NULL DEFAULT now(),
 archived_by_portal_user_id BIGINT REFERENCES admin.portal_users(portal_user_id),
 archive_action TEXT NOT NULL CHECK (archive_action IN ('REMOVED','REPLACED')),
 archive_reason TEXT NOT NULL, replacement_relationship_id UUID, audit_transaction_id UUID NOT NULL
);
CREATE INDEX IF NOT EXISTS asset_device_relationship_history_relationship_idx ON metadata.asset_device_relationship_history(relationship_id,archived_at DESC);
CREATE INDEX IF NOT EXISTS asset_device_relationship_history_asset_idx ON metadata.asset_device_relationship_history(asset_id,archived_at DESC);

CREATE OR REPLACE FUNCTION metadata.assert_asset_device_relationship(p_asset_id UUID,p_device_id UUID,p_relationship_type TEXT) RETURNS VOID
LANGUAGE plpgsql STABLE SET search_path TO pg_catalog,metadata,config AS $function$
DECLARE v_asset metadata.assets%ROWTYPE; v_device metadata.devices%ROWTYPE; v_category UUID; v_type TEXT:=upper(btrim(p_relationship_type));
BEGIN
 IF NOT EXISTS (SELECT 1 FROM config.asset_device_relationship_types WHERE code=v_type AND is_active) THEN RAISE EXCEPTION 'Select a valid controlled relationship type.' USING ERRCODE='23514'; END IF;
 SELECT * INTO v_asset FROM metadata.assets WHERE id=p_asset_id; SELECT * INTO v_device FROM metadata.devices WHERE id=p_device_id;
 IF v_asset.id IS NULL OR v_device.id IS NULL THEN RAISE EXCEPTION 'Select an existing asset and device.' USING ERRCODE='23514'; END IF;
 IF v_asset.organization_id IS DISTINCT FROM v_device.organization_id THEN RAISE EXCEPTION 'Asset and device must belong to the same organization.' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS (SELECT 1 FROM metadata.gateways g WHERE g.id=v_device.gateway_id AND g.site_id=v_asset.site_id) THEN RAISE EXCEPTION 'Asset and device must belong to the same site.' USING ERRCODE='23514'; END IF;
 SELECT dm.device_category_id INTO v_category FROM metadata.device_models dm WHERE dm.id=v_device.device_model_id;
 IF NOT EXISTS (SELECT 1 FROM config.asset_device_relationship_category_compatibility c WHERE c.relationship_type=v_type AND c.device_category_id=v_category) THEN RAISE EXCEPTION 'Device category is not compatible with the selected relationship type.' USING ERRCODE='23514'; END IF;
 IF v_type='PRIMARY_METER' AND NOT EXISTS (SELECT 1 FROM config.device_categories dc WHERE dc.id=v_category AND lower(dc.name)='energy meter') THEN RAISE EXCEPTION 'A PRIMARY_METER must use a qualifying Energy Meter device.' USING ERRCODE='23514'; END IF;
END;$function$;

CREATE OR REPLACE FUNCTION metadata.validate_asset_device_relationship() RETURNS TRIGGER LANGUAGE plpgsql SET search_path TO pg_catalog,metadata,config AS $function$
BEGIN NEW.relationship_type:=upper(btrim(NEW.relationship_type)); PERFORM metadata.assert_asset_device_relationship(NEW.asset_id,NEW.device_id,NEW.relationship_type); NEW.updated_at:=now(); RETURN NEW; END;$function$;

DROP FUNCTION IF EXISTS admin.list_accessible_asset_device_relationships(BIGINT);
CREATE FUNCTION admin.list_accessible_asset_device_relationships(p_actor_portal_user_id BIGINT) RETURNS TABLE(relationship_id UUID,organization_id UUID,site_id UUID,site_name TEXT,asset_id UUID,asset_name TEXT,asset_status TEXT,metering_requirement TEXT,device_id UUID,device_name TEXT,device_external_id TEXT,device_category_name TEXT,relationship_type TEXT,relationship_name TEXT,exclusivity_policy TEXT,panel_name TEXT,feeder_name TEXT,breaker_identifier TEXT,channel_identifier TEXT,ct_ratio NUMERIC,phase_designation TEXT,mounting_point TEXT,engineering_notes TEXT,created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ)
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata,config AS $function$
SELECT ad.id,a.organization_id,a.site_id,s.name,a.id,a.name,a.status,a.metering_requirement,d.id,d.name,d.external_id,dc.name,ad.relationship_type,rt.name,rt.exclusivity_policy,ad.panel_name,ad.feeder_name,ad.breaker_identifier,ad.channel_identifier,ad.ct_ratio,ad.phase_designation,ad.mounting_point,ad.engineering_notes,ad.created_at,ad.updated_at
FROM metadata.asset_devices ad JOIN metadata.assets a ON a.id=ad.asset_id JOIN metadata.sites s ON s.id=a.site_id JOIN metadata.devices d ON d.id=ad.device_id JOIN metadata.device_models dm ON dm.id=d.device_model_id JOIN config.device_categories dc ON dc.id=dm.device_category_id JOIN config.asset_device_relationship_types rt ON rt.code=ad.relationship_type
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,a.site_id) ORDER BY s.name,a.name,rt.display_order,d.name;$function$;

CREATE OR REPLACE FUNCTION admin.update_asset_device_relationship_metadata(p_actor BIGINT,p_relationship UUID,p_panel TEXT,p_feeder TEXT,p_breaker TEXT,p_channel TEXT,p_ct NUMERIC,p_phase TEXT,p_mounting TEXT,p_notes TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata AS $function$
DECLARE v_actor TEXT; v_rel metadata.asset_devices%ROWTYPE; v_audit UUID:=gen_random_uuid(); v_result JSONB;
BEGIN
 SELECT username INTO v_actor FROM admin.portal_users WHERE portal_user_id=p_actor AND is_active; IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor,'asset.manage') THEN RAISE EXCEPTION 'Portal actor is not authorized to manage asset relationships.' USING ERRCODE='42501'; END IF;
 SELECT ad.* INTO v_rel FROM metadata.asset_devices ad JOIN metadata.assets a ON a.id=ad.asset_id WHERE ad.id=p_relationship AND admin.portal_user_can_access_site(p_actor,a.site_id) FOR UPDATE OF ad; IF NOT FOUND THEN RAISE EXCEPTION 'Relationship was not found or is not accessible.' USING ERRCODE='22023'; END IF;
 UPDATE metadata.asset_devices SET panel_name=nullif(btrim(p_panel),''),feeder_name=nullif(btrim(p_feeder),''),breaker_identifier=nullif(btrim(p_breaker),''),channel_identifier=nullif(btrim(p_channel),''),ct_ratio=p_ct,phase_designation=nullif(upper(btrim(p_phase)),''),mounting_point=nullif(btrim(p_mounting),''),engineering_notes=nullif(btrim(p_notes),''),updated_at=now() WHERE id=p_relationship;
 v_result:=jsonb_build_object('success',true,'relationship_id',p_relationship,'asset_id',v_rel.asset_id,'device_id',v_rel.device_id,'relationship_type',v_rel.relationship_type,'audit_transaction_id',v_audit);
 INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload) VALUES(v_audit,v_actor,jsonb_build_object('operation','UPDATE_RELATIONSHIP_METADATA','relationship_id',p_relationship,'before',to_jsonb(v_rel),'after',jsonb_build_object('panel_name',p_panel,'feeder_name',p_feeder,'breaker_identifier',p_breaker,'channel_identifier',p_channel,'ct_ratio',p_ct,'phase_designation',p_phase,'mounting_point',p_mounting,'engineering_notes',p_notes)),v_result); RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION admin.remove_asset_device_relationship(p_actor BIGINT,p_relationship UUID,p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata AS $function$
DECLARE v_actor TEXT; v_rel metadata.asset_devices%ROWTYPE; v_asset metadata.assets%ROWTYPE; v_audit UUID:=gen_random_uuid(); v_result JSONB;
BEGIN
 IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Removal reason is required.' USING ERRCODE='22023'; END IF;
 SELECT username INTO v_actor FROM admin.portal_users WHERE portal_user_id=p_actor AND is_active; IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor,'asset.manage') THEN RAISE EXCEPTION 'Portal actor is not authorized to manage asset relationships.' USING ERRCODE='42501'; END IF;
 SELECT ad.* INTO v_rel
 FROM metadata.asset_devices ad
 JOIN metadata.assets a ON a.id=ad.asset_id
 WHERE ad.id=p_relationship AND admin.portal_user_can_access_site(p_actor,a.site_id)
 FOR UPDATE OF ad;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'Relationship was not found or is not accessible.' USING ERRCODE='22023';
 END IF;

 SELECT a.* INTO v_asset
 FROM metadata.assets a
 WHERE a.id=v_rel.asset_id;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'The relationship asset was not found.' USING ERRCODE='22023';
 END IF;
 IF v_rel.relationship_type='PRIMARY_METER' AND lower(v_asset.status)='active' AND v_asset.metering_requirement='DIRECT_METER_REQUIRED' THEN RAISE EXCEPTION 'An active direct-metered asset must retain a PRIMARY_METER. Replace the meter or change the asset policy/status first.' USING ERRCODE='23514'; END IF;
 INSERT INTO metadata.asset_device_relationship_history(relationship_id,asset_id,device_id,relationship_type,panel_name,feeder_name,breaker_identifier,channel_identifier,ct_ratio,phase_designation,mounting_point,engineering_notes,relationship_created_at,archived_by_portal_user_id,archive_action,archive_reason,audit_transaction_id) SELECT id,asset_id,device_id,relationship_type,panel_name,feeder_name,breaker_identifier,channel_identifier,ct_ratio,phase_designation,mounting_point,engineering_notes,created_at,p_actor,'REMOVED',btrim(p_reason),v_audit FROM metadata.asset_devices WHERE id=p_relationship;
 DELETE FROM metadata.asset_devices WHERE id=p_relationship;
 v_result:=jsonb_build_object('success',true,'relationship_id',p_relationship,'asset_id',v_rel.asset_id,'device_id',v_rel.device_id,'relationship_type',v_rel.relationship_type,'removed',true,'audit_transaction_id',v_audit);
 INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload) VALUES(v_audit,v_actor,jsonb_build_object('operation','REMOVE_ASSET_DEVICE_RELATIONSHIP','relationship',to_jsonb(v_rel),'reason',btrim(p_reason)),v_result); RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION admin.replace_asset_primary_meter(p_actor BIGINT,p_relationship UUID,p_new_device UUID,p_reason TEXT) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog,admin,metadata AS $function$
DECLARE v_actor TEXT; v_old metadata.asset_devices%ROWTYPE; v_asset metadata.assets%ROWTYPE; v_new_relationship UUID:=gen_random_uuid(); v_audit UUID:=gen_random_uuid(); v_result JSONB;
BEGIN
 IF nullif(btrim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Replacement reason is required.' USING ERRCODE='22023'; END IF;
 SELECT username INTO v_actor FROM admin.portal_users WHERE portal_user_id=p_actor AND is_active; IF NOT FOUND OR NOT admin.portal_user_has_permission(p_actor,'asset.manage') THEN RAISE EXCEPTION 'Portal actor is not authorized to manage asset relationships.' USING ERRCODE='42501'; END IF;
 SELECT ad.* INTO v_old
 FROM metadata.asset_devices ad
 JOIN metadata.assets a ON a.id=ad.asset_id
 WHERE ad.id=p_relationship AND admin.portal_user_can_access_site(p_actor,a.site_id)
 FOR UPDATE OF ad;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'Relationship was not found or is not accessible.' USING ERRCODE='22023';
 END IF;

 SELECT a.* INTO v_asset
 FROM metadata.assets a
 WHERE a.id=v_old.asset_id;
 IF NOT FOUND THEN
  RAISE EXCEPTION 'The relationship asset was not found.' USING ERRCODE='22023';
 END IF;
 IF v_old.relationship_type<>'PRIMARY_METER' THEN RAISE EXCEPTION 'Only a PRIMARY_METER relationship can use atomic meter replacement.' USING ERRCODE='23514'; END IF;
 IF v_old.device_id=p_new_device THEN RAISE EXCEPTION 'Select a different replacement device.' USING ERRCODE='23514'; END IF;
 IF NOT EXISTS (SELECT 1 FROM metadata.devices d JOIN metadata.gateways g ON g.id=d.gateway_id WHERE d.id=p_new_device AND admin.portal_user_can_access_site(p_actor,g.site_id)) THEN RAISE EXCEPTION 'Replacement device was not found or is not accessible.' USING ERRCODE='22023'; END IF;
 PERFORM metadata.assert_asset_device_relationship(v_old.asset_id,p_new_device,'PRIMARY_METER');
 IF EXISTS (SELECT 1 FROM metadata.asset_devices WHERE device_id=p_new_device AND relationship_type='PRIMARY_METER') THEN RAISE EXCEPTION 'Replacement device already has a PRIMARY_METER assignment.' USING ERRCODE='23505'; END IF;
 DELETE FROM metadata.asset_devices WHERE id=p_relationship;
 INSERT INTO metadata.asset_devices(id,asset_id,device_id,relationship_type,panel_name,feeder_name,breaker_identifier,channel_identifier,ct_ratio,phase_designation,mounting_point,engineering_notes) VALUES(v_new_relationship,v_old.asset_id,p_new_device,'PRIMARY_METER',v_old.panel_name,v_old.feeder_name,v_old.breaker_identifier,v_old.channel_identifier,v_old.ct_ratio,v_old.phase_designation,v_old.mounting_point,v_old.engineering_notes);
 INSERT INTO metadata.asset_device_relationship_history(relationship_id,asset_id,device_id,relationship_type,panel_name,feeder_name,breaker_identifier,channel_identifier,ct_ratio,phase_designation,mounting_point,engineering_notes,relationship_created_at,archived_by_portal_user_id,archive_action,archive_reason,replacement_relationship_id,audit_transaction_id) VALUES(v_old.id,v_old.asset_id,v_old.device_id,v_old.relationship_type,v_old.panel_name,v_old.feeder_name,v_old.breaker_identifier,v_old.channel_identifier,v_old.ct_ratio,v_old.phase_designation,v_old.mounting_point,v_old.engineering_notes,v_old.created_at,p_actor,'REPLACED',btrim(p_reason),v_new_relationship,v_audit);
 v_result:=jsonb_build_object('success',true,'relationship_id',v_new_relationship,'replaced_relationship_id',p_relationship,'asset_id',v_old.asset_id,'device_id',p_new_device,'relationship_type','PRIMARY_METER','audit_transaction_id',v_audit);
 INSERT INTO admin.onboarding_audit(id,requested_by,request_payload,result_payload) VALUES(v_audit,v_actor,jsonb_build_object('operation','REPLACE_PRIMARY_METER','old_relationship',to_jsonb(v_old),'replacement_device_id',p_new_device,'reason',btrim(p_reason)),v_result); RETURN v_result;
END;$function$;

ALTER FUNCTION metadata.assert_asset_device_relationship(UUID,UUID,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_asset_device_relationships(BIGINT) OWNER TO ems_admin;
ALTER FUNCTION admin.update_asset_device_relationship_metadata(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.remove_asset_device_relationship(BIGINT,UUID,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.replace_asset_primary_meter(BIGINT,UUID,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.update_asset_device_relationship_metadata(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.remove_asset_device_relationship(BIGINT,UUID,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.replace_asset_primary_meter(BIGINT,UUID,UUID,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION admin.update_asset_device_relationship_metadata(BIGINT,UUID,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.remove_asset_device_relationship(BIGINT,UUID,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.replace_asset_primary_meter(BIGINT,UUID,UUID,TEXT) TO ems_app;
