-- ============================================================================
-- Disposable test database only: reproduce staging's read-only investigation
-- role before the migrations run.
--
-- Staging has ems_investigator (created out of band by an ops script) with
-- USAGE on the application schemas and
--     ALTER DEFAULT PRIVILEGES FOR ROLE ems_admin IN SCHEMA <s>
--         GRANT SELECT ON TABLES TO ems_investigator
-- so every table a migration creates there is readable by it at once.
-- Migration 314 (admin.portal_sessions) failed on staging on exactly that
-- (staging release run 40689330235, 2026-10-28) while passing here; with this
-- file the test database grants the same, and a migration that must leave a
-- table ungranted fails in CI first.
--
-- NOLOGIN here (staging's role can log in); privileges are what matter.
-- Idempotent.
-- ============================================================================

\set ON_ERROR_STOP on

DO $role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ems_investigator') THEN
        CREATE ROLE ems_investigator NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
    END IF;
END
$role$;

DO $grants$
DECLARE
    s TEXT;
BEGIN
    FOREACH s IN ARRAY ARRAY['admin', 'analytics', 'config', 'integration', 'metadata', 'telemetry'] LOOP
        IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
            EXECUTE format('GRANT USAGE ON SCHEMA %I TO ems_investigator', s);
            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE ems_admin IN SCHEMA %I GRANT SELECT ON TABLES TO ems_investigator', s);
        END IF;
    END LOOP;
END
$grants$;
