-- ============================================================================
-- Rollback for migration 231 (Phase 7 -- Analytics API / Query Boundary,
-- first slice).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 231 created:
--   * analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz,
--     timestamptz, text)                                        (function)
--   * analytics.get_portal_space_measurement_series(bigint, uuid, text,
--     timestamptz, timestamptz, text)                           (function)
--   * analytics.portal_user_can_access_space(bigint, uuid)      (function)
--
-- Migration 231 created NO table, hypertable, job, policy, trigger, grant to
-- PUBLIC/grafana_reader, or data. It changed no existing object. There is no
-- stored state to reconcile.
--
-- Refuses to run if an object OUTSIDE migration 231 depends on any of the
-- three functions (e.g. a later Phase 7 slice wrapped them in a view).
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/231_analytics_api_query_boundary_rollback.sql
-- ============================================================================

BEGIN;

DO $rollback_guard$
DECLARE
    v_dep TEXT;
BEGIN
    IF to_regprocedure('analytics.portal_user_can_access_space(bigint, uuid)') IS NULL
       AND to_regprocedure('analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)') IS NULL
       AND to_regprocedure('analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)') IS NULL THEN
        RAISE NOTICE 'Rollback 231: nothing to do (all three functions already absent).';
        RETURN;
    END IF;

    -- Refuse if anything outside migration 231 depends on these functions.
    SELECT string_agg(DISTINCT dependent.identity, ', ')
      INTO v_dep
    FROM pg_depend d
    JOIN pg_proc p
      ON p.oid = d.refobjid
     AND p.pronamespace = 'analytics'::regnamespace
     AND p.proname IN (
         'portal_user_can_access_space',
         'get_portal_space_measurement_series',
         'get_portal_site_energy_consumption'
     )
    JOIN LATERAL (
        SELECT pg_describe_object(d.classid, d.objid, d.objsubid) AS identity
    ) AS dependent ON TRUE
    WHERE d.deptype IN ('n', 'a')
      AND pg_describe_object(d.classid, d.objid, d.objsubid) NOT LIKE 'function analytics.%';

    IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 231 aborted: external dependents exist -> %', v_dep;
    END IF;
END;
$rollback_guard$;

DROP FUNCTION IF EXISTS analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text);
DROP FUNCTION IF EXISTS analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text);
DROP FUNCTION IF EXISTS analytics.portal_user_can_access_space(bigint, uuid);

DO $rollback_post$
BEGIN
    IF to_regprocedure('analytics.portal_user_can_access_space(bigint, uuid)') IS NOT NULL
       OR to_regprocedure('analytics.get_portal_space_measurement_series(bigint, uuid, text, timestamptz, timestamptz, text)') IS NOT NULL
       OR to_regprocedure('analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 231 postcondition failed: a boundary function is still present.';
    END IF;
    RAISE NOTICE 'Rollback 231: all three /api/v1 query-boundary functions dropped.';
END;
$rollback_post$;

COMMIT;
