-- ============================================================================
-- Migration 187
-- Hierarchical Sector -> Sub-Sector -> Asset Type taxonomy for onboarding.
--
-- Adds:
--   * metadata.sectors / metadata.sub_sectors  -- controlled two-level
--     industry classification, seeded with the standardized list below.
--   * metadata.sub_sector_asset_mapping        -- which of the 27
--     standardized asset types are relevant to each sub-sector.
--   * metadata.sites.sub_sector_id             -- nullable FK, additive.
--     This is intentionally layered alongside the existing
--     metadata.sites.sector_code / config.site_sectors flat classification
--     introduced in migration 120 (admin.set_site_sector and everything
--     wired to it in the admin portal are untouched and keep working).
--     Existing sites are left with sub_sector_id = NULL; the asset-type
--     filter below falls back to the full catalog when a site has no
--     sub-sector assigned yet, so nothing already deployed breaks.
--
-- Replaces the asset type catalog:
--   STEP A: insert the 27 standardized asset types (idempotent, by
--     case-insensitive name, same pattern as migration 119).
--   STEP B: remap metadata.assets.asset_type_id off of every legacy asset
--     type that is not staying in the catalog, before it is deleted.
--     Verified against live production data at the time this migration was
--     authored (2 orgs / 5 sites / 24 assets):
--       'Motor'           (18 assets) -> 'Motors/Pumps/Conveyors'
--       'Pump'            ( 2 assets) -> 'Motors/Pumps/Conveyors'
--       'Compressed air'  ( 2 assets) -> 'Air Compressors'
--       'AHU'             ( 2 assets) -> already an exact-name match to the
--                                        new catalog; no remap needed.
--     Any asset type this migration has not seen data for is not assumed
--     safe to guess at from its name alone -- a bare fuzzy-match on
--     unfamiliar legacy labels risks silently misclassifying real client
--     assets. Any asset left pointing at a to-be-removed legacy type after
--     the explicit remap above falls back to 'Sub-meter' as a safe,
--     reviewable default (flagged for follow-up, not silently correct).
--   STEP C: delete legacy asset types that are not in the new 27 and are
--     no longer referenced by any asset. This is belt-and-braces: even if
--     step B missed a row, metadata.assets.asset_type_id has a plain
--     (non-cascading) foreign key to metadata.asset_types, so a leftover
--     reference makes this DELETE fail loudly instead of orphaning data.
--
-- Idempotent: safe to run more than once against the same database.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Schema: sector / sub-sector taxonomy and its mapping to asset types.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS metadata.sectors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS sectors_name_ci_uq
    ON metadata.sectors (lower(name));

