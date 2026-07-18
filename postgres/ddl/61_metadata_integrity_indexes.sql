-- ============================================================================
-- 61_metadata_integrity_indexes.sql
--
-- Canonical metadata integrity and lookup indexes.
--
-- These indexes enforce stable asset hierarchy rules, prevent ambiguous
-- primary-meter assignments, and optimize external device identifier lookup.
--
-- All statements use IF NOT EXISTS so the file is safe to rerun.
-- ============================================================================

-- Accelerates resolution of devices using identifiers received from external
-- systems such as MQTT gateway/device UIDs.
CREATE INDEX IF NOT EXISTS idx_device_identifiers_lookup
    ON metadata.device_identifiers
    USING btree (identifier_type, identifier_value);

COMMENT ON INDEX metadata.idx_device_identifiers_lookup IS
    'Accelerates device resolution by external identifier type and value.';


-- A physical device may act as the PRIMARY_METER for no more than one asset.
--
-- Other relationship types remain unrestricted because one device may provide
-- secondary, environmental, status, or auxiliary measurements to many assets.
CREATE UNIQUE INDEX IF NOT EXISTS uq_asset_devices_primary_meter
    ON metadata.asset_devices
    USING btree (device_id)
    WHERE relationship_type = 'PRIMARY_METER';

COMMENT ON INDEX metadata.uq_asset_devices_primary_meter IS
    'Ensures a device is assigned as PRIMARY_METER to at most one asset.';


-- Root-level asset names must be unique within an organization and site.
--
-- PostgreSQL treats NULL values as distinct in ordinary unique indexes, so a
-- partial index is required for assets without a parent.
CREATE UNIQUE INDEX IF NOT EXISTS uq_assets_root_name
    ON metadata.assets
    USING btree (organization_id, site_id, name)
    WHERE parent_asset_id IS NULL;

COMMENT ON INDEX metadata.uq_assets_root_name IS
    'Prevents duplicate root asset names within an organization and site.';


-- Child asset names must be unique among siblings under the same parent.
CREATE UNIQUE INDEX IF NOT EXISTS uq_assets_child_name
    ON metadata.assets
    USING btree (organization_id, site_id, parent_asset_id, name)
    WHERE parent_asset_id IS NOT NULL;

COMMENT ON INDEX metadata.uq_assets_child_name IS
    'Prevents duplicate child asset names under the same parent asset.';
