-- ============================================================================
-- Migration 308
-- Remove PUBLIC EXECUTE from six SECURITY DEFINER job / trigger routines
--
-- These routines run as ems_admin (SECURITY DEFINER). Their repository
-- definitions never revoke the default PUBLIC EXECUTE, so on production any
-- database login can CALL the energy / environment tier jobs (which refresh
-- persisted tiers and advance checkpoints) or invoke the two trigger
-- functions directly. Staging had PUBLIC removed out of band; this migration
-- records that hardening in the repository so every environment matches
-- (staging/production parity audit, 2026-10-23, H10).
--
--   analytics.run_energy_consumption_15min_job(integer, jsonb)   procedure
--   analytics.run_energy_consumption_hourly_job(integer, jsonb)  procedure
--   analytics.run_energy_consumption_daily_job(integer, jsonb)   procedure
--   telemetry.run_environment_daily_job(integer, jsonb)          procedure
--   config.ensure_asset_demand_policy_for_site()                 trigger function
--   telemetry.set_energy_measurement_asset_id()                  trigger function
--
-- Callers are unaffected: TimescaleDB runs each job as its owner (ems_admin),
-- and trigger functions are not EXECUTE-checked when a trigger fires. Only
-- PUBLIC is revoked; every explicit grant (ems_admin, and ems_readonly on
-- production) is left exactly as it is. No routine body, owner, job,
-- schedule or data changes. On staging the REVOKE is a no-op.
--
-- Not in scope: admin.list_accessible_asset_device_relationships and
-- telemetry.resolve_primary_asset_id are PUBLIC-executable on both
-- environments and the application relies on that; they need explicit
-- grants first and are a separate change.
--
-- Rollback: GRANT EXECUTE ON ROUTINE <each routine above> TO PUBLIC;
-- ============================================================================

DO $pre$
DECLARE
    v_missing text;
BEGIN
    SELECT string_agg(r, ', ')
    INTO v_missing
    FROM unnest(ARRAY[
        'analytics.run_energy_consumption_15min_job(integer,jsonb)',
        'analytics.run_energy_consumption_hourly_job(integer,jsonb)',
        'analytics.run_energy_consumption_daily_job(integer,jsonb)',
        'telemetry.run_environment_daily_job(integer,jsonb)',
        'config.ensure_asset_demand_policy_for_site()',
        'telemetry.set_energy_measurement_asset_id()'
    ]) AS r
    WHERE to_regprocedure(r) IS NULL
       OR NOT (SELECT p.prosecdef FROM pg_proc AS p WHERE p.oid = to_regprocedure(r));
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 308 precondition failed: missing or not SECURITY DEFINER: %', v_missing;
    END IF;
END
$pre$;

CREATE TEMP TABLE migration_308_before ON COMMIT DROP AS
SELECT p.oid,
       ARRAY(SELECT a::text FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
             WHERE a::text NOT LIKE '=%' ORDER BY 1) AS named_grants,
       md5(p.prosrc) AS body,
       p.proowner
FROM pg_proc AS p
WHERE p.oid IN (
    'analytics.run_energy_consumption_15min_job(integer,jsonb)'::regprocedure,
    'analytics.run_energy_consumption_hourly_job(integer,jsonb)'::regprocedure,
    'analytics.run_energy_consumption_daily_job(integer,jsonb)'::regprocedure,
    'telemetry.run_environment_daily_job(integer,jsonb)'::regprocedure,
    'config.ensure_asset_demand_policy_for_site()'::regprocedure,
    'telemetry.set_energy_measurement_asset_id()'::regprocedure
);

REVOKE EXECUTE ON PROCEDURE analytics.run_energy_consumption_15min_job(integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE analytics.run_energy_consumption_hourly_job(integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE analytics.run_energy_consumption_daily_job(integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE telemetry.run_environment_daily_job(integer, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION config.ensure_asset_demand_policy_for_site() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION telemetry.set_energy_measurement_asset_id() FROM PUBLIC;

DO $post$
DECLARE
    v_bad text;
BEGIN
    SELECT string_agg(b.oid::regprocedure::text, ', ')
    INTO v_bad
    FROM migration_308_before AS b
    JOIN pg_proc AS p ON p.oid = b.oid
    WHERE has_function_privilege('public', p.oid, 'EXECUTE')
       OR ARRAY(SELECT a::text FROM unnest(coalesce(p.proacl, acldefault('f', p.proowner))) AS a
                WHERE a::text NOT LIKE '=%' ORDER BY 1) IS DISTINCT FROM b.named_grants
       OR md5(p.prosrc) <> b.body
       OR p.proowner <> b.proowner
       OR NOT p.prosecdef;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 308 postcondition failed: PUBLIC still executes, or a named grant / body / owner changed on %', v_bad;
    END IF;
END
$post$;
