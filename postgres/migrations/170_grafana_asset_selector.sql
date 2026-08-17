BEGIN;

-- ============================================================================
-- Grafana asset-selection projection
--
-- Purpose
-- -------
-- Provide one tenant-aware selection surface for:
--
--     Site -> Location -> Asset Type -> Asset
--
-- This intentionally does NOT change analytics.v_grafana_assets because that
-- view is already consumed widely by dashboards and analytics contracts.
--
-- Physical location remains canonical in metadata:
--
--     Site -> Building -> Floor -> Space
--
-- location_key is a stable filtering key.
-- location_path is display text only.
-- ============================================================================

CREATE OR REPLACE VIEW analytics.v_grafana_asset_selector AS
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
        WHEN sp.id IS NOT NULL
            THEN 'S:' || sp.id::text

        WHEN fl.id IS NOT NULL
            THEN 'F:' || fl.id::text

        WHEN b.id IS NOT NULL
            THEN 'B:' || b.id::text

        ELSE 'UNSPECIFIED'
    END AS location_key,

    COALESCE(
        NULLIF(
            concat_ws(
                ' / ',
                NULLIF(b.name, ''),
                NULLIF(fl.name, ''),
                NULLIF(sp.name, '')
            ),
            ''
        ),
        'Unspecified'
    ) AS location_path,

    ga.lifecycle_status

FROM analytics.v_grafana_assets AS ga

JOIN metadata.assets AS ma
  ON ma.id = ga.asset_id
 AND ma.organization_id = ga.organization_id
 AND ma.site_id = ga.site_id

-- A space identifies its floor.
LEFT JOIN metadata.spaces AS sp
  ON sp.id = ma.space_id
 AND sp.organization_id = ga.organization_id

-- Resolve a floor from either the asset directly or its assigned space.
LEFT JOIN metadata.floors AS fl
  ON fl.id = COALESCE(ma.floor_id, sp.floor_id)
 AND fl.organization_id = ga.organization_id

-- Resolve a building from either the asset directly or its resolved floor.
LEFT JOIN metadata.buildings AS b
  ON b.id = COALESCE(ma.building_id, fl.building_id)
 AND b.organization_id = ga.organization_id
 AND b.site_id = ga.site_id
;

COMMENT ON VIEW analytics.v_grafana_asset_selector IS
'Tenant-aware Grafana asset-selection projection. Provides physical location, asset type and asset identity for cascading Site -> Location -> Asset Type -> Asset dashboard variables.';

COMMENT ON COLUMN analytics.v_grafana_asset_selector.location_key IS
'Stable physical-location selector key. Uses deepest resolved location: S:<space UUID>, F:<floor UUID>, B:<building UUID>, or UNSPECIFIED.';

COMMENT ON COLUMN analytics.v_grafana_asset_selector.location_path IS
'Human-readable resolved physical location path using Building / Floor / Space.';

GRANT SELECT
ON analytics.v_grafana_asset_selector
TO grafana_reader;

COMMIT;