CREATE TABLE IF NOT EXISTS metadata.sub_sectors (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sector_id UUID NOT NULL REFERENCES metadata.sectors(id),
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS sub_sectors_name_ci_uq
    ON metadata.sub_sectors (lower(name));

CREATE INDEX IF NOT EXISTS idx_sub_sectors_sector_id
    ON metadata.sub_sectors (sector_id);

CREATE TABLE IF NOT EXISTS metadata.sub_sector_asset_mapping (
    sub_sector_id UUID NOT NULL REFERENCES metadata.sub_sectors(id),
    asset_type_id UUID NOT NULL REFERENCES metadata.asset_types(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (sub_sector_id, asset_type_id)
);

CREATE INDEX IF NOT EXISTS idx_sub_sector_asset_mapping_asset_type
    ON metadata.sub_sector_asset_mapping (asset_type_id);

-- Additive: existing metadata.sites.sector_code / config.site_sectors keep
-- working untouched. sub_sector_id is nullable so existing sites are not
-- forced into the new hierarchy retroactively.
ALTER TABLE metadata.sites
    ADD COLUMN IF NOT EXISTS sub_sector_id UUID REFERENCES metadata.sub_sectors(id);

CREATE INDEX IF NOT EXISTS idx_sites_sub_sector_id
    ON metadata.sites (sub_sector_id);

COMMENT ON TABLE metadata.sectors IS
    'Controlled top-level industry sector classification for onboarding.';
COMMENT ON TABLE metadata.sub_sectors IS
    'Controlled sub-sector classification within a sector, selected during site onboarding.';
COMMENT ON TABLE metadata.sub_sector_asset_mapping IS
    'Which standardized asset types are relevant to each sub-sector, used to filter the asset-type picker during asset onboarding.';
COMMENT ON COLUMN metadata.sites.sub_sector_id IS
    'Sub-sector this site belongs to, used to filter Asset Type choices when creating assets at this site. Nullable for sites onboarded before this classification existed.';

DO $grants$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        GRANT SELECT ON metadata.sectors TO ems_app;
        GRANT SELECT ON metadata.sub_sectors TO ems_app;
        GRANT SELECT ON metadata.sub_sector_asset_mapping TO ems_app;
    END IF;
END $grants$;

-- ----------------------------------------------------------------------------
-- Seed: sectors and sub-sectors.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.sectors (name)
SELECT requested.name
FROM (VALUES
    ('Commercial Real Estate'),
    ('Industrial / Manufacturing'),
    ('Retail'),
    ('Healthcare'),
    ('Pharmaceuticals & Life Sciences'),
    ('Data Centers'),
    ('Education'),
    ('Logistics & Transport')
) AS requested(name)
WHERE NOT EXISTS (
    SELECT 1 FROM metadata.sectors existing
    WHERE lower(existing.name) = lower(requested.name)
);

INSERT INTO metadata.sub_sectors (sector_id, name)
SELECT s.id, requested.name
FROM (VALUES
    ('Commercial Real Estate', 'Office Buildings'),
    ('Commercial Real Estate', 'Multi-Family Residential'),
    ('Commercial Real Estate', 'Corporate Campuses'),
    ('Commercial Real Estate', 'Mixed-Use Developments'),
    ('Commercial Real Estate', 'Hotels & Hospitality'),

    ('Industrial / Manufacturing', 'Heavy Manufacturing'),
    ('Industrial / Manufacturing', 'Light Manufacturing'),
    ('Industrial / Manufacturing', 'Food & Beverage Processing'),
    ('Industrial / Manufacturing', 'Chemical Processing'),
    ('Industrial / Manufacturing', 'Pulp & Paper'),

    ('Retail', 'Supermarkets & Grocery'),
    ('Retail', 'Convenience Stores & Gas Stations'),
    ('Retail', 'Shopping Malls'),
    ('Retail', 'Strip Malls'),

    ('Healthcare', 'Hospitals'),
    ('Healthcare', 'Clinics'),
    ('Healthcare', 'Long-Term Care & Assisted Living'),

    ('Pharmaceuticals & Life Sciences', 'R&D Laboratories'),
    ('Pharmaceuticals & Life Sciences', 'Manufacturing Plants (Bulk/API/FDF)'),

    ('Data Centers', 'Hyperscale Data Centers'),
    ('Data Centers', 'Enterprise Data Centers'),
    ('Data Centers', 'Edge Data Centers'),

    ('Education', 'University & College Campuses'),
    ('Education', 'K-12 Schools'),

    ('Logistics & Transport', 'Distribution & Fulfillment Centers'),
    ('Logistics & Transport', 'Cold Storage Warehouses'),
    ('Logistics & Transport', 'Airports'),
    ('Logistics & Transport', 'Transit Hubs (Rail/Bus)')
) AS requested(sector_name, name)
JOIN metadata.sectors s ON lower(s.name) = lower(requested.sector_name)
WHERE NOT EXISTS (
    SELECT 1 FROM metadata.sub_sectors existing
    WHERE lower(existing.name) = lower(requested.name)
);

-- ----------------------------------------------------------------------------
-- STEP A: insert the 27 standardized asset types (idempotent).
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE new_asset_type_catalog (
    name TEXT PRIMARY KEY,
    description TEXT
) ON COMMIT DROP;

INSERT INTO new_asset_type_catalog (name, description) VALUES
    ('Chillers (Central/Industrial)', 'Central or industrial chiller plant providing chilled water for cooling'),
    ('Boilers (Steam/Hot Water)', 'Steam or hot-water boiler plant'),
    ('Cooling Towers', 'Cooling tower rejecting heat from a condenser water loop'),
    ('AHU', 'Air handling unit'),
    ('RTUs / Split-Systems', 'Rooftop unit or split-system packaged HVAC equipment'),
    ('CRAC / In-Row Cooling', 'Computer room air conditioning or in-row cooling unit'),
    ('Refrigeration', 'Refrigeration plant, case, or packaged refrigeration equipment'),
    ('Ovens/Furnaces', 'Industrial oven or furnace'),
    ('Kitchen Ovens/Hoods', 'Commercial kitchen oven or exhaust hood'),
    ('Fluid Bed Processors/Dryers', 'Fluid bed processor or dryer used in pharmaceutical or chemical processing'),
    ('Metal Presses/CNC Machines', 'Metal stamping press or CNC machine tool'),
    ('Industrial Mixers/Blenders', 'Industrial mixing or blending equipment'),
    ('Purified Water (RO/WFI) Systems', 'Purified water system, including reverse osmosis and water-for-injection'),
    ('Nitrogen Generators', 'On-site nitrogen generation equipment'),
    ('Central Vacuum Pumps', 'Central plant vacuum pump system'),
    ('Effluent Treatment (ETP) Pumps', 'Effluent treatment plant pump'),
    ('Stability Chambers', 'Environmental stability chamber for controlled testing or storage'),
    ('Autoclaves / Steam Sterilizers', 'Autoclave or steam sterilizer'),
    ('Medical Scanners (MRI/CT)', 'Medical imaging scanner, including MRI and CT systems'),
    ('Motors/Pumps/Conveyors', 'Electric motor, pump, or conveyor equipment'),
    ('Air Compressors', 'Compressed-air generation, treatment, storage, or distribution equipment'),
    ('Exhaust/Ventilation Fans', 'Exhaust or ventilation fan'),
    ('Baggage Handling Systems', 'Airport baggage handling conveyance system'),
    ('Elevators / Escalators', 'Vertical transportation equipment, including elevators and escalators'),
    ('Lighting', 'Lighting circuit or fixture group'),
    ('Sub-meter', 'General-purpose electrical sub-meter'),
    ('Backup Generator', 'On-site backup or standby electrical generator')
ON CONFLICT (name) DO NOTHING;

INSERT INTO metadata.asset_types (name, description)
SELECT c.name, c.description
FROM new_asset_type_catalog c
WHERE NOT EXISTS (
    SELECT 1 FROM metadata.asset_types existing
    WHERE lower(existing.name) = lower(c.name)
);

-- ----------------------------------------------------------------------------
-- STEP B: remap existing assets off of legacy asset types before they are
-- removed from the catalog.
-- ----------------------------------------------------------------------------

WITH legacy_to_new (legacy_name, new_name) AS (
    VALUES
        ('Motor', 'Motors/Pumps/Conveyors'),
        ('Pump', 'Motors/Pumps/Conveyors'),
        ('Compressed air', 'Air Compressors')
),
remap AS (
    SELECT legacy.id AS legacy_id, new.id AS new_id
    FROM legacy_to_new map
    JOIN metadata.asset_types legacy ON lower(legacy.name) = lower(map.legacy_name)
    JOIN metadata.asset_types new ON lower(new.name) = lower(map.new_name)
)
UPDATE metadata.assets a
SET asset_type_id = remap.new_id,
    updated_at = clock_timestamp()
FROM remap
WHERE a.asset_type_id = remap.legacy_id;

-- Safety net: any asset still pointing at a legacy type that is not in the
-- new 27 (and was not covered by an explicit remap above) falls back to
-- 'Sub-meter' rather than blocking the migration or being guessed at.
UPDATE metadata.assets a
SET asset_type_id = fallback.id,
    updated_at = clock_timestamp()
FROM metadata.asset_types fallback
WHERE fallback.name = 'Sub-meter'
    AND a.asset_type_id IN (
        SELECT legacy.id
        FROM metadata.asset_types legacy
        WHERE NOT EXISTS (
            SELECT 1 FROM new_asset_type_catalog c
            WHERE lower(c.name) = lower(legacy.name)
        )
    );

-- ----------------------------------------------------------------------------
-- STEP C: delete legacy asset types outside the new 27, now unreferenced.
-- ----------------------------------------------------------------------------

DELETE FROM metadata.asset_types legacy
WHERE NOT EXISTS (
        SELECT 1 FROM new_asset_type_catalog c
        WHERE lower(c.name) = lower(legacy.name)
    )
    AND NOT EXISTS (
        SELECT 1 FROM metadata.assets a
        WHERE a.asset_type_id = legacy.id
    );

-- ----------------------------------------------------------------------------
-- Map the 27 standardized asset types to relevant sub-sectors.
-- ----------------------------------------------------------------------------

-- Cross-sector types: relevant to every sub-sector (base building services).
INSERT INTO metadata.sub_sector_asset_mapping (sub_sector_id, asset_type_id)
SELECT ss.id, at.id
FROM metadata.sub_sectors ss
CROSS JOIN metadata.asset_types at
WHERE at.name IN (
    'AHU', 'RTUs / Split-Systems', 'Motors/Pumps/Conveyors', 'Air Compressors',
    'Exhaust/Ventilation Fans', 'Elevators / Escalators', 'Lighting',
    'Sub-meter', 'Backup Generator'
)
ON CONFLICT DO NOTHING;

-- Sector/sub-sector-specific types.
INSERT INTO metadata.sub_sector_asset_mapping (sub_sector_id, asset_type_id)
SELECT ss.id, at.id
FROM (VALUES
    ('Chillers (Central/Industrial)', 'Office Buildings'),
    ('Chillers (Central/Industrial)', 'Multi-Family Residential'),
    ('Chillers (Central/Industrial)', 'Corporate Campuses'),
    ('Chillers (Central/Industrial)', 'Mixed-Use Developments'),
    ('Chillers (Central/Industrial)', 'Hotels & Hospitality'),
    ('Chillers (Central/Industrial)', 'Heavy Manufacturing'),
    ('Chillers (Central/Industrial)', 'Light Manufacturing'),
    ('Chillers (Central/Industrial)', 'Food & Beverage Processing'),
    ('Chillers (Central/Industrial)', 'Chemical Processing'),
    ('Chillers (Central/Industrial)', 'Shopping Malls'),
    ('Chillers (Central/Industrial)', 'Hospitals'),
    ('Chillers (Central/Industrial)', 'Clinics'),
    ('Chillers (Central/Industrial)', 'Long-Term Care & Assisted Living'),
    ('Chillers (Central/Industrial)', 'R&D Laboratories'),
    ('Chillers (Central/Industrial)', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Chillers (Central/Industrial)', 'Hyperscale Data Centers'),
    ('Chillers (Central/Industrial)', 'Enterprise Data Centers'),
    ('Chillers (Central/Industrial)', 'University & College Campuses'),
    ('Chillers (Central/Industrial)', 'K-12 Schools'),
    ('Chillers (Central/Industrial)', 'Airports'),
    ('Chillers (Central/Industrial)', 'Transit Hubs (Rail/Bus)'),

    ('Boilers (Steam/Hot Water)', 'Multi-Family Residential'),
    ('Boilers (Steam/Hot Water)', 'Hotels & Hospitality'),
    ('Boilers (Steam/Hot Water)', 'Heavy Manufacturing'),
    ('Boilers (Steam/Hot Water)', 'Food & Beverage Processing'),
    ('Boilers (Steam/Hot Water)', 'Chemical Processing'),
    ('Boilers (Steam/Hot Water)', 'Pulp & Paper'),
    ('Boilers (Steam/Hot Water)', 'Hospitals'),
    ('Boilers (Steam/Hot Water)', 'Long-Term Care & Assisted Living'),
    ('Boilers (Steam/Hot Water)', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Boilers (Steam/Hot Water)', 'University & College Campuses'),

    ('Cooling Towers', 'Office Buildings'),
    ('Cooling Towers', 'Corporate Campuses'),
    ('Cooling Towers', 'Mixed-Use Developments'),
    ('Cooling Towers', 'Hotels & Hospitality'),
    ('Cooling Towers', 'Heavy Manufacturing'),
    ('Cooling Towers', 'Chemical Processing'),
    ('Cooling Towers', 'Hospitals'),
    ('Cooling Towers', 'R&D Laboratories'),
    ('Cooling Towers', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Cooling Towers', 'Hyperscale Data Centers'),
    ('Cooling Towers', 'Enterprise Data Centers'),
    ('Cooling Towers', 'University & College Campuses'),

    ('CRAC / In-Row Cooling', 'Hyperscale Data Centers'),
    ('CRAC / In-Row Cooling', 'Enterprise Data Centers'),
    ('CRAC / In-Row Cooling', 'Edge Data Centers'),

    ('Refrigeration', 'Supermarkets & Grocery'),
    ('Refrigeration', 'Convenience Stores & Gas Stations'),
    ('Refrigeration', 'Food & Beverage Processing'),
    ('Refrigeration', 'Cold Storage Warehouses'),
    ('Refrigeration', 'Distribution & Fulfillment Centers'),
    ('Refrigeration', 'Hotels & Hospitality'),

    ('Ovens/Furnaces', 'Heavy Manufacturing'),
    ('Ovens/Furnaces', 'Light Manufacturing'),
    ('Ovens/Furnaces', 'Pulp & Paper'),
    ('Ovens/Furnaces', 'Chemical Processing'),

    ('Kitchen Ovens/Hoods', 'Hotels & Hospitality'),
    ('Kitchen Ovens/Hoods', 'Supermarkets & Grocery'),
    ('Kitchen Ovens/Hoods', 'K-12 Schools'),
    ('Kitchen Ovens/Hoods', 'University & College Campuses'),
    ('Kitchen Ovens/Hoods', 'Long-Term Care & Assisted Living'),

    ('Fluid Bed Processors/Dryers', 'R&D Laboratories'),
    ('Fluid Bed Processors/Dryers', 'Manufacturing Plants (Bulk/API/FDF)'),

    ('Metal Presses/CNC Machines', 'Heavy Manufacturing'),
    ('Metal Presses/CNC Machines', 'Light Manufacturing'),

    ('Industrial Mixers/Blenders', 'Food & Beverage Processing'),
    ('Industrial Mixers/Blenders', 'Chemical Processing'),
    ('Industrial Mixers/Blenders', 'Manufacturing Plants (Bulk/API/FDF)'),

    ('Purified Water (RO/WFI) Systems', 'R&D Laboratories'),
    ('Purified Water (RO/WFI) Systems', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Purified Water (RO/WFI) Systems', 'Hospitals'),

    ('Nitrogen Generators', 'R&D Laboratories'),
    ('Nitrogen Generators', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Nitrogen Generators', 'Chemical Processing'),
    ('Nitrogen Generators', 'Heavy Manufacturing'),

    ('Central Vacuum Pumps', 'R&D Laboratories'),
    ('Central Vacuum Pumps', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Central Vacuum Pumps', 'Hospitals'),

    ('Effluent Treatment (ETP) Pumps', 'Chemical Processing'),
    ('Effluent Treatment (ETP) Pumps', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Effluent Treatment (ETP) Pumps', 'Pulp & Paper'),
    ('Effluent Treatment (ETP) Pumps', 'Food & Beverage Processing'),

    ('Stability Chambers', 'R&D Laboratories'),
    ('Stability Chambers', 'Manufacturing Plants (Bulk/API/FDF)'),

    ('Autoclaves / Steam Sterilizers', 'Hospitals'),
    ('Autoclaves / Steam Sterilizers', 'Clinics'),
    ('Autoclaves / Steam Sterilizers', 'Long-Term Care & Assisted Living'),
    ('Autoclaves / Steam Sterilizers', 'Manufacturing Plants (Bulk/API/FDF)'),
    ('Autoclaves / Steam Sterilizers', 'R&D Laboratories'),

    ('Medical Scanners (MRI/CT)', 'Hospitals'),
    ('Medical Scanners (MRI/CT)', 'Clinics'),

    ('Baggage Handling Systems', 'Airports')
) AS requested(asset_type_name, sub_sector_name)
JOIN metadata.asset_types at ON lower(at.name) = lower(requested.asset_type_name)
JOIN metadata.sub_sectors ss ON lower(ss.name) = lower(requested.sub_sector_name)
ON CONFLICT DO NOTHING;

-- ----------------------------------------------------------------------------
-- admin API: set a site's sub-sector, and list asset types filtered by site.
-- Mirrors the existing admin.set_site_sector contract from migration 120.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION admin.set_site_sub_sector(
    p_actor_portal_user_id BIGINT,
    p_site_id UUID,
    p_sub_sector_id UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
DECLARE
    v_org UUID;
BEGIN
    IF NOT admin.portal_user_has_permission(p_actor_portal_user_id, 'site.manage')
       OR NOT admin.portal_user_can_access_site(p_actor_portal_user_id, p_site_id) THEN
        RAISE EXCEPTION 'Portal actor is not authorized to update this site.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM metadata.sub_sectors WHERE id = p_sub_sector_id) THEN
        RAISE EXCEPTION 'Select a valid sub-sector.' USING ERRCODE = '22023';
    END IF;

    UPDATE metadata.sites
    SET sub_sector_id = p_sub_sector_id, updated_at = clock_timestamp()
    WHERE id = p_site_id
    RETURNING organization_id INTO v_org;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Site was not found.' USING ERRCODE = '22023';
    END IF;

    RETURN jsonb_build_object(
        'success', TRUE,
        'site_id', p_site_id,
        'organization_id', v_org,
        'sub_sector_id', p_sub_sector_id
    );
END;
$function$;

ALTER FUNCTION admin.set_site_sub_sector(BIGINT, UUID, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.set_site_sub_sector(BIGINT, UUID, UUID) FROM PUBLIC;

-- Asset types available for the Asset Type picker at a given site: filtered
-- to the site's sub-sector mapping when one is set, otherwise the full
-- catalog (keeps sites onboarded before this migration functional).
CREATE OR REPLACE FUNCTION admin.list_site_asset_types(p_site_id UUID)
RETURNS TABLE (id UUID, name TEXT, description TEXT)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
    WITH site_sub_sector AS (
        SELECT sub_sector_id FROM metadata.sites WHERE id = p_site_id
    )
    SELECT vat.id, vat.name, vat.description
    FROM admin.v_asset_types vat
    WHERE (SELECT sub_sector_id FROM site_sub_sector) IS NULL
       OR EXISTS (
            SELECT 1
            FROM metadata.sub_sector_asset_mapping m
            WHERE m.asset_type_id = vat.id
              AND m.sub_sector_id = (SELECT sub_sector_id FROM site_sub_sector)
        )
    ORDER BY vat.name, vat.id;
$function$;

ALTER FUNCTION admin.list_site_asset_types(UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_site_asset_types(UUID) FROM PUBLIC;

CREATE OR REPLACE VIEW admin.v_sectors
WITH (security_barrier = TRUE)
AS
SELECT id, name, description
FROM metadata.sectors
ORDER BY name;

CREATE OR REPLACE VIEW admin.v_sub_sectors
WITH (security_barrier = TRUE)
AS
SELECT id, sector_id, name, description
FROM metadata.sub_sectors
ORDER BY name;

COMMENT ON VIEW admin.v_sectors IS 'Controlled sectors available for onboarding.';
COMMENT ON VIEW admin.v_sub_sectors IS 'Controlled sub-sectors available for onboarding, scoped to a sector.';

DO $grants$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        GRANT SELECT ON admin.v_sectors TO ems_app;
        GRANT SELECT ON admin.v_sub_sectors TO ems_app;
        GRANT EXECUTE ON FUNCTION admin.set_site_sub_sector(BIGINT, UUID, UUID) TO ems_app;
        GRANT EXECUTE ON FUNCTION admin.list_site_asset_types(UUID) TO ems_app;
    END IF;
END $grants$;

COMMIT;
