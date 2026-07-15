-- ============================================================================
-- File: 03_admin.sql
-- Purpose: Establish the baseline database administration and security
--          configuration for the EMS SaaS platform.
--
-- Notes:
--   - This script is idempotent.
--   - Application object permissions will be granted after the schemas,
--     tables, views, and functions are created.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Database Comment
-- ----------------------------------------------------------------------------
COMMENT ON DATABASE ems IS
'Enterprise Multi-Tenant Energy Management System (EMS) SaaS Platform';

-- ----------------------------------------------------------------------------
-- Secure the default public schema
-- ----------------------------------------------------------------------------

-- Prevent arbitrary object creation in the public schema.
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Ensure all users can connect to the database.
GRANT CONNECT ON DATABASE ems TO PUBLIC;

-- ----------------------------------------------------------------------------
-- Search Path
-- ----------------------------------------------------------------------------

ALTER DATABASE ems
SET search_path = public;

-- ----------------------------------------------------------------------------
-- End of File
-- ----------------------------------------------------------------------------
