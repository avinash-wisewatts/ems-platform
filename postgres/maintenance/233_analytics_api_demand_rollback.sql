-- ============================================================================
-- Rollback for migration 233 (Slice B -- Demand backend, B1).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 233 created:
--   * analytics.get_portal_site_demand_series(bigint, uuid, timestamptz, timestamptz)
--   * analytics.get_portal_site_current_demand(bigint, uuid)
--
-- Migration 233 created NO table, hypertable, job, policy, trigger, grant to
-- PUBLIC/grafana_reader, or data. It changed no existing object. There is no
-- stored state to reconcile.
--
-- Refuses to run if an object OUTSIDE migration 233 depends on either
-- function.
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/233_analytics_api_demand_rollback.sql
--
-- NOT executed as part of this implementation increment.
-- ============================================================================

BEGIN;

DO $rollback_guard$
DECLARE
    v_dep TEXT;
BEGIN
    IF to_regprocedure('analytics.get_portal_site_demand_series(bigint, uuid, timestamptz, timestamptz)') IS NULL
       AND to_regprocedure('analytics.get_portal_site_current_demand(bigint, uuid)') IS NULL THEN
        RAISE NOTICE 'Rollback 233: nothing to do (both functions already absent).';
        RETURN;
    END IF;

    SELECT string_agg(DISTINCT dependent.identity, ', ')
      INTO v_dep
    FROM pg_depend d
    JOIN pg_proc p
      ON p.oid = d.refobjid
     AND p.pronamespace = 'analytics'::regnamespace
     AND p.proname IN (
         'get_portal_site_demand_series',
         'get_portal_site_current_demand'
     )
    JOIN LATERAL (
        SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS identity
    ) AS dependent ON TRUE
    WHERE d.deptype IN ('n', 'a')
      AND pg_describe_object(d.classid, d.objid, d.objsubid) NOT LIKE 'function analytics.%';

    IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 233 aborted: external dependents exist -> %', v_dep;
    END IF;
END;
$rollback_guard$;

DROP FUNCTION IF EXISTS analytics.get_portal_site_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS analytics.get_portal_site_current_demand(BIGINT, UUID);

COMMIT;
