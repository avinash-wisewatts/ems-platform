-- ============================================================================
-- Migration 234
-- Slice B (Power Quality backend, D1) -- read-only, portal-user-scoped
-- Power Factor / current THD for the /api/v1 Analytics API.
--
-- Source of record:
--   Approved Slice B implementation decision pack: PQ has NO existing
--   portal-facing resolution pipeline (unlike Demand). This migration
--   introduces the one genuinely new piece of Slice B: a small, additive
--   meter-role JOIN directly against config.site_energy_meter_roles,
--   independent of the Demand-specific config.site_demand_policies /
--   analytics.resolve_demand_capability path.
--
-- Verified source data (this session, direct DDL read -- not assumed):
--   telemetry.ca_energy_15min / ca_energy_hourly / ca_energy_daily
--   (migrations 51/52/53) each carry, per (bucket_start, organization_id,
--   site_id, device_id): power_factor_total_avg/min/max,
--   current_thd_l1_percent_avg/max, current_thd_l2_percent_avg/max,
--   current_thd_l3_percent_avg/max.
--
--   IMPORTANT CORRECTION FROM THE APPROVED PLAN: there is NO
--   current_thd_total_percent (or similarly named single-figure) column in
--   any of the three continuous aggregates -- only per-phase L1/L2/L3.
--   Unlike telemetry.energy_measurements (the raw table), the aggregates
--   never rolled up a "total" THD column. This migration therefore returns
--   all three phases explicitly rather than inventing a derived average or
--   arbitrarily picking one phase. See app/src/analytics_api_service.py
--   for the corresponding response-shape change from the originally
--   planned single "parameter" selector.
--
-- What this migration does (ADDITIVE ONLY):
--   One new function in schema analytics:
--
--   analytics.get_portal_site_power_quality_series(bigint, uuid, text,
--     timestamptz, timestamptz) RETURNS TABLE(bucket_start,
--     power_factor_avg, power_factor_min, power_factor_max,
--     current_thd_l1_avg, current_thd_l1_max, current_thd_l2_avg,
--     current_thd_l2_max, current_thd_l3_avg, current_thd_l3_max)
--
--     * SECURITY DEFINER, STABLE, pinned SET search_path, no dynamic SQL
--       (LANGUAGE plpgsql with static, literal branch queries per
--       resolution -- no EXECUTE/format() anywhere; each branch is a
--       complete, fixed SELECT against one specific, named continuous
--       aggregate, chosen by a plain IF/ELSIF on the closed p_resolution
--       vocabulary {'15min','1h','1d'} -- not a dynamically constructed
--       query),
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a
--       caller that cannot see the site gets ZERO ROWS, never an error,
--     * resolves the site's authoritative meter by JOINing DIRECTLY against
--       config.site_energy_meter_roles WHERE meter_role = 'SITE_CONSUMPTION'
--       (the exclusive-per-site, "authoritative directly measured total
--       site consumption" role -- migration 100) AND is_active AND
--       now() is within the row's effective_range. A site with no such
--       device configured returns ZERO ROWS, not an error.
--
-- What this migration does NOT do:
--   * Does NOT reference config.site_demand_policies or
--     analytics.resolve_demand_capability (the Demand-specific policy
--     path) anywhere -- PQ resolution is independent, per the approved
--     plan (postcondition-checked below).
--   * Does NOT invent a PF/THD threshold, target value, or "material
--     deviation" classification -- no such configuration exists anywhere
--     in the schema (confirmed absent this session); out of scope.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement in the function body.
--   * Does not alter telemetry.ca_energy_15min/hourly/daily or any
--     existing v_grafana_* object.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches
--   223-233).
--
-- Rollback: postgres/maintenance/234_analytics_api_power_quality_rollback.sql
--   -- dependency-checked, no CASCADE, safe if never applied.
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
        RAISE EXCEPTION 'Migration 234 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('config.site_energy_meter_roles') IS NULL THEN
        RAISE EXCEPTION 'Migration 234 precondition failed: config.site_energy_meter_roles is missing (migration 85).';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.site_energy_roles WHERE role_code = 'SITE_CONSUMPTION') THEN
        RAISE EXCEPTION 'Migration 234 precondition failed: config.site_energy_roles has no SITE_CONSUMPTION row (migration 100).';
    END IF;

    IF to_regclass('telemetry.ca_energy_15min') IS NULL
       OR to_regclass('telemetry.ca_energy_hourly') IS NULL
       OR to_regclass('telemetry.ca_energy_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 234 precondition failed: telemetry.ca_energy_15min / ca_energy_hourly / ca_energy_daily not all present (migrations 51/52/53).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'telemetry' AND table_name = 'ca_energy_hourly'
          AND column_name = 'power_factor_total_avg'
    ) THEN
        RAISE EXCEPTION 'Migration 234 precondition failed: telemetry.ca_energy_hourly.power_factor_total_avg is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_power_quality_series(bigint, uuid, text,
