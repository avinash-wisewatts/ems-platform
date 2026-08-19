-- ============================================================================
-- Migration 188
-- Fully deprecate the legacy flat site-sector classification introduced in
-- migration 120 (config.site_sectors / metadata.sites.sector_code /
-- admin.set_site_sector), now that migration 187's Sector -> Sub-Sector
-- taxonomy (metadata.sectors / metadata.sub_sectors / sites.sub_sector_id)
-- is in place and is the only sector-related classification going forward.
--
-- Before dropping anything, every live consumer of sector_code /
-- config.site_sectors was inventoried:
--   * metadata.sites.sector_code -- FK'd only by config.site_sectors, no
--     other table references it.
--   * config.site_sectors -- referenced only by that one FK.
--   * admin.set_site_sector(...) -- the only function whose body touches
--     sector_code; called only from the application layer, never from
--     another database function.
--   * analytics.v_grafana_sites / analytics.v_grafana_assets -- both
--     project sector_code (and, for v_grafana_sites, config.site_sectors'
--     display_name as sector_name) as plain output columns. The Grafana
--     dashboard grafana/dashboards/core/organization-overview.json queries
--     analytics.v_grafana_sites.sector_name directly (two panels), so that
--     column name is kept -- it now sources from metadata.sectors instead
--     of config.site_sectors. Both views also gain sector_id, sub_sector_id,
--     and sub_sector_name, matching migration 187's taxonomy. Removing a
--     column that isn't at the end of the list is not something
--     CREATE OR REPLACE VIEW can do, so both views are dropped and
--     recreated. analytics.v_grafana_assets has two dependent views
--     (analytics.v_grafana_asset_identity_context and
--     analytics.v_grafana_asset_selector, both used directly by the
--     analytics-explorer and asset-overview Grafana dashboards) that select
--     explicit columns and never reference sector_code/sector_name, so
--     dropping v_grafana_assets with CASCADE and recreating all three
--     (verbatim for the two dependents) is safe and leaves their dashboard
--     queries unaffected.
--   * admin.list_manageable_sites(...) -- backs admin.get_site_workspace,
--     which is what the FastAPI site detail/edit pages read. It did not
--     previously return sub_sector_id at all; this migration adds
--     sector_id, sector_name, sub_sector_id, and sub_sector_name so the
--     Site Edit screen can pre-select the site's current sector/sub-sector.
--     PostgreSQL cannot CREATE OR REPLACE a function to change its
--     RETURNS TABLE shape, so it is dropped and recreated.
--
-- After this migration, metadata.sites.sub_sector_id is the only
-- sector-related foreign key on the Sites table.
--
-- Idempotent: safe to run more than once against the same database.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- Grafana-facing views: replace sector_code / config.site_sectors with the
-- new taxonomy, keeping the sector_name column name Grafana already queries.
--
-- sector_code sat in the middle of both column lists, and
-- CREATE OR REPLACE VIEW can only append columns, never remove or reorder
-- one -- so both views are dropped and recreated. v_grafana_assets is
-- dropped CASCADE to also drop its two dependent views, which are then
-- recreated verbatim (they don't reference sector columns at all).
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS analytics.v_grafana_sites;
DROP VIEW IF EXISTS analytics.v_grafana_assets CASCADE;

CREATE VIEW analytics.v_grafana_sites
WITH (security_barrier = TRUE)
AS
SELECT
    gom.grafana_org_id,
    o.id AS organization_id,
    o.code AS organization_code,
    o.name AS organization_name,
    o.timezone AS organization_timezone,
    s.id AS site_id,
    s.code AS site_code,
    s.name AS site_name,
    s.timezone AS site_timezone,
    sec.id AS sector_id,
    sec.name AS sector_name,
    ss.id AS sub_sector_id,
    ss.name AS sub_sector_name,
    s.lifecycle_status,
    s.is_active,
    s.address,
    (SELECT count(*) FROM metadata.assets a WHERE a.site_id = s.id) AS asset_count,
    (SELECT count(*) FROM metadata.gateways g WHERE g.site_id = s.id) AS gateway_count,
    (SELECT count(*) FROM metadata.devices d JOIN metadata.gateways g ON g.id = d.gateway_id WHERE g.site_id = s.id) AS device_count
FROM metadata.grafana_organization_map gom
JOIN metadata.organizations o ON o.id = gom.organization_id
JOIN metadata.sites s ON s.organization_id = o.id
LEFT JOIN metadata.sub_sectors ss ON ss.id = s.sub_sector_id
LEFT JOIN metadata.sectors sec ON sec.id = ss.sector_id
WHERE gom.is_active = true;

COMMENT ON VIEW analytics.v_grafana_sites IS
    'Per-tenant Grafana site catalog. sector_name/sub_sector_name are sourced from metadata.sectors/sub_sectors (migration 187); the legacy config.site_sectors classification was removed in migration 188.';

CREATE VIEW analytics.v_grafana_assets
WITH (security_barrier = TRUE)
AS
WITH RECURSIVE asset_tree AS (
    SELECT
        a.id, a.organization_id, a.site_id, a.parent_asset_id,
        a.id AS root_asset_id, 0 AS depth,
        ARRAY[a.id] AS path_ids, ARRAY[a.name] AS path_names
    FROM metadata.assets a
    WHERE a.parent_asset_id IS NULL

    UNION ALL

    SELECT
        c.id, c.organization_id, c.site_id, c.parent_asset_id,
        t.root_asset_id, t.depth + 1,
        t.path_ids || c.id, t.path_names || c.name
    FROM asset_tree t
    JOIN metadata.assets c
        ON c.parent_asset_id = t.id
        AND c.organization_id = t.organization_id
        AND c.site_id = t.site_id
    WHERE NOT (c.id = ANY (t.path_ids))
),
enriched AS (
    SELECT
        a.id, a.organization_id, a.site_id, a.asset_type_id, a.parent_asset_id,
        a.name, a.manufacturer, a.model, a.serial_number, a.status, a.metadata,
        a.created_at, a.updated_at, a.space_id, a.metering_requirement,
        a.lifecycle_status, a.building_id, a.floor_id, a.external_id,
        COALESCE(t.root_asset_id, a.id) AS root_asset_id,
        COALESCE(t.depth, 0) AS hierarchy_depth,
        COALESCE(t.path_names, ARRAY[a.name]) AS hierarchy_names
    FROM metadata.assets a
    LEFT JOIN asset_tree t ON t.id = a.id
)
SELECT
    gom.grafana_org_id,
    e.organization_id,
    e.site_id,
    s.code AS site_code,
    s.name AS site_name,
    sec.id AS sector_id,
    sec.name AS sector_name,
    ss.id AS sub_sector_id,
    ss.name AS sub_sector_name,
    e.id AS asset_id,
    e.parent_asset_id,
    p.name AS parent_asset_name,
    e.root_asset_id,
    e.hierarchy_depth,
    array_to_string(e.hierarchy_names, ' / ') AS hierarchy_path,
    e.asset_type_id,
    at.name AS asset_type,
    e.name AS asset_name,
    e.external_id,
    e.manufacturer,
    e.model,
    e.serial_number,
    e.status,
    e.lifecycle_status,
    e.metering_requirement,
    e.metadata,
    (SELECT count(*) FROM metadata.assets c WHERE c.parent_asset_id = e.id) AS child_count,
    NOT EXISTS (SELECT 1 FROM metadata.assets c WHERE c.parent_asset_id = e.id) AS is_leaf,
    (SELECT count(*) FROM metadata.asset_devices ad WHERE ad.asset_id = e.id) AS assigned_device_count,
    e.created_at,
    e.updated_at
FROM metadata.grafana_organization_map gom
JOIN enriched e ON e.organization_id = gom.organization_id
JOIN metadata.sites s ON s.id = e.site_id
LEFT JOIN metadata.sub_sectors ss ON ss.id = s.sub_sector_id
LEFT JOIN metadata.sectors sec ON sec.id = ss.sector_id
LEFT JOIN metadata.assets p ON p.id = e.parent_asset_id
LEFT JOIN metadata.asset_types at ON at.id = e.asset_type_id
WHERE gom.is_active = true;

COMMENT ON VIEW analytics.v_grafana_assets IS
    'Per-tenant Grafana asset catalog with hierarchy. sector_name/sub_sector_name are sourced from metadata.sectors/sub_sectors (migration 187).';

-- Recreated verbatim: neither references sector_code/sector_name, so
-- dropping v_grafana_assets via CASCADE only means re-issuing these as-is.

CREATE VIEW analytics.v_grafana_asset_identity_context
WITH (security_barrier = TRUE)
AS
SELECT
    a.grafana_org_id,
    a.organization_id,
    a.site_id,
    a.site_name,
    a.asset_id,
    a.asset_name,
    a.external_id,
    a.asset_type,
    a.hierarchy_path,
    a.lifecycle_status,
    a.metering_requirement,
    a.assigned_device_count,
    b.name AS building_name,
    f.name AS floor_name,
    sp.name AS space_name,
    COALESCE(NULLIF(concat_ws(' / ', NULLIF(b.name, ''), NULLIF(f.name, ''), NULLIF(sp.name, '')), ''), a.site_name) AS location_path
FROM analytics.v_grafana_assets a
JOIN metadata.assets ma ON ma.id = a.asset_id AND ma.organization_id = a.organization_id AND ma.site_id = a.site_id
LEFT JOIN metadata.buildings b ON b.id = ma.building_id AND b.organization_id = ma.organization_id AND b.site_id = ma.site_id
LEFT JOIN metadata.floors f ON f.id = ma.floor_id AND f.organization_id = ma.organization_id AND f.building_id = ma.building_id
LEFT JOIN metadata.spaces sp ON sp.id = ma.space_id AND sp.organization_id = ma.organization_id AND sp.floor_id = ma.floor_id;

COMMENT ON VIEW analytics.v_grafana_asset_identity_context IS
    'Tenant-scoped Grafana asset identity context including canonical physical Building / Floor / Space location.';

CREATE VIEW analytics.v_grafana_asset_selector
AS
SELECT
    ga.grafana_org_id,
    ga.organization_id,
    ga.site_id,
    ga.site_code,
    ga.site_name,
    ga.asset_id,
    ga.asset_name,
    ga.hierarchy_path,
    ga.asset_type_id,
    ga.asset_type,
    b.id AS building_id,
    b.name AS building_name,
    fl.id AS floor_id,
    fl.name AS floor_name,
    sp.id AS space_id,
    sp.name AS space_name,
    CASE
        WHEN sp.id IS NOT NULL THEN 'S:' || sp.id::text
        WHEN fl.id IS NOT NULL THEN 'F:' || fl.id::text
        WHEN b.id IS NOT NULL THEN 'B:' || b.id::text
        ELSE 'UNSPECIFIED'
    END AS location_key,
    COALESCE(NULLIF(concat_ws(' / ', NULLIF(b.name, ''), NULLIF(fl.name, ''), NULLIF(sp.name, '')), ''), 'Unspecified') AS location_path,
    ga.lifecycle_status
FROM analytics.v_grafana_assets ga
JOIN metadata.assets ma ON ma.id = ga.asset_id AND ma.organization_id = ga.organization_id AND ma.site_id = ga.site_id
LEFT JOIN metadata.spaces sp ON sp.id = ma.space_id AND sp.organization_id = ga.organization_id
LEFT JOIN metadata.floors fl ON fl.id = COALESCE(ma.floor_id, sp.floor_id) AND fl.organization_id = ga.organization_id
LEFT JOIN metadata.buildings b ON b.id = COALESCE(ma.building_id, fl.building_id) AND b.organization_id = ga.organization_id AND b.site_id = ga.site_id;

COMMENT ON VIEW analytics.v_grafana_asset_selector IS
    'Tenant-aware Grafana asset-selection projection. Provides physical location, asset type and asset identity for cascading Site -> Location -> Asset Type -> Asset dashboard variables.';

DO $grants$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader') THEN
        GRANT SELECT ON analytics.v_grafana_sites TO grafana_reader;
        GRANT SELECT ON analytics.v_grafana_assets TO grafana_reader;
        GRANT SELECT ON analytics.v_grafana_asset_identity_context TO grafana_reader;
        GRANT SELECT ON analytics.v_grafana_asset_selector TO grafana_reader;
    END IF;
END $grants$;

-- ----------------------------------------------------------------------------
-- admin.list_manageable_sites: add sector_id/sector_name/sub_sector_id/
-- sub_sector_name so the Site Edit screen can pre-select current values.
-- CREATE OR REPLACE cannot change RETURNS TABLE shape, so drop first.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS admin.list_manageable_sites(BIGINT);

CREATE FUNCTION admin.list_manageable_sites(p_actor_portal_user_id BIGINT)
RETURNS TABLE (
    site_id UUID,
    organization_id UUID,
    organization_code TEXT,
    organization_name TEXT,
    site_code TEXT,
    site_name TEXT,
    timezone TEXT,
    address JSONB,
    lifecycle_status TEXT,
    is_active BOOLEAN,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    sector_id UUID,
    sector_name TEXT,
    sub_sector_id UUID,
    sub_sector_name TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO pg_catalog, admin, metadata
AS $function$
    SELECT
        s.id,
        s.organization_id,
        o.code,
        o.name,
        s.code,
        s.name,
        s.timezone,
        COALESCE(s.address, '{}'::jsonb),
        s.lifecycle_status,
        s.is_active,
        s.created_at,
        s.updated_at,
        sec.id,
        sec.name,
        ss.id,
        ss.name
    FROM metadata.sites AS s
    JOIN metadata.organizations AS o ON o.id = s.organization_id
    LEFT JOIN metadata.sub_sectors AS ss ON ss.id = s.sub_sector_id
    LEFT JOIN metadata.sectors AS sec ON sec.id = ss.sector_id
    JOIN admin.portal_users AS u
      ON u.portal_user_id = p_actor_portal_user_id
     AND u.is_active = TRUE
    WHERE
        u.access_scope_mode = 'GLOBAL'
        OR (
            u.organization_id = s.organization_id
            AND (
                u.access_scope_mode = 'ORGANIZATION'
                OR (
                    u.access_scope_mode = 'SELECTED_SITES'
                    AND EXISTS (
                        SELECT 1
                        FROM admin.portal_user_site_access AS a
                        WHERE a.portal_user_id = u.portal_user_id
                          AND a.site_id = s.id
                    )
                )
            )
        )
    ORDER BY o.name, s.name, s.code, s.id;
$function$;

ALTER FUNCTION admin.list_manageable_sites(BIGINT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION admin.list_manageable_sites(BIGINT) FROM PUBLIC;

DO $grants$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_app') THEN
        GRANT EXECUTE ON FUNCTION admin.list_manageable_sites(BIGINT) TO ems_app;
    END IF;
END $grants$;

-- ----------------------------------------------------------------------------
-- Drop the legacy classification: function, then column/constraint/index,
-- then the now-unreferenced lookup table.
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS admin.set_site_sector(BIGINT, UUID, TEXT);

ALTER TABLE metadata.sites DROP CONSTRAINT IF EXISTS sites_sector_code_fk;
DROP INDEX IF EXISTS metadata.idx_sites_sector_code;
ALTER TABLE metadata.sites DROP COLUMN IF EXISTS sector_code;

DROP TABLE IF EXISTS config.site_sectors;

COMMIT;
