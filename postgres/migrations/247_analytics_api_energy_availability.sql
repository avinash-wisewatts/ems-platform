-- ============================================================================
-- Migration 247
-- WiseWatts dashboard redesign -- Main Dashboard Energy Usage chart. Adds a
-- portal-user-scoped read of the SITE's ACTUAL persisted energy-consumption
-- data availability (earliest/latest), for the new
-- GET /sites/{site_id}/energy/consumption/availability endpoint.
--
-- Why this is needed (verified this session, direct DB read against the
-- local dev database -- not assumed): the existing /energy/consumption
-- caps (time/ranges.ts#ENERGY_MAX_WINDOW_S / this app's
-- ENERGY_RESOLUTION_MAX_WINDOW) are QUERY-WINDOW limits (how large a single
-- request may span), not data-retention or data-availability facts.
-- analytics.energy_consumption_hourly (migration 181) carries its own
-- 5-YEAR retention policy, and analytics.energy_consumption_daily
-- (migration 183) has explicitly NO retention policy at all -- neither
-- fact is discoverable from the API's query-window caps, which is exactly
-- why a UI date-range picker must not be bounded by them. There is no
-- existing customer-facing read of "what is the actual earliest/latest
-- energy data for this site" anywhere in the /api/v1 API prior to this
-- migration (grep of app/src/routers/analytics_api.py and
-- app/src/analytics_api_service.py, this session).
--
-- Source of record: this session's Main Dashboard Energy Usage chart
-- revision. Sibling precedent: migration 237
-- (get_portal_site_telemetry_freshness) for the "always exactly one row
-- once authorized, nullable fields for the not-yet-known case" shape, and
-- migration 244 (get_portal_asset_energy_intervals) for the additive
-- read-only wrapper pattern.
--
-- What this migration does (ADDITIVE ONLY):
--   One new function in schema analytics:
--
--   analytics.get_portal_site_energy_availability(bigint, uuid)
--     RETURNS TABLE(site_id, earliest, latest)
--
--     * Reads MIN/MAX(bucket_start) across BOTH
--       analytics.energy_consumption_daily AND
--       analytics.energy_consumption_hourly for the site -- the union of
--       the two tables the existing GET /energy/consumption endpoint
--       already reads (resolution=1d / resolution=1h respectively) --
--       because a value in EITHER table is genuinely persisted, queryable
--       energy data. Daily has no retention policy, so it alone already
--       determines the true earliest date in every case observed this
--       session; hourly is included because it can be more current than a
--       not-yet-finalized daily bucket for "today" and because relying on
--       daily alone would be an unverified assumption about which table
--       updates first. LEAST()/GREATEST() are used deliberately: per
--       PostgreSQL semantics (unlike a bare MIN/MAX(a,b) inline comparison)
--       they ignore a NULL operand and only return NULL when every operand
--       is NULL -- exactly "no data in this table for this site" without
--       needing separate CASE logic.
--     * SECURITY DEFINER, STABLE, pinned SET search_path,
--     * REVOKE ALL FROM PUBLIC, GRANT EXECUTE TO ems_app, OWNER ems_admin,
--     * tenant scope via admin.portal_user_can_access_site(bigint, uuid) --
--       a caller who cannot access the site gets ZERO rows, matching every
--       other function in this family. A site the caller CAN access but
--       that has no energy data at all (verified this session: true for
--       every site in the local dev database) gets exactly one row with
--       earliest = latest = NULL, never zero rows and never a fabricated
--       date -- the router/service layer maps that to has_data = false.
--
-- What this migration does NOT do:
--   * Does NOT modify analytics.energy_consumption_daily,
--     analytics.energy_consumption_hourly, or any existing energy read
--     function -- read-only, additive.
--   * Does NOT introduce a new table, hypertable, job, or trigger.
--   * Does NOT change ENERGY_RESOLUTION_MAX_WINDOW or any existing
--     query-window cap -- those remain separate, still-enforced
--     per-request limits, independent of this availability read.
--   * Does NOT infer availability from telemetry.device_telemetry_state
--     (migration 237's freshness source) -- that reflects raw telemetry
--     receipt, not the persisted, queryable energy-consumption historians
--     this chart actually reads from.
--
-- Rollback: DROP FUNCTION analytics.get_portal_site_energy_availability
-- (bigint, uuid); safe, no existing object is altered by this migration.
--
-- New app tests: app/tests/test_analytics_api_v1_energy_availability_routes.py.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 247 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;

    IF to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 247 precondition failed: analytics.energy_consumption_daily is missing (migration 183).';
    END IF;

    IF to_regclass('analytics.energy_consumption_hourly') IS NULL THEN
        RAISE EXCEPTION 'Migration 247 precondition failed: analytics.energy_consumption_hourly is missing (migration 181).';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. analytics.get_portal_site_energy_availability(bigint, uuid)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_portal_site_energy_availability
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    site_id  UUID,
    earliest TIMESTAMPTZ,
    latest   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH daily_range AS (
        SELECT MIN(d.bucket_start) AS earliest, MAX(d.bucket_start) AS latest
        FROM analytics.energy_consumption_daily AS d
        WHERE d.site_id = p_site_id
    ),
    hourly_range AS (
        SELECT MIN(h.bucket_start) AS earliest, MAX(h.bucket_start) AS latest
        FROM analytics.energy_consumption_hourly AS h
        WHERE h.site_id = p_site_id
    )
    SELECT
        p_site_id,
        LEAST(dr.earliest, hr.earliest),
        GREATEST(dr.latest, hr.latest)
    FROM daily_range AS dr, hourly_range AS hr;
END;
$function$;

ALTER FUNCTION analytics.get_portal_site_energy_availability(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_site_energy_availability(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_site_energy_availability(BIGINT, UUID) TO ems_app;


-- ----------------------------------------------------------------------------
-- Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_site_energy_availability(bigint, uuid)';
    v_body TEXT;
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: % was not created.', v_sig;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND p.provolatile = 's'
          AND r.rolname = 'ems_admin'
    ) THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin.', v_sig;
    END IF;

    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    IF NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: % is not executable by ems_app.', v_sig;
    END IF;

    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position(' merge ' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: the availability function contains a write statement or dynamic SQL.';
    END IF;

    IF position('energy_consumption_daily' IN v_body) = 0
       OR position('energy_consumption_hourly' IN v_body) = 0 THEN
        RAISE EXCEPTION 'Migration 247 postcondition failed: the availability function must read both energy_consumption_daily and energy_consumption_hourly.';
    END IF;

    RAISE NOTICE 'Migration 247: all postconditions passed (portal-scoped site energy availability read function created; read-only).';
END;
$post$;
