-- ============================================================================
-- Migration 248
-- Main Dashboard Energy Usage chart -- server-side Weekly/Monthly/Yearly
-- aggregation for GET /sites/{site_id}/energy/consumption (widens its
-- `resolution` enum; does not change its path, response shape, or its
-- existing 1h/1d behavior).
--
-- Source of record: this session's read-only architecture investigation
-- (reported to the user prior to this migration). Findings used here:
--   * No persisted weekly/monthly/yearly energy aggregate exists anywhere
--     in this codebase (exhaustive grep of all prior migrations for such
--     an object name, combined with "energy", returned zero matches).
--   * analytics.energy_consumption_daily has NO retention policy (migration
--     183) and its `consumption_date` column is already the site-LOCAL
--     calendar date (derived via `bucket_start AT TIME ZONE site.timezone`,
--     migration 183's own refresh function) -- grouping it with
--     date_trunc('week'/'month'/'year', consumption_date) is therefore
--     already site-timezone-correct with NO further timezone handling
--     needed, in SQL or in the frontend.
--   * date_trunc('week', date) truncates to the ISO Monday of that date's
--     week -- the exact Monday-anchored convention this product's own
--     (now superseded) client-side weekly bucketing already used, so this
--     migration does not change what "a week" means to the customer.
--
-- What this migration does (ADDITIVE ONLY):
--   One new function in schema analytics:
--
--   analytics.get_portal_site_energy_consumption_periodic(bigint, uuid,
--     timestamptz, timestamptz, text) RETURNS TABLE(bucket_start,
--     import_consumption_kwh, export_consumption_kwh, source_interval_count)
--     -- the EXACT same row shape analytics.get_portal_site_energy_
--     consumption (migration 231) already returns, so the existing Python
--     build_energy_consumption_response mapping is reused completely
--     unchanged.
--
--     * p_period is 'week' | 'month' | 'year' (validated; anything else
--       raises, matching migration 231's own p_resolution validation
--       style).
--     * Reads ONLY analytics.energy_consumption_daily (no new table). One
--       row per requested period, summed from whichever days in
--       [p_from, p_to) actually exist -- a partial first/last period is
--       therefore summed correctly and honestly from only the days
--       present, with no special-casing required.
--     * bucket_start is MIN(d.bucket_start) within the group -- the first
--       real per-day site-local-midnight instant already stored on those
--       rows -- so the returned bucket boundary is a real, already-correct
--       instant, never recomputed or guessed from the bare DATE.
--     * SECURITY DEFINER, STABLE, pinned SET search_path, REVOKE ALL FROM
--       PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin, tenant scope via
--       admin.portal_user_can_access_site(bigint, uuid) -- zero rows for an
--       inaccessible site, matching every other function in this family.
--     * No Grafana concept referenced or exposed.
--
-- What this migration does NOT do:
--   * Does NOT create a new table, hypertable, materialized view, job, or
--     trigger. No persisted weekly/monthly/yearly aggregate is introduced.
--   * Does NOT modify analytics.energy_consumption_daily,
--     analytics.energy_consumption_hourly, or analytics.get_portal_site_
--     energy_consumption (migration 231) -- the existing Hourly/Daily read
--     path is completely unchanged; this is a new, additive sibling read.
--   * Does NOT change ENERGY_RESOLUTION_MAX_WINDOW's existing "1h"/"1d"
--     entries (app/src/analytics_api_service.py) -- those stay exactly as
--     they are. The new "1w"/"1mo"/"1y" tiers get their own, separate,
--     generous window cap (an engineering safety backstop only -- the
--     product's actual selectable-range decision is the separate
--     GET .../energy/consumption/availability endpoint, migration 247,
--     never this cap).
--
-- Rollback: DROP FUNCTION analytics.get_portal_site_energy_consumption_periodic
-- (bigint, uuid, timestamptz, timestamptz, text); safe, no existing object
-- altered by this migration.
--
-- New app tests: app/tests/test_analytics_api_v1_energy_consumption_periodic_routes.py.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 248 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;

    IF to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 248 precondition failed: analytics.energy_consumption_daily is missing (migration 183).';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_energy_consumption_periodic(bigint, uuid, timestamptz, timestamptz, text)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_energy_consumption_periodic
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_period         TEXT
)
RETURNS TABLE
(
    bucket_start            TIMESTAMPTZ,
    import_consumption_kwh  NUMERIC,
    export_consumption_kwh  NUMERIC,
    source_interval_count   BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    IF p_period IS NULL OR p_period NOT IN ('week', 'month', 'year') THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption_periodic: unsupported period %', p_period
            USING ERRCODE = '22023';
    END IF;

    IF p_from IS NULL OR p_to IS NULL OR p_from >= p_to THEN
        RAISE EXCEPTION 'analytics.get_portal_site_energy_consumption_periodic: invalid time range (from must be < to)'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT
        MIN(d.bucket_start),
        SUM(d.import_consumption_kwh),
        SUM(d.export_consumption_kwh),
        SUM(d.source_interval_count)::BIGINT
    FROM analytics.energy_consumption_daily AS d
    WHERE d.site_id = p_site_id
      AND d.bucket_start >= p_from
      AND d.bucket_start <  p_to
    GROUP BY date_trunc(p_period, d.consumption_date)
    ORDER BY MIN(d.bucket_start);
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_energy_consumption_periodic(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_energy_consumption_periodic(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_energy_consumption_periodic(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_site_energy_consumption_periodic(BIGINT, UUID, TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS
'Portal-user-scoped site-level Weekly/Monthly/Yearly energy consumption, aggregated server-side from analytics.energy_consumption_daily via date_trunc(p_period, consumption_date) -- consumption_date is already the site-local calendar date, so no additional timezone handling is required. One row per period actually covered by data in [p_from, p_to); a partial first/last period sums only the days present. Tenant scope re-derived from p_portal_user_id via admin.portal_user_can_access_site; unknown site or no access -> zero rows.';


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_site_energy_consumption_periodic(bigint, uuid, timestamptz, timestamptz, text)';
    v_body TEXT;
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: % was not created.', v_sig;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND p.provolatile = 's'
          AND r.rolname = 'ems_admin'
    ) THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: the periodic-aggregation function contains a write statement or dynamic SQL.';
    END IF;

    IF position('energy_consumption_daily' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: the periodic-aggregation function does not reference energy_consumption_daily.';
    END IF;

    IF position('grafana' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 248 postcondition failed: the periodic-aggregation function must not reference any Grafana concept.';
    END IF;

    RAISE NOTICE 'Migration 248: all postconditions passed (portal-scoped site energy Weekly/Monthly/Yearly aggregation function created; read-only; sources analytics.energy_consumption_daily only).';
END;
$post$;
