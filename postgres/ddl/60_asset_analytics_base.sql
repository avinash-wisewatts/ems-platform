-- ============================================================================
-- Canonical tenant-safe asset analytics base views
--
-- Purpose:
--   Provides the canonical asset hierarchy and asset-to-device views required
--   by downstream asset-centric analytics.
--
-- Classification:
--   Canonical production DDL.
--
-- Important:
--   This file creates schema objects only. It does not insert demo assets,
--   devices, organizations, or assignments.
-- ============================================================================

-- 6. Tenant-safe asset hierarchy view.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_assets
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    a.organization_id,
    a.site_id,

    s.code AS site_code,
    s.name AS site_name,

    a.id AS asset_id,
    a.parent_asset_id,

    parent.name AS parent_asset_name,

    a.asset_type_id,
    at.name AS asset_type,
    at.description AS asset_type_description,

    a.name AS asset_name,
    a.manufacturer,
    a.model,
    a.serial_number,
    a.status,
    a.metadata,

    a.created_at,
    a.updated_at,

    -- Preserve the expanded canonical v_assets contract introduced by
    -- asset meter coverage. Keeping this column here makes repeated canonical
    -- deployment idempotent because CREATE OR REPLACE VIEW cannot remove
    -- columns from an existing view.
    a.metering_requirement

FROM metadata.grafana_organization_map gom

JOIN metadata.assets a
  ON a.organization_id = gom.organization_id

JOIN metadata.sites s
  ON s.id = a.site_id

LEFT JOIN metadata.assets parent
  ON parent.id = a.parent_asset_id

LEFT JOIN metadata.asset_types at
  ON at.id = a.asset_type_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_assets IS
'Tenant-safe operational asset hierarchy for Grafana variables, asset dashboards, and metering-policy analytics.';


-- ----------------------------------------------------------------------------
-- 7. Tenant-safe asset-to-device relationship view.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW analytics.v_asset_devices
WITH
(
    security_barrier = TRUE
)
AS
SELECT
    gom.grafana_org_id,

    a.organization_id,
    a.site_id,

    s.code AS site_code,
    s.name AS site_name,

    a.id AS asset_id,
    a.name AS asset_name,

    a.parent_asset_id,
    parent.name AS parent_asset_name,

    at.name AS asset_type,

    ad.relationship_type,

    d.id AS device_id,
    d.external_id,
    d.name AS device_name,
    d.serial_number AS device_serial_number,
    d.protocol,

    ad.created_at AS relationship_created_at

FROM metadata.grafana_organization_map gom

JOIN metadata.assets a
  ON a.organization_id = gom.organization_id

JOIN metadata.sites s
  ON s.id = a.site_id

JOIN metadata.asset_devices ad
  ON ad.asset_id = a.id

JOIN metadata.devices d
  ON d.id = ad.device_id

LEFT JOIN metadata.assets parent
  ON parent.id = a.parent_asset_id

LEFT JOIN metadata.asset_types at
  ON at.id = a.asset_type_id

WHERE gom.is_active = TRUE;


COMMENT ON VIEW analytics.v_asset_devices IS
'Tenant-safe mappings between operational assets and their telemetry devices.';


-- ----------------------------------------------------------------------------
-- 8. Least-privilege access.
-- ----------------------------------------------------------------------------

REVOKE ALL ON
    analytics.v_assets,
    analytics.v_asset_devices
FROM PUBLIC;


GRANT SELECT ON
    analytics.v_assets,
    analytics.v_asset_devices
TO grafana_reader;