--    timestamptz, timestamptz)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_power_quality_series
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_resolution     TEXT,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ
)
RETURNS TABLE
(
    bucket_start       TIMESTAMPTZ,
    power_factor_avg   DOUBLE PRECISION,
    power_factor_min   DOUBLE PRECISION,
    power_factor_max   DOUBLE PRECISION,
    current_thd_l1_avg DOUBLE PRECISION,
    current_thd_l1_max DOUBLE PRECISION,
    current_thd_l2_avg DOUBLE PRECISION,
    current_thd_l2_max DOUBLE PRECISION,
    current_thd_l3_avg DOUBLE PRECISION,
    current_thd_l3_max DOUBLE PRECISION
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, config, telemetry
AS $function$
DECLARE
    v_device_id UUID;
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    SELECT mr.device_id
      INTO v_device_id
    FROM config.site_energy_meter_roles AS mr
    WHERE mr.site_id = p_site_id
      AND mr.meter_role = 'SITE_CONSUMPTION'
      AND mr.is_active
      AND now() <@ mr.effective_range
    LIMIT 1;

    IF v_device_id IS NULL THEN
        RETURN;
    END IF;

    IF p_resolution = '15min' THEN
        RETURN QUERY
        SELECT
            c.bucket_start,
            c.power_factor_total_avg, c.power_factor_total_min, c.power_factor_total_max,
            c.current_thd_l1_percent_avg, c.current_thd_l1_percent_max,
            c.current_thd_l2_percent_avg, c.current_thd_l2_percent_max,
            c.current_thd_l3_percent_avg, c.current_thd_l3_percent_max
        FROM telemetry.ca_energy_15min AS c
        WHERE c.site_id = p_site_id
          AND c.device_id = v_device_id
          AND c.bucket_start >= p_from
          AND c.bucket_start < p_to
        ORDER BY c.bucket_start;

    ELSIF p_resolution = '1h' THEN
        RETURN QUERY
        SELECT
            c.bucket_start,
            c.power_factor_total_avg, c.power_factor_total_min, c.power_factor_total_max,
            c.current_thd_l1_percent_avg, c.current_thd_l1_percent_max,
            c.current_thd_l2_percent_avg, c.current_thd_l2_percent_max,
            c.current_thd_l3_percent_avg, c.current_thd_l3_percent_max
        FROM telemetry.ca_energy_hourly AS c
        WHERE c.site_id = p_site_id
          AND c.device_id = v_device_id
          AND c.bucket_start >= p_from
          AND c.bucket_start < p_to
        ORDER BY c.bucket_start;

    ELSIF p_resolution = '1d' THEN
        RETURN QUERY
        SELECT
            c.bucket_start,
            c.power_factor_total_avg, c.power_factor_total_min, c.power_factor_total_max,
            c.current_thd_l1_percent_avg, c.current_thd_l1_percent_max,
            c.current_thd_l2_percent_avg, c.current_thd_l2_percent_max,
            c.current_thd_l3_percent_avg, c.current_thd_l3_percent_max
        FROM telemetry.ca_energy_daily AS c
        WHERE c.site_id = p_site_id
          AND c.device_id = v_device_id
          AND c.bucket_start >= p_from
          AND c.bucket_start < p_to
        ORDER BY c.bucket_start;
    END IF;

    -- Any resolution outside the closed set simply returns zero rows here;
    -- the API layer rejects it as a 422 contract violation before this
    -- function is ever called (same discipline as every existing endpoint).
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_power_quality_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_power_quality_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_power_quality_series(BIGINT, UUID, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- mandatory architectural guard: PQ must not route through the
-- Demand-specific policy table.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_site_power_quality_series(bigint, uuid, text, timestamptz, timestamptz)';
    v_body TEXT;
BEGIN
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
        RAISE EXCEPTION 'Migration 234 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 234 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 234 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 234 postcondition failed: the PQ function contains a write statement or dynamic SQL.';
    END IF;

    IF position('site_demand_policies' IN v_body) > 0
       OR position('resolve_demand_capability' IN v_body) > 0
       OR position('demand_intervals' IN v_body) > 0
       OR position('demand_state' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 234 postcondition failed: the PQ function references the Demand-specific policy/resolution path, which is prohibited -- PQ must resolve its device independently via config.site_energy_meter_roles.';
    END IF;

    IF position('site_energy_meter_roles' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 234 postcondition failed: the PQ function does not reference config.site_energy_meter_roles -- the required direct meter-role JOIN is missing.';
    END IF;

    RAISE NOTICE 'Migration 234: all postconditions passed (portal Power Quality read function created; read-only; direct config.site_energy_meter_roles resolution confirmed; independent of the Demand-specific policy path).';
END;
$post$;
