-- ============================================================================
-- Migration 235
-- Slice C (Energy Performance, C2) -- read-only, portal-user-scoped energy
-- evidence/quality counters for the /api/v1 Analytics API.
--
-- Source of record:
--   Approved Slice C decision pack (2026-09-11). C2 requires exposing
--   evidence for the existing energy consumption series WITHOUT changing
--   analytics.get_portal_site_energy_consumption (migration 231) or the
--   existing GET /sites/{id}/energy/consumption contract in any way.
--
-- What this migration does (ADDITIVE ONLY, same pattern as migration
-- 231/233/234):
--   One new function in schema analytics:
--     * SECURITY DEFINER, STABLE, explicit parameter + return types,
--     * pinned SET search_path, no dynamic SQL,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope re-derived server-side via the established
--       admin.portal_user_can_access_site(bigint, uuid) function -- a caller
--       that cannot see the site gets ZERO ROWS, never an error.
--
--   analytics.get_portal_site_energy_consumption_evidence(bigint, uuid,
--     timestamptz, timestamptz, text) RETURNS TABLE(bucket_start,
--     source_interval_count, valid_import_intervals, invalid_import_intervals,
--     valid_export_intervals, invalid_export_intervals, gap_interval_count,
--     reset_interval_count, rollover_interval_count, invalid_interval_count,
--     first_source_bucket, last_source_bucket)
--
--   Reads EXACTLY the same two persisted historians migration 231's
--   get_portal_site_energy_consumption already reads --
--   analytics.energy_consumption_hourly (migration 181) and
--   analytics.energy_consumption_daily (migration 183) -- selecting the
--   evidence/coverage columns that already exist on those tables but were
--   never selected by migration 231. No new telemetry, no new pipeline, no
--   new table.
--
--   Semantic source chain (traced from the migration files during the
--   Slice C read-only review; the live catalog was NOT queried to confirm
--   this against a running database -- this is a static reading of the
--   canonical migration/ddl definitions, not a runtime-verified fact):
--     analytics.energy_consumption_hourly/daily.{gap,reset,rollover,
--     invalid}_interval_count (migrations 181/183, summed unchanged here)
--       <- SUM(...) from analytics.energy_consumption_15min (migration 216)
--       <- SELECT ... FROM analytics.v_energy_semantic_rollup_15min
--          (canonical current definition: postgres/ddl/
--          147_combined_energy_quality_counters.sql), whose gap_interval_
--          count / reset_interval_count / rollover_interval_count /
--          invalid_interval_count columns are each an independent
--          COUNT(*) FILTER (WHERE <flag>_detected) over FOUR SEPARATE
--          boolean conditions (gap_detected, reset_detected, rollover_
--          detected, invalid_detected -- themselves each import_X_detected
--          OR export_X_detected).
--
--   These four counters are INDEPENDENT EVIDENCE COUNTERS, NOT a
--   mutually-exclusive classification and NOT a partition of
--   source_interval_count -- a single interval CAN satisfy more than one
--   of the four flags simultaneously (the same source view elsewhere
--   collapses them to one label via a priority-ordered CASE --
--   INVALID > RESET > GAP > ROLLOVER -- for a DIFFERENT reporting path;
--   that priority resolution is deliberately NOT reproduced here). This
--   migration invents no new quality classification, does not claim these
--   four counters sum to source_interval_count, and does not attempt to
--   map them onto the unrelated five-value measurement lattice
--   (GOOD/GAP/ESTIMATED/INVALID/PARTIAL) used elsewhere in the frontend.
--
--   (valid_import_intervals / invalid_import_intervals, and their export
--   counterparts, ARE a genuine complementary pair -- each interval is
--   exactly one or the other -- and are unaffected by the above; only the
--   four *_interval_count evidence flags are potentially overlapping.)
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.get_portal_site_energy_consumption or any
--     other migration-231 object.
--   * No new table, hypertable, TimescaleDB job, trigger, or grant to
--     PUBLIC/grafana_reader. No write statement anywhere in the function body.
--   * No prediction, no fitted/probabilistic baseline, no normalization.
--   * No change to the energy telemetry/routing/classification pipeline
--     (migrations 77-84) -- read-only against already-persisted counters.
--
-- Transaction: NO BEGIN/COMMIT of its own -- scripts/apply_migrations.sh
--   wraps the file + the ledger INSERT in one transaction (matches
--   223-234).
--
-- Rollback: postgres/maintenance/235_analytics_api_energy_evidence_rollback.sql
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
        RAISE EXCEPTION 'Migration 235 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing (three-role scope model).';
    END IF;

    IF to_regclass('analytics.energy_consumption_hourly') IS NULL THEN
        RAISE EXCEPTION 'Migration 235 precondition failed: analytics.energy_consumption_hourly is missing (migration 181).';
    END IF;

    IF to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 235 precondition failed: analytics.energy_consumption_daily is missing (migration 183).';
    END IF;

    IF to_regprocedure('analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 235 precondition failed: analytics.get_portal_site_energy_consumption(...) is missing (migration 231) -- this migration is additive alongside it, not a replacement.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'energy_consumption_hourly'
          AND column_name = 'gap_interval_count'
    ) THEN
        RAISE EXCEPTION 'Migration 235 precondition failed: analytics.energy_consumption_hourly.gap_interval_count is missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_energy_consumption_evidence(bigint, uuid,
