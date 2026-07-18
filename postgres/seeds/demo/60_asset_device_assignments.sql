-- ============================================================================
-- File:
--   60_asset_device_assignments.sql
--
-- Purpose:
--   Harden asset natural-key uniqueness, assign the three Eniscope energy
--   meters to operational assets, and expose tenant-safe asset metadata to
--   Grafana.
--
-- Assignments:
--
--   ENI-ENERGY-001 -> Chiller 1
--   ENI-ENERGY-002 -> Primary Pump 1
--   ENI-ENERGY-003 -> Secondary Pump 1
--
-- Relationship:
--
--   PRIMARY_METER
--
-- A device may participate in several relationships, but it may be the
-- PRIMARY_METER for only one asset.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Prevent duplicate root assets within one tenant/site.
--
-- PostgreSQL treats NULL values as distinct in ordinary unique constraints, so
-- root and child assets require separate partial unique indexes.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_assets_root_name
ON metadata.assets
(
    organization_id,
    site_id,
    name
)
WHERE parent_asset_id IS NULL;


-- ----------------------------------------------------------------------------
-- 2. Prevent duplicate child assets under one parent.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_assets_child_name
ON metadata.assets
(
    organization_id,
    site_id,
    parent_asset_id,
    name
)
WHERE parent_asset_id IS NOT NULL;


-- ----------------------------------------------------------------------------
-- 3. One device may be the primary meter for only one asset.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_asset_devices_primary_meter
ON metadata.asset_devices
(
    device_id
)
WHERE relationship_type = 'PRIMARY_METER';


-- ----------------------------------------------------------------------------
-- 4. Assign energy meters to operational assets.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.asset_devices
(
    asset_id,
    device_id,
    relationship_type
)
SELECT
    a.id,
    d.id,
    'PRIMARY_METER'
FROM metadata.assets a

JOIN metadata.organizations o
  ON o.id = a.organization_id

JOIN metadata.devices d
  ON d.organization_id = a.organization_id

WHERE o.code = 'WW-DEMO'
  AND
  (
      (a.name = 'Chiller 1'
       AND d.external_id = 'ENI-ENERGY-001')

      OR

      (a.name = 'Primary Pump 1'
       AND d.external_id = 'ENI-ENERGY-002')

      OR

      (a.name = 'Secondary Pump 1'
       AND d.external_id = 'ENI-ENERGY-003')
  )

ON CONFLICT
(
    asset_id,
    device_id,
    relationship_type
)
DO NOTHING;


-- ----------------------------------------------------------------------------
-- 5. Validate all expected assignments.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_assignment_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_assignment_count
    FROM metadata.asset_devices ad

    JOIN metadata.assets a
      ON a.id = ad.asset_id

    JOIN metadata.devices d
      ON d.id = ad.device_id

    JOIN metadata.organizations o
      ON o.id = a.organization_id

    WHERE o.code = 'WW-DEMO'
      AND ad.relationship_type = 'PRIMARY_METER'
      AND
      (
          (a.name = 'Chiller 1'
           AND d.external_id = 'ENI-ENERGY-001')

          OR

          (a.name = 'Primary Pump 1'
           AND d.external_id = 'ENI-ENERGY-002')

          OR

          (a.name = 'Secondary Pump 1'
           AND d.external_id = 'ENI-ENERGY-003')
      );

    IF v_assignment_count <> 3 THEN
        RAISE EXCEPTION
            'Expected 3 primary-meter assignments, found %',
            v_assignment_count;
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
