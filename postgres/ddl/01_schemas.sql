-- ============================================================================
-- File: 01_schemas.sql
-- Purpose: Create logical database schemas for the EMS SaaS platform.
--
-- This script is idempotent and may be executed multiple times.
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS metadata;
CREATE SCHEMA IF NOT EXISTS telemetry;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS config;
CREATE SCHEMA IF NOT EXISTS integration;

COMMENT ON SCHEMA admin IS
'Platform administration, security and operational metadata.';

COMMENT ON SCHEMA metadata IS
'Core business entities such as organizations, sites, assets and devices.';

COMMENT ON SCHEMA telemetry IS
'Raw time-series telemetry and hypertables.';

COMMENT ON SCHEMA analytics IS
'Continuous aggregates, reporting views and derived metrics.';

COMMENT ON SCHEMA config IS
'Configuration objects including device profiles, engineering units and parser definitions.';

COMMENT ON SCHEMA integration IS
'External system mappings and integration metadata.';
