-- ============================================================================
-- Migration 285
-- Analytics read latency: make analytics.energy_direction_status inlinable.
--
-- analytics.energy_direction_status (migration 279) is a pure, IMMUTABLE SQL
-- CASE over its six counters. Its SET search_path clause stops PostgreSQL
-- from inlining it, so analytics.get_portal_asset_energy_series calls it as
-- a function (with a configuration save/restore) once per 15-minute row per
-- direction: about 43,000-46,000 calls per 10-asset 15m/30m/1h request,
-- about 5.5 us each, measured on staging on 2026-09-29 (about 0.23-0.25 s per
-- request; the same CASE evaluated inline costs about 0.3 us).
--
-- Change: ALTER FUNCTION ... RESET search_path. Nothing else: the body,
-- signature, IMMUTABLE, SECURITY INVOKER, owner, grants (owner only) and
-- comment are unchanged, and the series function is not replaced. Without the
-- SET clause the planner inlines the CASE into its caller, where it is parsed
-- under the caller's pinned search_path (pg_catalog first); the body uses
-- only built-in comparison operators and text literals.
--
-- Callers (checked on staging 2026-09-29): only
-- analytics.get_portal_asset_energy_series (SECURITY DEFINER, owner
-- ems_admin, pinned search_path). No view, continuous aggregate, default,
-- constraint, index or policy uses it; get_canonical_energy_read, Grafana
-- and the Asset View do not call it; it is executable by its owner only.
--
-- Rollback: ALTER FUNCTION analytics.energy_direction_status(bigint, bigint,
--           bigint, bigint, bigint, bigint) SET search_path TO pg_catalog;
-- ============================================================================

DO $pre$
DECLARE
    v_helper TEXT := 'analytics.energy_direction_status(bigint, bigint, bigint, bigint, bigint, bigint)';
BEGIN
    IF to_regprocedure(v_helper) IS NULL THEN
        RAISE EXCEPTION 'Migration 285 precondition failed: % is missing.', v_helper;
    END IF;
    IF md5(pg_get_functiondef(v_helper::regprocedure)) <> '6a81cd347c56bd5acb8d21a2119a44ed' THEN
        RAISE EXCEPTION 'Migration 285 precondition failed: % differs from the migration 279 definition.', v_helper;
    END IF;
    IF md5(pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure))
       <> '3f43cdae3e4dbb21087d31bc77c7bab0' THEN
        RAISE EXCEPTION 'Migration 285 precondition failed: the series function differs from the migration 284 definition.';
    END IF;
END;
$pre$;

ALTER FUNCTION analytics.energy_direction_status(BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT) RESET search_path;

DO $post$
DECLARE
    v_helper TEXT := 'analytics.energy_direction_status(bigint, bigint, bigint, bigint, bigint, bigint)';
    v_plan   TEXT := '';
    v_line   TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
        WHERE p.oid = v_helper::regprocedure
          AND l.lanname = 'sql' AND p.provolatile = 'i' AND NOT p.prosecdef AND NOT p.proisstrict
          AND p.proconfig IS NULL AND r.rolname = 'ems_admin'
    ) THEN
        RAISE EXCEPTION 'Migration 285 postcondition failed: % is not an IMMUTABLE, SECURITY INVOKER SQL function without SET, owned by ems_admin.', v_helper;
    END IF;
    IF has_function_privilege('public', v_helper, 'EXECUTE')
       OR has_function_privilege('ems_app', v_helper, 'EXECUTE')
       OR has_function_privilege('grafana_reader', v_helper, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 285 postcondition failed: % must remain executable by its owner only.', v_helper;
    END IF;
    IF md5(pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure))
       <> '3f43cdae3e4dbb21087d31bc77c7bab0' THEN
        RAISE EXCEPTION 'Migration 285 postcondition failed: the series function changed.';
    END IF;
    -- The canonical precedence (as migration 279 checked it).
    IF analytics.energy_direction_status(1, 1, 1, 1, 1, 1) <> 'INVALID_INTERVALS'
       OR analytics.energy_direction_status(1, 0, 1, 1, 1, 1) <> 'RESET_DETECTED'
       OR analytics.energy_direction_status(1, 0, 0, 1, 1, 1) <> 'GAPS_DETECTED'
       OR analytics.energy_direction_status(1, 0, 0, 0, 1, 1) <> 'RECONSTRUCTED_TIMING'
       OR analytics.energy_direction_status(1, 0, 0, 0, 0, 1) <> 'ROLLOVER_DETECTED'
       OR analytics.energy_direction_status(0, 0, 0, 0, 0, 0) <> 'INVALID_INTERVALS'
       OR analytics.energy_direction_status(0, 0, 0, 0, 2, 0) <> 'RECONSTRUCTED_TIMING'
       OR analytics.energy_direction_status(1, 0, 0, 0, 0, 0) <> 'GOOD' THEN
        RAISE EXCEPTION 'Migration 285 postcondition failed: energy_direction_status precedence changed.';
    END IF;
    -- Inlined: the plan of a call over columns shows the CASE, not the function.
    FOR v_line IN EXECUTE
        'EXPLAIN (VERBOSE, COSTS OFF) SELECT analytics.energy_direction_status(g, g, g, g, g, g) '
        'FROM generate_series(0::bigint, 1::bigint) AS g'
    LOOP
        v_plan := v_plan || v_line || E'\n';
    END LOOP;
    IF position('energy_direction_status' IN v_plan) > 0 OR position('CASE' IN v_plan) = 0 THEN
        RAISE EXCEPTION 'Migration 285 postcondition failed: % is not inlined: %', v_helper, v_plan;
    END IF;
    RAISE NOTICE 'Migration 285: all postconditions passed (energy_direction_status inlinable; body, grants and series function unchanged).';
END;
$post$;
