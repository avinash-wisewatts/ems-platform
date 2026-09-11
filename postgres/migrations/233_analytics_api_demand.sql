-- ============================================================================
-- Migration 233
-- Slice B (Demand backend, B1) -- read-only, portal-user-scoped Maximum
-- Demand for the /api/v1 Analytics API.
--
-- Source of record:
--   Approved Slice B implementation decision pack: Demand MUST read the
--   already meter-role-resolved analytics.demand_intervals /
--   analytics.demand_state -- NOT re-derive meter-role resolution at portal
--   query time, and NOT reuse analytics.v_energy_demand_15min /
--   analytics.v_energy_site_demand_kpis (the older SUM-across-devices
--   pattern, unrelated to the meter-role/policy pipeline).
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration
-- 231/232):
--   Two new functions in schema analytics, each:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a caller
--       that cannot see the site gets ZERO ROWS, never an error.
--
--   1. analytics.get_portal_site_demand_series(bigint, uuid, timestamptz,
--        timestamptz) RETURNS TABLE(interval_start, interval_end,
--        demand_kw, peak_power_kw, quality_status, coverage_percent)
--        Reads analytics.demand_intervals ONLY, filtered to
--        scope_type = 'SITE'. Returns the interval as already computed and
--        already quality-tagged upstream (by analytics.calculate_demand_
--        window / migration 132) -- no recalculation, no re-aggregation,
--        no meter-role JOIN. Native interval grain only (whatever
--        config.site_demand_policies.demand_interval_seconds produced for
--        that site, 900 or 1800 seconds) -- there is no separate
--        coarser-resolution persisted demand tier to select between, so
--        this function takes no resolution parameter.
--
--   2. analytics.get_portal_site_current_demand(bigint, uuid) RETURNS
--        TABLE(interval_start, interval_end, current_demand_kw,
--        current_demand_kva, quality_status, coverage_percent)
--        Reads analytics.demand_state ONLY (the live/current-interval
--        table, distinct from the finalized historical demand_intervals),
--        the single most recent row for the site.
--
-- What this migration does NOT do:
--   * No reference to analytics.v_energy_demand_15min,
--     analytics.v_energy_peak_demand_daily/monthly,
--     analytics.v_energy_site_demand_kpis, analytics.v_energy_load_profile_*
--     (migration 58's older, non-meter-role SUM-across-devices family).
--   * No reference to config.site_energy_meter_roles,
--     config.site_demand_policies, or analytics.resolve_demand_capability --
--     that resolution already ran upstream when demand_intervals /
--     demand_state were populated; this migration does not repeat it.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement anywhere in either function
--     body.
--   * No contract-demand / sanctioned-load column or comparison -- no such
--     configuration exists in the schema (confirmed absent in the approved
--     decision pack); out of scope for this migration.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches
--   223-232).
--
-- Rollback: postgres/maintenance/233_analytics_api_demand_rollback.sql --
--   dependency-checked, no CASCADE, safe if never applied.
--
-- NOT APPLIED as part of this implementation increment -- source-code /
-- migration-file change only. No remote or local database write occurs
-- from authoring this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 233 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('analytics.demand_intervals') IS NULL THEN
        RAISE EXCEPTION 'Migration 233 precondition failed: analytics.demand_intervals is missing (migration 130).';
    END IF;

    IF to_regclass('analytics.demand_state') IS NULL THEN
        RAISE EXCEPTION 'Migration 233 precondition failed: analytics.demand_state is missing (migration 130).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'demand_intervals'
          AND column_name = 'quality_status'
    ) THEN
        RAISE EXCEPTION 'Migration 233 precondition failed: analytics.demand_intervals.quality_status is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_demand_series(bigint, uuid, timestamptz,
--    timestamptz)
--    Historical, finalized, site-scoped demand intervals. Empty for an
--    inaccessible or unknown site.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_demand_series
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
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
    WHERE di.site_id = p_site_id
      AND di.scope_type = 'SITE'
      AND di.interval_start >= p_from
      AND di.interval_start < p_to
      AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    ORDER BY di.interval_start;
$function$;

ALTER FUNCTION analytics.get_portal_site_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_demand_series(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- 2. analytics.get_portal_site_current_demand(bigint, uuid)
--    Most recent live demand_state row for the site. Empty for an
--    inaccessible or unknown site, or a site with no demand state yet.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_current_demand
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
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
    WHERE ds.site_id = p_site_id
      AND ds.scope_type = 'SITE'
      AND admin.portal_user_can_access_site(p_portal_user_id, p_site_id)
    ORDER BY ds.interval_start DESC
    LIMIT 1;
$function$;

ALTER FUNCTION analytics.get_portal_site_current_demand(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_current_demand(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_current_demand(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- mandatory architectural guard: neither function may reference the older
-- SUM-across-devices view family or re-derive meter-role resolution.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT;
    v_body TEXT := '';
BEGIN
    FOR v_sig IN
        SELECT unnest(ARRAY[
            'analytics.get_portal_site_demand_series(bigint, uuid, timestamptz, timestamptz)',
            'analytics.get_portal_site_current_demand(bigint, uuid)'
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
            RAISE EXCEPTION 'Migration 233 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;

        IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 233 postcondition failed: % is executable by PUBLIC.', v_sig;
        END IF;
        IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 233 postcondition failed: % is not executable by ems_app.', v_sig;
        END IF;

        v_body := v_body || lower(pg_get_functiondef(v_sig::regprocedure)) || E'\n';
    END LOOP;

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 233 postcondition failed: a demand-read function contains a write statement.';
    END IF;

    IF position('v_energy_demand_15min' IN v_body) > 0
       OR position('v_energy_site_demand_kpis' IN v_body) > 0
       OR position('v_energy_peak_demand' IN v_body) > 0
       OR position('v_energy_load_profile' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 233 postcondition failed: a demand-read function references the older SUM-across-devices view family (v_energy_demand_15min / v_energy_site_demand_kpis / v_energy_peak_demand_* / v_energy_load_profile_*), which is prohibited by the approved Slice B decision.';
    END IF;

    IF position('site_energy_meter_roles' IN v_body) > 0
       OR position('resolve_demand_capability' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 233 postcondition failed: a demand-read function re-derives meter-role resolution at portal query time, which is prohibited -- demand_intervals/demand_state are already meter-role-resolved upstream.';
    END IF;

    RAISE NOTICE 'Migration 233: all postconditions passed (portal Demand read functions created; read-only; demand_intervals/demand_state source confirmed; no SUM-across-devices view referenced; no query-time meter-role re-resolution).';
END;
$post$;
