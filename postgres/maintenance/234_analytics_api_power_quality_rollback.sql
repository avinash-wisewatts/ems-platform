-- ============================================================================
-- Rollback for migration 234 (Slice B -- Power Quality backend, D1).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 234 created:
--   * analytics.get_portal_site_power_quality_series(bigint, uuid, text, timestamptz, timestamptz)
--
-- Migration 234 created NO table, hypertable, job, policy, trigger, grant to
-- PUBLIC/grafana_reader, or data. It changed no existing object. There is no
-- stored state to reconcile.
--
-- Refuses to run if an object OUTSIDE migration 234 depends on the function.
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/234_analytics_api_power_quality_rollback.sql
--
-- NOT executed as part of this implementation increment.
-- ============================================================================

BEGIN;

DO $rollback_guard$
DECLARE
    v_dep TEXT;
BEGIN
    IF to_regprocedure('analytics.get_portal_site_power_quality_series(bigint, uuid, text, timestamptz, timestamptz)') IS NULL THEN
        RAISE NOTICE 'Rollback 234: nothing to do (function already absent).';
        RETURN;
    END IF;

    SELECT string_agg(DISTINCT dependent.identity, ', ')
      INTO v_dep
    FROM pg_depend d
    JOIN pg_proc p
      ON p.oid = d.refobjid
     AND p.pronamespace = 'analytics'::regnamespace
     AND p.proname = 'get_portal_site_power_quality_series'
    JOIN LATERAL (
        SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS identity
    ) AS dependent ON TRUE
    WHERE d.deptype IN ('n', 'a')
      AND pg_describe_object(d.classid, d.objid, d.objsubid) NOT LIKE 'function analytics.%';

    IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 234 aborted: external dependents exist -> %', v_dep;
    END IF;
END;
$rollback_guard$;

DROP FUNCTION IF EXISTS analytics.get_portal_site_power_quality_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ);

COMMIT;
