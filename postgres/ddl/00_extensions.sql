-- ============================================================================
-- File: 00_extensions.sql
-- Purpose: Install required PostgreSQL extensions for the EMS platform.
--
-- This script is idempotent and can be safely executed multiple times.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;
