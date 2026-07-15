-- ============================================================================
-- File: 02_roles.sql
-- Purpose: Create application roles for the EMS SaaS platform.
--
-- Notes:
--   - Login roles are used by services.
--   - Privileges will be granted in subsequent scripts.
--   - This script is idempotent.
-- ============================================================================

DO
$$
BEGIN

    ---------------------------------------------------------------------------
    -- Telegraf Ingestion Role
    ---------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'telegraf_writer'
    ) THEN
        CREATE ROLE telegraf_writer
            LOGIN
            PASSWORD 'CHANGE_ME_TELEGRAF';
    END IF;

    ---------------------------------------------------------------------------
    -- Grafana Read-Only Role
    ---------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'grafana_reader'
    ) THEN
        CREATE ROLE grafana_reader
            LOGIN
            PASSWORD 'CHANGE_ME_GRAFANA';
    END IF;

    ---------------------------------------------------------------------------
    -- Future EMS Backend/API Role
    ---------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'ems_app'
    ) THEN
        CREATE ROLE ems_app
            LOGIN
            PASSWORD 'CHANGE_ME_APP';
    END IF;

    ---------------------------------------------------------------------------
    -- Operations Read-Only Role
    ---------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'ems_readonly'
    ) THEN
        CREATE ROLE ems_readonly
            LOGIN
            PASSWORD 'CHANGE_ME_READONLY';
    END IF;

END
$$;
