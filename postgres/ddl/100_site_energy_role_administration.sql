-- Epic 13: controlled site energy-balance roles and audited meter assignment.

CREATE TABLE IF NOT EXISTS config.site_energy_roles (
  role_code TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL,
  balance_direction TEXT NOT NULL,
  is_exclusive_per_site BOOLEAN NOT NULL DEFAULT FALSE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  display_order INTEGER NOT NULL,
  CONSTRAINT site_energy_roles_code_chk CHECK (role_code=upper(btrim(role_code)) AND role_code ~ '^[A-Z][A-Z0-9_]*$'),
  CONSTRAINT site_energy_roles_direction_chk CHECK (balance_direction IN ('IMPORT','EXPORT','CONSUMPTION','GENERATION','STORAGE_CHARGE','STORAGE_DISCHARGE')),
  CONSTRAINT site_energy_roles_text_chk CHECK (btrim(display_name)<>'' AND btrim(description)<>''),
  CONSTRAINT site_energy_roles_order_chk CHECK (display_order>0)
);

INSERT INTO config.site_energy_roles(role_code,display_name,description,balance_direction,is_exclusive_per_site,is_active,display_order) VALUES
 ('GRID_IMPORT','Grid import','Utility energy imported into the site.','IMPORT',FALSE,TRUE,10),
 ('GRID_EXPORT','Grid export','Utility energy exported from the site.','EXPORT',FALSE,TRUE,20),
 ('SITE_CONSUMPTION','Site consumption','Authoritative directly measured total site consumption.','CONSUMPTION',TRUE,TRUE,30),
 ('SOLAR_GENERATION','Solar generation','Solar photovoltaic generation supplied within the site.','GENERATION',FALSE,TRUE,40),
 ('GENERATOR_OUTPUT','Generator output','On-site generator energy supplied within the site.','GENERATION',FALSE,TRUE,50),
 ('BATTERY_CHARGE','Battery charging','Energy absorbed while charging site battery storage.','STORAGE_CHARGE',FALSE,TRUE,60),
 ('BATTERY_DISCHARGE','Battery discharging','Energy supplied while discharging site battery storage.','STORAGE_DISCHARGE',FALSE,TRUE,70),
 ('LOAD_SUBMETER','Legacy load submeter','Legacy role retained only for historical rows.','CONSUMPTION',FALSE,FALSE,900)
ON CONFLICT(role_code) DO UPDATE SET
 display_name=excluded.display_name,description=excluded.description,balance_direction=excluded.balance_direction,
 is_exclusive_per_site=excluded.is_exclusive_per_site,is_active=excluded.is_active,display_order=excluded.display_order;

-- Remove the legacy role check before normalizing historical values.
-- Otherwise SOLAR_GENERATION would be rejected by the old constraint.
ALTER TABLE config.site_energy_meter_roles
  DROP CONSTRAINT IF EXISTS ck_site_energy_meter_role;

ALTER TABLE config.site_energy_meter_roles
  DROP CONSTRAINT IF EXISTS site_energy_meter_roles_meter_role_fkey;

UPDATE config.site_energy_meter_roles
SET meter_role = 'SOLAR_GENERATION',
    updated_at = now()
WHERE meter_role = 'ONSITE_GENERATION';

ALTER TABLE config.site_energy_meter_roles
  ADD CONSTRAINT site_energy_meter_roles_meter_role_fkey
  FOREIGN KEY (meter_role)
  REFERENCES config.site_energy_roles(role_code);

CREATE OR REPLACE FUNCTION config.validate_site_energy_meter_role()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path TO pg_catalog,config,metadata AS $function$
DECLARE
 v_device_site UUID; v_device_org UUID; v_category TEXT; v_device_status TEXT;
 v_site_org UUID; v_site_status TEXT; v_role_active BOOLEAN; v_exclusive BOOLEAN;
