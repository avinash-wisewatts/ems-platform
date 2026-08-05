BEGIN;

CREATE TABLE IF NOT EXISTS config.site_sectors (
    code TEXT PRIMARY KEY,
    display_name TEXT NOT NULL UNIQUE,
    display_order INTEGER NOT NULL UNIQUE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO config.site_sectors(code, display_name, display_order, is_active) VALUES
('HOSPITALITY','Hospitality',10,TRUE),
('HEALTHCARE','Healthcare',20,TRUE),
('MANUFACTURING','Manufacturing',30,TRUE),
('RETAIL','Retail',40,TRUE),
('FOOD&BEVERAGE','Food & Beverage',50,TRUE),
('COMMERCIAL','Commercial',60,TRUE),
('EDUCATION','Education',70,TRUE),
('DATA CENTER','Data Center',80,TRUE),
('OTHER','Other',90,TRUE)
ON CONFLICT (code) DO UPDATE SET
 display_name=EXCLUDED.display_name, display_order=EXCLUDED.display_order, is_active=TRUE;

ALTER TABLE metadata.sites ADD COLUMN IF NOT EXISTS sector_code TEXT;
UPDATE metadata.sites SET sector_code='OTHER' WHERE sector_code IS NULL OR btrim(sector_code)='';
ALTER TABLE metadata.sites ALTER COLUMN sector_code SET DEFAULT 'OTHER';
ALTER TABLE metadata.sites ALTER COLUMN sector_code SET NOT NULL;

DO $block$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sites_sector_code_fk' AND conrelid='metadata.sites'::regclass) THEN
  ALTER TABLE metadata.sites ADD CONSTRAINT sites_sector_code_fk FOREIGN KEY(sector_code) REFERENCES config.site_sectors(code);
 END IF;
END $block$;
CREATE INDEX IF NOT EXISTS idx_sites_sector_code ON metadata.sites(sector_code);

CREATE OR REPLACE FUNCTION admin.set_site_sector(
 p_actor_portal_user_id BIGINT, p_site_id UUID, p_sector_code TEXT
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata, config
AS $function$
DECLARE v_sector TEXT := upper(btrim(p_sector_code)); v_org UUID;
BEGIN
 IF NOT admin.portal_user_has_permission(p_actor_portal_user_id,'site.manage')
    OR NOT admin.portal_user_can_access_site(p_actor_portal_user_id,p_site_id) THEN
  RAISE EXCEPTION 'Portal actor is not authorized to update this site.' USING ERRCODE='42501';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM config.site_sectors WHERE code=v_sector AND is_active=TRUE) THEN
  RAISE EXCEPTION 'Select a valid active site sector.' USING ERRCODE='22023';
 END IF;
 UPDATE metadata.sites SET sector_code=v_sector, updated_at=clock_timestamp() WHERE id=p_site_id RETURNING organization_id INTO v_org;
 IF NOT FOUND THEN RAISE EXCEPTION 'Site was not found.' USING ERRCODE='22023'; END IF;
 RETURN jsonb_build_object('success',TRUE,'site_id',p_site_id,'organization_id',v_org,'sector_code',v_sector);
END;
$function$;

COMMENT ON TABLE config.site_sectors IS 'Controlled site-level sector classifications.';
COMMENT ON COLUMN metadata.sites.sector_code IS 'Controlled site-level sector classification.';
ALTER FUNCTION admin.set_site_sector(BIGINT,UUID,TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.set_site_sector(BIGINT,UUID,TEXT) FROM PUBLIC;
DO $block$ BEGIN
 IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ems_app') THEN
  GRANT USAGE ON SCHEMA config TO ems_app;
  GRANT SELECT ON config.site_sectors TO ems_app;
  GRANT EXECUTE ON FUNCTION admin.set_site_sector(BIGINT,UUID,TEXT) TO ems_app;
 END IF;
END $block$;

COMMIT;
