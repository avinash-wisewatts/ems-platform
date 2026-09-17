-- ============================================================================
-- Migration 245
-- Asset View (WiseWatts dashboard redesign) -- portal-user-scoped Asset
-- Demand for the /api/v1 Analytics API's new
-- GET /sites/{site_id}/assets/{asset_id}/demand and .../demand/current
-- endpoints.
--
-- Source of record: read-only investigation of the existing Asset Demand
-- data/API path (this session, prior to any code change). Findings:
--   * analytics.demand_intervals / analytics.demand_state already support
--     scope_type='ASSET' natively (migration 130's own CHECK constraint
--     and partial index ix_demand_intervals_asset_time(asset_id,
--     interval_start DESC) WHERE asset_id IS NOT NULL), and are actively,
--     automatically populated for every asset with a PRIMARY_METER device
--     by the existing analytics.refresh_demand_analytics job (migration
--     132), which already loops SITE UNION ALL ASSET in one pass -- proven
--     by scripts/test/assert_asset_demand_automatic_decoupling.sh.
--   * The only existing read path, analytics.get_grafana_asset_demand_-
--     summary (migration 019/138), is tenant-scoped by grafana_org_id, not
--     portal_user_id -- the wrong auth boundary for this API, exactly the
--     same reasoning already applied when migration 244 built a portal
--     wrapper instead of reusing analytics.get_grafana_asset_energy_-
--     intervals directly. It is also current-value-only (no historical
--     series/peak parameter).
--   * No portal-scoped asset demand function existed anywhere before this
--     migration.
--
-- This migration mirrors migration 233 (Site Demand) exactly, substituting
-- SITE -> ASSET and admin.portal_user_can_access_site -> admin.portal_-
-- user_can_access_asset (migration 022, already used by the existing
-- asset live-state/energy-consumption routes). Unlike migration 244, this
-- does NOT need to bridge to a grafana_org_id or wrap any analytics.
-- get_grafana_* function -- analytics.demand_intervals/demand_state
-- already carry asset_id directly, so the read is a direct, unwrapped
-- filter, exactly like migration 233's SITE functions.
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration 233):
--   Two new functions in schema analytics, each:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_asset(bigint, uuid) function -- a
--       caller that cannot see the asset (via its site) gets ZERO ROWS,
--       never an error.
--
--   1. analytics.get_portal_asset_demand_series(bigint, uuid, timestamptz,
--        timestamptz) RETURNS TABLE(interval_start, interval_end,
--        demand_kw, peak_power_kw, quality_status, coverage_percent)
--        Reads analytics.demand_intervals ONLY, filtered to
--        scope_type = 'ASSET' AND asset_id = p_asset_id. Native interval
--        grain only (whatever config.site_demand_policies.demand_interval_
--        seconds produced -- the auto-backfilled platform-managed ASSET
--        policy is 900 seconds), no resolution parameter, matching Site
--        Demand's own rationale exactly.
--
--   2. analytics.get_portal_asset_current_demand(bigint, uuid) RETURNS
--        TABLE(interval_start, interval_end, current_demand_kw,
--        current_demand_kva, quality_status, coverage_percent)
--        Reads analytics.demand_state ONLY, the single most recent row for
--        the asset.
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.get_grafana_asset_demand_summary,
--     analytics.v_grafana_asset_demand_state/intervals, or any Grafana
--     dashboard/panel that reads them.
--   * Does NOT modify analytics.demand_intervals, analytics.demand_state,
--     analytics.calculate_demand_window, analytics.refresh_demand_-
--     analytics, analytics.resolve_demand_capability, or the demand
--     calculation job -- that pipeline already runs and is already tested;
--     this migration only adds a read path over its output.
--   * No reference to analytics.v_energy_demand_15min,
--     analytics.v_energy_peak_demand_daily/monthly,
--     analytics.v_energy_site_demand_kpis, analytics.v_energy_load_profile_*
--     (the older SUM-across-devices family) -- same prohibition as
--     migration 233, postcondition-checked identically.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement anywhere in either
--     function body.
--
-- Rollback: DROP FUNCTION analytics.get_portal_asset_demand_series
-- (bigint, uuid, timestamptz, timestamptz); DROP FUNCTION analytics.
-- get_portal_asset_current_demand(bigint, uuid); safe, no existing object
-- is altered by this migration (matches migration 244's inline-rollback
-- convention -- no separate maintenance/ file).
--
-- New tests:
--   app/tests/test_analytics_api_v1_asset_demand_routes.py (HTTP contract,
--   mocked service boundary, mirrors test_analytics_api_v1_demand_routes.py
--   / test_analytics_api_v1_asset_energy_routes.py).
--   scripts/test/assert_asset_demand_portal_read.sh (data-driven, real
--   disposable-DB rows: correct returned values, asset/tenant
--   authorization isolation, no-data asset, range/window boundary
--   behavior -- directly against the two functions this migration adds).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_asset(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 245 precondition failed: admin.portal_user_can_access_asset(bigint, uuid) is missing (migration 022).';
    END IF;

    IF to_regclass('analytics.demand_intervals') IS NULL THEN
        RAISE EXCEPTION 'Migration 245 precondition failed: analytics.demand_intervals is missing (migration 130).';
    END IF;

    IF to_regclass('analytics.demand_state') IS NULL THEN
        RAISE EXCEPTION 'Migration 245 precondition failed: analytics.demand_state is missing (migration 130).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'demand_intervals'
          AND column_name = 'asset_id'
    ) THEN
        RAISE EXCEPTION 'Migration 245 precondition failed: analytics.demand_intervals.asset_id is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'demand_state'
          AND column_name = 'asset_id'
    ) THEN
        RAISE EXCEPTION 'Migration 245 precondition failed: analytics.demand_state.asset_id is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_asset_demand_series(bigint, uuid, timestamptz,