--    timestamptz, timestamptz, text)
--    Portal-user-scoped energy evidence/coverage counters. Same resolution
--    set, same [from, to) semantics, same tenant-scope discipline as
--    migration 231's get_portal_site_energy_consumption -- a deliberate
--    parallel read, not a replacement.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_energy_consumption_evidence
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT
)
RETURNS TABLE
(
    bucket_start             TIMESTAMPTZ,
    source_interval_count    BIGINT,
    valid_import_intervals   BIGINT,
    invalid_import_intervals BIGINT,
    valid_export_intervals   BIGINT,
    invalid_export_intervals BIGINT,
    gap_interval_count       BIGINT,
    reset_interval_count     BIGINT,
    rollover_interval_count  BIGINT,
    invalid_interval_count   BIGINT,
    first_source_bucket      TIMESTAMPTZ,
    last_source_bucket       TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('1h', '1d') THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption_evidence: unsupported resolution %', p_resolution
            USING ERRCODE = '22023';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption_evidence: invalid time range (from must be < to)'
            USING ERRCODE = '22023';
    END IF;

    -- Server-side tenant scope. Unknown site or no access -> zero rows.
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    IF p_resolution = '1h' THEN
        RETURN QUERY
        SELECT
            h.bucket_start,
            sum(h.source_interval_count)::BIGINT,
            sum(h.valid_import_intervals)::BIGINT,
            sum(h.invalid_import_intervals)::BIGINT,
            sum(h.valid_export_intervals)::BIGINT,
            sum(h.invalid_export_intervals)::BIGINT,
            sum(h.gap_interval_count)::BIGINT,
            sum(h.reset_interval_count)::BIGINT,
            sum(h.rollover_interval_count)::BIGINT,
            sum(h.invalid_interval_count)::BIGINT,
            min(h.first_source_bucket),
            max(h.last_source_bucket)
        FROM analytics.energy_consumption_hourly AS h
        WHERE h.site_id = p_site_id
          AND h.bucket_start >= p_from
          AND h.bucket_start <  p_to
        GROUP BY h.bucket_start
        ORDER BY h.bucket_start;
    ELSE
        RETURN QUERY
        SELECT
            d.bucket_start,
            sum(d.source_interval_count)::BIGINT,
            sum(d.valid_import_intervals)::BIGINT,
            sum(d.invalid_import_intervals)::BIGINT,
            sum(d.valid_export_intervals)::BIGINT,
            sum(d.invalid_export_intervals)::BIGINT,
            sum(d.gap_interval_count)::BIGINT,
            sum(d.reset_interval_count)::BIGINT,
            sum(d.rollover_interval_count)::BIGINT,
            sum(d.invalid_interval_count)::BIGINT,
            min(d.first_source_bucket),
            max(d.last_source_bucket)
        FROM analytics.energy_consumption_daily AS d
        WHERE d.site_id = p_site_id
          AND d.bucket_start >= p_from
          AND d.bucket_start <  p_to
        GROUP BY d.bucket_start
        ORDER BY d.bucket_start;
    END IF;
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_energy_consumption_evidence(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_energy_consumption_evidence(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_energy_consumption_evidence(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_site_energy_consumption_evidence(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS
'Slice C (C2): portal-scoped energy evidence counters, read from the same analytics.energy_consumption_hourly/daily historians as migration 231''s get_portal_site_energy_consumption. Additive parallel read; does not modify or duplicate migration 231. gap_interval_count/reset_interval_count/rollover_interval_count/invalid_interval_count are INDEPENDENT evidence counters sourced from analytics.v_energy_semantic_rollup_15min (postgres/ddl/147_combined_energy_quality_counters.sql) -- NOT a mutually-exclusive classification, NOT guaranteed to sum to source_interval_count, and NOT mapped onto the unrelated five-value measurement lattice.';


-- ----------------------------------------------------------------------------
-- Postconditions -- ownership/grant hygiene, read-only-body proof, and the
-- mandatory architectural guard: this function must not modify migration
-- 231's function, must not write, and must read only the two named
-- historians.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_site_energy_consumption_evidence(bigint, uuid, timestamptz, timestamptz, text)';
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
        RAISE EXCEPTION 'Migration 235 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 235 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 235 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));

    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 235 postcondition failed: the evidence function contains a write statement.';
    END IF;

    IF position('energy_consumption_hourly' IN v_body) = 0
       OR position('energy_consumption_daily' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 235 postcondition failed: the evidence function does not reference both analytics.energy_consumption_hourly and analytics.energy_consumption_daily.';
    END IF;

    -- Migration 231's function must remain untouched by this migration.
    IF (
        SELECT prosrc FROM pg_proc
        WHERE oid = 'analytics.get_portal_site_energy_consumption(bigint, uuid, timestamptz, timestamptz, text)'::regprocedure
    ) IS NULL THEN
        RAISE EXCEPTION 'Migration 235 postcondition failed: analytics.get_portal_site_energy_consumption (migration 231) is missing after this migration ran.';
    END IF;

    RAISE NOTICE 'Migration 235: all postconditions passed (portal energy-evidence read function created; read-only; energy_consumption_hourly/daily source confirmed; migration 231 untouched).';
END;
$post$;
