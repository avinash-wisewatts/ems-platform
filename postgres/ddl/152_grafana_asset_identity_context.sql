-- Grafana tenant-safe asset identity/location context.
--
-- Provides physical Building / Floor / Space location without granting
-- grafana_reader direct access to metadata tables.

CREATE OR REPLACE VIEW analytics.v_grafana_asset_identity_context
WITH (security_barrier = true)
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

    b.name  AS building_name,
    f.name  AS floor_name,
    sp.name AS space_name,

    COALESCE(
        NULLIF(
            concat_ws(
                ' / ',
                NULLIF(b.name, ''),
                NULLIF(f.name, ''),
                NULLIF(sp.name, '')
            ),
            ''
        ),
        a.site_name
    ) AS location_path

FROM analytics.v_grafana_assets a

JOIN metadata.assets ma
  ON ma.id = a.asset_id
 AND ma.organization_id = a.organization_id
 AND ma.site_id = a.site_id

LEFT JOIN metadata.buildings b
  ON b.id = ma.building_id
 AND b.organization_id = ma.organization_id
 AND b.site_id = ma.site_id

LEFT JOIN metadata.floors f
  ON f.id = ma.floor_id
 AND f.organization_id = ma.organization_id
 AND f.building_id = ma.building_id

LEFT JOIN metadata.spaces sp
  ON sp.id = ma.space_id
 AND sp.organization_id = ma.organization_id
 AND sp.floor_id = ma.floor_id;


ALTER VIEW analytics.v_grafana_asset_identity_context
OWNER TO ems_admin;

REVOKE ALL
ON analytics.v_grafana_asset_identity_context
FROM PUBLIC;

GRANT SELECT
ON analytics.v_grafana_asset_identity_context
TO grafana_reader;

COMMENT ON VIEW analytics.v_grafana_asset_identity_context IS
'Tenant-scoped Grafana asset identity context including canonical physical Building / Floor / Space location.';