BEGIN
 NEW.meter_role:=upper(btrim(NEW.meter_role));
 SELECT r.is_active,r.is_exclusive_per_site INTO v_role_active,v_exclusive
 FROM config.site_energy_roles r WHERE r.role_code=NEW.meter_role;
 IF NOT FOUND OR NOT v_role_active THEN RAISE EXCEPTION 'Select an active controlled site energy role.' USING ERRCODE='23514'; END IF;

 SELECT s.organization_id,s.lifecycle_status INTO v_site_org,v_site_status FROM metadata.sites s WHERE s.id=NEW.site_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Site was not found.' USING ERRCODE='23514'; END IF;
 IF v_site_status='DECOMMISSIONED' THEN RAISE EXCEPTION 'New site energy roles cannot target a decommissioned site.' USING ERRCODE='23514'; END IF;

 SELECT g.site_id,g.organization_id,dc.name,d.lifecycle_status
 INTO v_device_site,v_device_org,v_category,v_device_status
 FROM metadata.devices d
 JOIN metadata.gateways g ON g.id=d.gateway_id
 JOIN metadata.device_models dm ON dm.id=d.device_model_id
 JOIN config.device_categories dc ON dc.id=dm.device_category_id
 WHERE d.id=NEW.device_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Device was not found or lacks a valid model category.' USING ERRCODE='23514'; END IF;
 IF lower(v_category)<>'energy meter' THEN RAISE EXCEPTION 'A site energy role requires a qualifying Energy Meter device.' USING ERRCODE='23514'; END IF;
 IF v_device_status='DECOMMISSIONED' THEN RAISE EXCEPTION 'New site energy roles cannot use a decommissioned device.' USING ERRCODE='23514'; END IF;
 IF v_device_site<>NEW.site_id OR v_device_org<>v_site_org THEN RAISE EXCEPTION 'Device and site must belong to the same tenant and site.' USING ERRCODE='23514'; END IF;

 IF v_exclusive AND NEW.is_active AND EXISTS(
   SELECT 1 FROM config.site_energy_meter_roles x
   WHERE x.site_id=NEW.site_id AND x.meter_role=NEW.meter_role AND x.is_active
     AND x.id<>COALESCE(NEW.id,gen_random_uuid())
     AND x.effective_range && tstzrange(NEW.effective_from,COALESCE(NEW.effective_to,'infinity'::timestamptz),'[)')
 ) THEN RAISE EXCEPTION 'Only one active % role may apply to a site for an overlapping period.',NEW.meter_role USING ERRCODE='23505'; END IF;
 RETURN NEW;
END;$function$;

DROP TRIGGER IF EXISTS trg_validate_site_energy_meter_role ON config.site_energy_meter_roles;
CREATE TRIGGER trg_validate_site_energy_meter_role
BEFORE INSERT OR UPDATE OF site_id,device_id,meter_role,effective_from,effective_to,is_active
ON config.site_energy_meter_roles FOR EACH ROW EXECUTE FUNCTION config.validate_site_energy_meter_role();