--    timestamptz)
--    Historical, finalized, asset-scoped demand intervals. Empty for an
--    inaccessible or unknown asset, or an asset with no demand data (e.g.
--    no PRIMARY_METER device was ever assigned).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_asset_demand_series
(
    p_portal_user_id BIGINT,
    p_asset_id       UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ
)
RETURNS TABLE
(
    interval_start   TIMESTAMPTZ,
    interval_end     TIMESTAMPTZ,
    demand_kw        DOUBLE PRECISION,
    peak_power_kw    DOUBLE PRECISION,
    quality_status   TEXT,
    coverage_percent NUMERIC
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT
        di.interval_start,
        di.interval_end,
        di.demand_kw,
        di.peak_power_kw,
        di.quality_status,
        di.coverage_percent
    FROM analytics.demand_intervals AS di
    WHERE di.asset_id = p_asset_id
      AND di.scope_type = 'ASSET'
      AND di.interval_start >= p_from
      AND di.interval_start < p_to
      AND admin.portal_user_can_access_asset(p_portal_user_id, p_asset_id)
    ORDER BY di.interval_start;
$function$;

ALTER FUNCTION analytics.get_portal_asset_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- 2. analytics.get_portal_asset_current_demand(bigint, uuid)
--    Most recent live demand_state row for the asset. Empty for an
--    inaccessible or unknown asset, or an asset with no demand state yet.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_asset_current_demand
(
    p_portal_user_id BIGINT,
    p_asset_id       UUID
)
RETURNS TABLE
(
    interval_start     TIMESTAMPTZ,
    interval_end       TIMESTAMPTZ,
    current_demand_kw  DOUBLE PRECISION,
    current_demand_kva DOUBLE PRECISION,
    quality_status     TEXT,
    coverage_percent   NUMERIC
)
LANGUAGE SQL
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
    SELECT
        ds.interval_start,
        ds.interval_end,
        ds.current_demand_kw,
        ds.current_demand_kva,
        ds.quality_status,
        ds.coverage_percent
    FROM analytics.demand_state AS ds
    WHERE ds.asset_id = p_asset_id
      AND ds.scope_type = 'ASSET'
      AND admin.portal_user_can_access_asset(p_portal_user_id, p_asset_id)
    ORDER BY ds.interval_start DESC
    LIMIT 1;
$function$;

ALTER FUNCTION analytics.get_portal_asset_current_demand(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_current_demand(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_current_demand(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- same architectural guards migration 233 enforces for Site Demand.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT;
    v_body TEXT := '';
BEGIN
    FOR v_sig IN
        SELECT unnest(ARRAY[
            'analytics.get_portal_asset_demand_series(bigint, uuid, timestamptz, timestamptz)',
            'analytics.get_portal_asset_current_demand(bigint, uuid)'
        ])
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND EXISTS (
                  SELECT 1 FROM unnest(coalesce(p.proconfig, ARRAY[]::text[])) AS c
                  WHERE c LIKE 'search_path=%'
              )
        ) THEN
            RAISE EXCEPTION 'Migration 245 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;

        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 245 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 245 postcondition failed: % is not executable by ems_app.', v_sig;
        END IF;

        v_body := v_body || lower(pg_get_functiondef(v_sig::regprocedure)) || E'\n';
    END LOOP;

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 245 postcondition failed: an asset-demand-read function contains a write statement.';
    END IF;

    IF position('v_energy_demand_15min' IN v_body) > 0
       OR position('v_energy_site_demand_kpis' IN v_body) > 0
       OR position('v_energy_peak_demand' IN v_body) > 0
       OR position('v_energy_load_profile' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 245 postcondition failed: an asset-demand-read function references the older SUM-across-devices view family, which is prohibited by the same Slice B decision migration 233 already enforces.';
    END IF;

    IF position('site_energy_meter_roles' IN v_body) > 0
       OR position('resolve_demand_capability' IN v_body) > 0
       OR position('get_grafana_asset_demand_summary' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 245 postcondition failed: an asset-demand-read function re-derives meter-role resolution or reuses the grafana_org_id-scoped summary function -- demand_intervals/demand_state are already meter-role-resolved upstream, and this API is portal_user_id-scoped, not grafana_org_id-scoped.';
    END IF;

    RAISE NOTICE 'Migration 245: all postconditions passed (portal-scoped asset demand read functions created; read-only; demand_intervals/demand_state source confirmed; no SUM-across-devices view or grafana summary function referenced; no query-time meter-role re-resolution).';
END;
$post$;
