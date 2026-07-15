-- ============================================================================
-- File: 08_indexes.sql
-- Purpose: Performance indexes for EMS metadata and telemetry.
--
-- Notes:
--   PostgreSQL automatically creates indexes for PRIMARY KEY and UNIQUE
--   constraints. This file creates indexes for FOREIGN KEY columns and
--   frequently filtered columns.
-- ============================================================================

-- ============================================================================
-- ORGANIZATION HIERARCHY
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_sites_organization
ON metadata.sites (organization_id);

CREATE INDEX IF NOT EXISTS idx_buildings_organization
ON metadata.buildings (organization_id);

CREATE INDEX IF NOT EXISTS idx_buildings_site
ON metadata.buildings (site_id);

CREATE INDEX IF NOT EXISTS idx_floors_organization
ON metadata.floors (organization_id);

CREATE INDEX IF NOT EXISTS idx_floors_building
ON metadata.floors (building_id);

CREATE INDEX IF NOT EXISTS idx_spaces_organization
ON metadata.spaces (organization_id);

CREATE INDEX IF NOT EXISTS idx_spaces_floor
ON metadata.spaces (floor_id);

-- ============================================================================
-- ASSETS
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_assets_organization
ON metadata.assets (organization_id);

CREATE INDEX IF NOT EXISTS idx_assets_site
ON metadata.assets (site_id);

CREATE INDEX IF NOT EXISTS idx_assets_parent
ON metadata.assets (parent_asset_id);

CREATE INDEX IF NOT EXISTS idx_assets_type
ON metadata.assets (asset_type_id);

-- ============================================================================
-- GATEWAYS & DEVICES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_gateways_organization
ON metadata.gateways (organization_id);

CREATE INDEX IF NOT EXISTS idx_gateways_site
ON metadata.gateways (site_id);

CREATE INDEX IF NOT EXISTS idx_devices_organization
ON metadata.devices (organization_id);

CREATE INDEX IF NOT EXISTS idx_devices_gateway
ON metadata.devices (gateway_id);

CREATE INDEX IF NOT EXISTS idx_devices_model
ON metadata.devices (device_model_id);

CREATE INDEX IF NOT EXISTS idx_devices_external_id
ON metadata.devices (external_id);

-- ============================================================================
-- MAPPINGS
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_asset_devices_asset
ON metadata.asset_devices (asset_id);

CREATE INDEX IF NOT EXISTS idx_asset_devices_device
ON metadata.asset_devices (device_id);

CREATE INDEX IF NOT EXISTS idx_asset_points_asset
ON metadata.asset_points (asset_id);

CREATE INDEX IF NOT EXISTS idx_asset_points_point
ON metadata.asset_points (logical_point_id);

CREATE INDEX IF NOT EXISTS idx_device_field_mapping_device
ON metadata.device_field_mapping (device_id);

CREATE INDEX IF NOT EXISTS idx_device_field_mapping_point
ON metadata.device_field_mapping (logical_point_id);