CREATE OR REPLACE FUNCTION admin.assign_site_energy_meter_role(
 p_actor_portal_user_id BIGINT,p_site_id UUID,p_device_id UUID,p_meter_role TEXT,
 p_allocation_factor NUMERIC DEFAULT 1,p_is_authoritative BOOLEAN DEFAULT TRUE,
 p_effective_from TIMESTAMPTZ DEFAULT now(),p_effective_to TIMESTAMPTZ DEFAULT NULL,p_description TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog,admin,config,metadata AS $function$
DECLARE v_active BOOLEAN; v_org UUID; v_id UUID; v_tx UUID:=gen_random_uuid(); v_role TEXT:=upper(btrim(p_meter_role)); v_result JSONB;
BEGIN
 SELECT u.is_active INTO v_active FROM admin.portal_users u WHERE u.portal_user_id=p_actor_portal_user_id;
 IF NOT FOUND OR NOT v_active OR NOT admin.portal_user_has_permission(p_actor_portal_user_id,'site.manage') THEN
   RAISE EXCEPTION 'Portal actor is not authorized to manage site energy roles.' USING ERRCODE='42501';
 END IF;
 IF NOT admin.portal_user_can_access_site(p_actor_portal_user_id,p_site_id) THEN RAISE EXCEPTION 'Portal actor cannot access the selected site.' USING ERRCODE='42501'; END IF;
 SELECT s.organization_id INTO v_org FROM metadata.sites s WHERE s.id=p_site_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Site was not found.' USING ERRCODE='22023'; END IF;

 INSERT INTO config.site_energy_meter_roles(site_id,device_id,meter_role,allocation_factor,is_authoritative,effective_from,effective_to,description)
 VALUES(p_site_id,p_device_id,v_role,p_allocation_factor,p_is_authoritative,COALESCE(p_effective_from,now()),p_effective_to,nullif(btrim(p_description),''))
 RETURNING id INTO v_id;

 PERFORM admin.write_audit_event(v_tx,p_actor_portal_user_id,'ASSIGN_SITE_ENERGY_METER_ROLE','SITE_ENERGY_METER_ROLE',v_id,v_org,p_site_id,
   '{}'::jsonb,jsonb_build_object('site_id',p_site_id,'device_id',p_device_id,'meter_role',v_role,'allocation_factor',p_allocation_factor,
   'is_authoritative',p_is_authoritative,'effective_from',COALESCE(p_effective_from,now()),'effective_to',p_effective_to,'description',nullif(btrim(p_description),'')),
   'SUCCEEDED',NULL);
 v_result:=jsonb_build_object('success',TRUE,'entity_type','SITE_ENERGY_METER_ROLE','entity_id',v_id,'assignment_id',v_id,
   'organization_id',v_org,'site_id',p_site_id,'device_id',p_device_id,'meter_role',v_role,'audit_transaction_id',v_tx);
 RETURN v_result;
END;$function$;

CREATE OR REPLACE FUNCTION admin.list_accessible_site_energy_meter_roles(
 p_actor_portal_user_id BIGINT,p_organization_id UUID DEFAULT NULL,p_site_id UUID DEFAULT NULL,
 p_meter_role TEXT DEFAULT NULL,p_active_only BOOLEAN DEFAULT TRUE
) RETURNS TABLE(
 assignment_id UUID,organization_id UUID,site_id UUID,site_code TEXT,site_name TEXT,device_id UUID,
 device_external_id TEXT,device_name TEXT,device_category_name TEXT,meter_role TEXT,role_display_name TEXT,balance_direction TEXT,
 allocation_factor NUMERIC,is_authoritative BOOLEAN,effective_from TIMESTAMPTZ,effective_to TIMESTAMPTZ,
 is_active BOOLEAN,description TEXT,created_at TIMESTAMPTZ,updated_at TIMESTAMPTZ
) LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path TO pg_catalog,admin,config,metadata AS $function$
SELECT r.id,s.organization_id,r.site_id,s.code,s.name,r.device_id,d.external_id,d.name,dc.name,
 r.meter_role,role.display_name,role.balance_direction,r.allocation_factor,r.is_authoritative,
 r.effective_from,r.effective_to,r.is_active,r.description,r.created_at,r.updated_at
FROM config.site_energy_meter_roles r
JOIN config.site_energy_roles role ON role.role_code=r.meter_role
JOIN metadata.sites s ON s.id=r.site_id
JOIN metadata.devices d ON d.id=r.device_id
JOIN metadata.device_models dm ON dm.id=d.device_model_id
JOIN config.device_categories dc ON dc.id=dm.device_category_id
WHERE admin.portal_user_can_access_site(p_actor_portal_user_id,r.site_id)
 AND (p_organization_id IS NULL OR s.organization_id=p_organization_id)
 AND (p_site_id IS NULL OR r.site_id=p_site_id)
 AND (p_meter_role IS NULL OR r.meter_role=upper(btrim(p_meter_role)))
 AND (NOT p_active_only OR r.is_active)
ORDER BY s.name,role.display_order,d.name,r.effective_from DESC;
$function$;

COMMENT ON TABLE config.site_energy_roles IS 'Controlled reference data for site-level energy-balance meter roles.';
ALTER TABLE config.site_energy_roles OWNER TO ems_admin;
ALTER FUNCTION config.validate_site_energy_meter_role() OWNER TO ems_admin;
ALTER FUNCTION admin.assign_site_energy_meter_role(BIGINT,UUID,UUID,TEXT,NUMERIC,BOOLEAN,TIMESTAMPTZ,TIMESTAMPTZ,TEXT) OWNER TO ems_admin;
ALTER FUNCTION admin.list_accessible_site_energy_meter_roles(BIGINT,UUID,UUID,TEXT,BOOLEAN) OWNER TO ems_admin;
REVOKE ALL ON config.site_energy_roles FROM PUBLIC;
REVOKE ALL ON config.site_energy_meter_roles FROM PUBLIC,ems_app;
REVOKE ALL ON FUNCTION config.validate_site_energy_meter_role() FROM PUBLIC,ems_app;
REVOKE ALL ON FUNCTION admin.assign_site_energy_meter_role(BIGINT,UUID,UUID,TEXT,NUMERIC,BOOLEAN,TIMESTAMPTZ,TIMESTAMPTZ,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION admin.list_accessible_site_energy_meter_roles(BIGINT,UUID,UUID,TEXT,BOOLEAN) FROM PUBLIC;
GRANT SELECT ON config.site_energy_roles TO ems_app;
GRANT EXECUTE ON FUNCTION admin.assign_site_energy_meter_role(BIGINT,UUID,UUID,TEXT,NUMERIC,BOOLEAN,TIMESTAMPTZ,TIMESTAMPTZ,TEXT) TO ems_app;
GRANT EXECUTE ON FUNCTION admin.list_accessible_site_energy_meter_roles(BIGINT,UUID,UUID,TEXT,BOOLEAN) TO ems_app;
