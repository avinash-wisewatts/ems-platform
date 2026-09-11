-- ============================================================================
-- Rollback for migration 232 (Slice 0 -- Hierarchy Foundation, Space/Asset
-- listing).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 232 created:
--   * analytics.list_portal_site_spaces(bigint, uuid)   (function)
--   * analytics.list_portal_site_assets(bigint, uuid)   (function)
--
-- Migration 232 created NO table, hypertable, job, policy, trigger, grant to
-- PUBLIC/grafana_reader, or data. It changed no existing object. There is no
-- stored state to reconcile.
--
-- Refuses to run if an object OUTSIDE migration 232 depends on either
-- function.
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/232_analytics_api_hierarchy_rollback.sql
--
-- NOT executed as part of this implementation increment.
-- ============================================================================

BEGIN;

DO $rollback_guard$
DECLARE
    v_dep TEXT;
BEGIN
    IF to_regprocedure('analytics.list_portal_site_spaces(bigint, uuid)') IS NULL
       AND to_regprocedure('analytics.list_portal_site_assets(bigint, uuid)') IS NULL THEN
        RAISE NOTICE 'Rollback 232: nothing to do (both functions already absent).';
        RETURN;
    END IF;

    SELECT string_agg(DISTINCT dependent.identity, ', ')
      INTO v_dep
    FROM pg_depend d
    JOIN pg_proc p
      ON p.oid = d.refobjid
     AND p.pronamespace = 'analytics'::regnamespace
     AND p.proname IN (
         'list_portal_site_spaces',
         'list_portal_site_assets'
     )
    JOIN LATERAL (
        SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS identity
    ) AS dependent ON TRUE
    WHERE d.deptype IN ('n', 'a')
      AND pg_describe_object(d.classid, d.objid, d.objsubid) NOT LIKE 'function analytics.%';

    IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 232 aborted: external dependents exist -> %', v_dep;
    END IF;
END;
$rollback_guard$;

DROP FUNCTION IF EXISTS analytics.list_portal_site_spaces(BIGINT, UUID);
DROP FUNCTION IF EXISTS analytics.list_portal_site_assets(BIGINT, UUID);

COMMIT;
