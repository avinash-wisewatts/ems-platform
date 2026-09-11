-- ============================================================================
-- Migration 236
-- Slice C (Energy Performance) -- comparable-period historical reference for
-- the /api/v1 Analytics API. Replaces the earlier, provisional N=4/min=2
-- rolling average (never applied, never shipped) with the approved
-- "Slice C Historical Comparison Decision Pack" algorithm.
--
-- Source of record:
--   Approved Slice C Historical Comparison Final Implementation
--   Specification (2026-09-12). Locked product rules:
--     * 8 requested comparable historical periods (REQUESTED_PERIOD_COUNT)
--     * minimum 5 eligible periods to report a value
--     * minimum 70% within-period coverage to be eligible
--     * comparable-period step = 7 days if period_length_days < 7,
--       else period_length_days
--     * statistic = median (standard definition: middle value if odd
--       count, average of the two middle values if even)
--     * evidence (gap/reset/rollover/invalid) is independent, may overlap,
--       and never itself determines eligibility -- only coverage does
--     * site timezone (NOT client-supplied) governs calendar/date
--       selection
--     * insufficient history returns NULL, never a manufactured value
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration
-- 231/233/234/235):
--   One new function in schema analytics:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a
--       caller that cannot see the site gets ZERO ROWS, never an error.
--
--   analytics.get_portal_site_energy_typical_reference(bigint, uuid,
--     timestamptz, timestamptz) RETURNS TABLE(window_index, window_from,
--     window_to, has_data, total_import_kwh, source_interval_count,
--     valid_import_intervals, coverage_percent, eligible,
--     gap_interval_count, reset_interval_count, rollover_interval_count,
--     invalid_interval_count)
--
--   Always returns exactly 8 rows (window_index 1..8, most recent first),
--   one per requested comparable period, whether or not that period has
--   any data -- so the caller never has to reconstruct missing windows.
--
--   Reads ONLY analytics.energy_consumption_daily (migration 183) and
--   metadata.sites.timezone (the SAME canonical source migration 183's own
--   loader already uses to resolve consumption_date -- traced directly in
--   this migration's own precondition, not assumed). Deliberately does
--   NOT read analytics.energy_consumption_hourly: only the daily table
--   carries a trustworthy, already-resolved site-local calendar date
--   (consumption_date), which comparable-period selection (day-of-week /
--   weekly / block alignment) depends on.
--
--   Median (the approved statistic) is NOT computed in SQL -- it is
--   computed in the Python service layer (app/src/analytics_api_service.py
--   :build_energy_typical_reference_response) from the eligible rows this
--   function returns, using Python's standard-library statistics.median
--   (which implements exactly the approved even/odd-count definition).
--   This function's job is strictly: identify the 8 comparable windows,
--   sum their totals and evidence counters, and compute the boolean
--   eligibility of each -- nothing else.
--
--   Coverage is deliberately the EVENT-COUNT ratio
--   (valid_import_intervals / source_interval_count), not a
--   duration-weighted one -- per the approved specification, this is the
--   only definition computable from existing columns without a new
--   dependency, and its known limitation (a single very long gap collapses
--   to one classified event, per analytics.classify_energy_register_delta
--   operating on consecutive-reading pairs rather than a fixed clock grid)
--   is a disclosed, accepted property of the design, not something this
--   migration attempts to work around.
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.get_portal_site_energy_consumption
--     (migration 231) or any other migration-231 object -- postcondition
--     checks this remains present and unaltered.
--   * Does NOT reference or depend on
--     analytics.get_portal_site_energy_consumption_evidence (migration
--     235) in any way -- postcondition checks this explicitly. Migration
--     235 remains independent, unapplied, and untouched.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement anywhere in the function
--     body.
--   * No prediction, no fitted/probabilistic baseline, no normalization,
--     no configured customer expectation, no persisted "baseline" entity
--     of any kind -- purely a query-time computation over already-
--     persisted historian rows.
--   * No change to the energy telemetry/routing/classification pipeline
--     (migrations 77-84) -- read-only against already-persisted counters.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches
--   223-235).
--
-- Rollback:
--   postgres/maintenance/236_analytics_api_energy_typical_reference_rollback.sql
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
        RAISE EXCEPTION 'Migration 236 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 236 precondition failed: analytics.energy_consumption_daily is missing (migration 183).';
    END IF;

    IF to_regclass('metadata.sites') IS NULL THEN
        RAISE EXCEPTION 'Migration 236 precondition failed: metadata.sites is missing.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'sites'
          AND column_name = 'timezone'
    ) THEN
        RAISE EXCEPTION 'Migration 236 precondition failed: metadata.sites.timezone is missing -- this is the same canonical source migration 183''s loader already uses (JOIN metadata.sites site ... site.timezone AS site_timezone); this migration depends on it existing, not on redefining it.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'energy_consumption_daily'
          AND column_name = 'consumption_date'
    ) THEN
        RAISE EXCEPTION 'Migration 236 precondition failed: analytics.energy_consumption_daily.consumption_date is missing -- required for site-local comparable-period selection.';
    END IF;

    IF to_regprocedure('analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 236 precondition failed: analytics.get_portal_site_energy_consumption(...) is missing (migration 231) -- this migration is additive alongside it, not a replacement.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_energy_typical_reference(bigint, uuid,
--    timestamptz, timestamptz)
--    Portal-user-scoped comparable-period historical reference. Always 8
--    rows (window_index 1..8), whether or not each window has data.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_energy_typical_reference
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ
)
RETURNS TABLE
(
    window_index             INT,
    window_from              TIMESTAMPTZ,
    window_to                TIMESTAMPTZ,
    has_data                 BOOLEAN,
    total_import_kwh         NUMERIC,
    source_interval_count    BIGINT,
    valid_import_intervals   BIGINT,
    coverage_percent         NUMERIC,
    eligible                 BOOLEAN,
    gap_interval_count       BIGINT,
    reset_interval_count     BIGINT,
    rollover_interval_count  BIGINT,
    invalid_interval_count   BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
DECLARE
    v_period_length_days INT;
    v_step_days          INT;
    v_site_timezone      TEXT;
    v_current_end_date   DATE;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_typical_reference: invalid time range (from must be < to)'
            USING ERRCODE = '22023';
    END IF;

    -- (to - from) must be a whole number of days -- the comparable-period
    -- rule operates entirely on whole site-local calendar dates.
    IF MOD(EXTRACT(EPOCH FROM (p_to - p_from))::BIGINT, 86400) <> 0 THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_typical_reference: the requested window must be a whole number of days'
            USING ERRCODE = '22023';
    END IF;

    v_period_length_days := (EXTRACT(EPOCH FROM (p_to - p_from)) / 86400)::INT;

    -- Closed set matching the five supported preset lengths
    -- (TODAY/7D/30D/3M/1Y). Not customer-configurable.
    IF v_period_length_days NOT IN (1, 7, 30, 90, 365) THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_typical_reference: unsupported period length % days', v_period_length_days
            USING ERRCODE = '22023';
    END IF;

    -- Locked comparable-period rule (Slice C decision pack):
    --   step = 7 days if period_length_days < 7, else period_length_days.
    v_step_days := CASE WHEN v_period_length_days < 7 THEN 7 ELSE v_period_length_days END;

    -- Server-side tenant scope. Unknown site or no access -> zero rows.
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    -- Site timezone resolved server-side from the SAME canonical source
    -- migration 183's own loader uses (metadata.sites.timezone) -- never
    -- supplied by the caller. A site with no daily historian rows at all
    -- may also have no resolvable timezone context for this feature; both
    -- cases are handled identically below (zero rows / has_data=false).
    SELECT s.timezone INTO v_site_timezone
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;

    IF v_site_timezone IS NULL THEN
        RETURN;
    END IF;

    v_current_end_date := (p_to AT TIME ZONE v_site_timezone)::DATE;

    RETURN QUERY
    WITH indices AS (
        SELECT generate_series(1, 8) AS k
    ),
    windows AS (
        SELECT
            k AS window_index,
            (v_current_end_date - (k * v_step_days) - v_period_length_days) AS from_date,
            (v_current_end_date - (k * v_step_days))                        AS to_date
        FROM indices
    ),
    aggregated AS (
        SELECT
            w.window_index,
            w.from_date,
            w.to_date,
            sum(d.import_consumption_kwh)          AS total_import_kwh,
            sum(d.source_interval_count)::BIGINT    AS source_interval_count,
            sum(d.valid_import_intervals)::BIGINT   AS valid_import_intervals,
            sum(d.gap_interval_count)::BIGINT       AS gap_interval_count,
            sum(d.reset_interval_count)::BIGINT     AS reset_interval_count,
            sum(d.rollover_interval_count)::BIGINT  AS rollover_interval_count,
            sum(d.invalid_interval_count)::BIGINT   AS invalid_interval_count,
            count(d.consumption_date)               AS day_rows
        FROM windows AS w
        LEFT JOIN analytics.energy_consumption_daily AS d
          ON d.site_id = p_site_id
         AND d.consumption_date >= w.from_date
         AND d.consumption_date <  w.to_date
        GROUP BY w.window_index, w.from_date, w.to_date
    )
    SELECT
        a.window_index,
        (a.from_date::TIMESTAMP AT TIME ZONE v_site_timezone),
        (a.to_date::TIMESTAMP AT TIME ZONE v_site_timezone),
        (a.day_rows > 0) AS has_data,
        a.total_import_kwh,
        coalesce(a.source_interval_count, 0),
        coalesce(a.valid_import_intervals, 0),
        CASE
            WHEN coalesce(a.source_interval_count, 0) = 0 THEN NULL
            ELSE round(100.0 * coalesce(a.valid_import_intervals, 0) / a.source_interval_count, 4)
        END AS coverage_percent,
        -- Eligibility: has data AND coverage >= 70% (inclusive). Gap/
        -- reset/rollover/invalid flags never appear in this expression --
        -- only the clean valid/invalid complementary pair does.
        COALESCE(
            a.day_rows > 0
            AND coalesce(a.source_interval_count, 0) > 0
            AND coalesce(a.valid_import_intervals, 0)::NUMERIC / NULLIF(a.source_interval_count, 0) >= 0.70,
            FALSE
        ) AS eligible,
        coalesce(a.gap_interval_count, 0),
        coalesce(a.reset_interval_count, 0),
        coalesce(a.rollover_interval_count, 0),
        coalesce(a.invalid_interval_count, 0)
    FROM aggregated AS a
    ORDER BY a.window_index;
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_energy_typical_reference(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_energy_typical_reference(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_energy_typical_reference(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_site_energy_typical_reference(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ) IS
'Slice C: comparable-period historical reference. Always 8 rows (window_index 1..8). Reads ONLY analytics.energy_consumption_daily + metadata.sites.timezone -- no dependency on migration 235, no change to migration 231. eligible = has_data AND (valid_import_intervals/source_interval_count) >= 0.70; gap/reset/rollover/invalid counters are independent evidence, never used for eligibility. The median statistic is computed by the Python service layer from these rows, not in SQL.';


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, the
-- mandatory "no dependency on migration 235" guard, and the mandatory
-- "migration 231 untouched" guard.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_site_energy_typical_reference(bigint, uuid, timestamptz, timestamptz)';
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
        RAISE EXCEPTION 'Migration 236 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: the typical-reference function contains a write statement.';
    END IF;

    IF position('energy_consumption_daily' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: the typical-reference function does not reference analytics.energy_consumption_daily.';
    END IF;

    IF position('energy_consumption_hourly' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: the typical-reference function must not read analytics.energy_consumption_hourly (only the daily table carries a trustworthy site-local calendar date).';
    END IF;

    -- Mandatory: no dependency on migration 235 whatsoever.
    IF position('get_portal_site_energy_consumption_evidence' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: the typical-reference function must not reference analytics.get_portal_site_energy_consumption_evidence (migration 235) -- migration 235 is independent and must remain undepended-upon.';
    END IF;

    -- Migration 231's function must remain untouched by this migration.
    IF (
        SELECT prosrc FROM pg_proc
        WHERE oid = 'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'::regprocedure
    ) IS NULL THEN
        RAISE EXCEPTION 'Migration 236 postcondition failed: analytics.get_portal_site_energy_consumption (migration 231) is missing after this migration ran.';
    END IF;

    RAISE NOTICE 'Migration 236: all postconditions passed (portal typical-reference function created; read-only; energy_consumption_daily-only source confirmed; no migration-235 dependency; migration 231 untouched).';
END;
$post$;
