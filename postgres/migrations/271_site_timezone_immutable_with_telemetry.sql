-- ============================================================================
-- Migration 271
-- ADR-019 D2: a site's timezone cannot be changed once the site has
-- telemetry. Analytics v1 step B0 (ADR-022).
--
-- Why now: ADR-019 D2 ("Block site timezone edits once a site has
-- telemetry. Effective-dated timezone history is a separate, future
-- product/data-model decision") was decided 2026-09-24 but never
-- implemented. Read-only staging verification (2026-09-27): the deployed
-- admin.update_site_workspace() validates only that the value is a real
-- IANA zone and then writes it unconditionally. Site-local calendar days
-- are already persisted with the zone in force when they were computed
-- (analytics.energy_consumption_daily.consumption_date and its
-- site_timezone column), and Analytics v1 adds a persisted site-local-day
-- tier (analytics.point_telemetry_1d, ADR-019 D1). A later zone change
-- would silently mislabel every one of those days.
--
-- Mechanism: a BEFORE UPDATE OF timezone row trigger on metadata.sites,
-- mirroring the existing sites_prevent_organization_change guard, so the
-- rule holds for every write path (admin.update_site_workspace() is the
-- only one today -- verified on staging: the only functions that UPDATE
-- metadata.sites are update_site_workspace, set_site_sub_sector and
-- transition_entity_lifecycle, and only the first writes timezone).
--
-- "Has telemetry" -- any one of:
--   * a telemetry.normalized_points row for this site from a device
--     currently attached to the site (raw history, 90-day retention);
--   * an analytics.point_telemetry_1h row for this site from such a device
--     (1-year retention);
--   * an analytics.energy_consumption_daily row for this site (no
--     retention policy) -- this also covers devices that have since moved
--     away from the site, because the row is keyed by site.
-- The device-scoped probes match the tables' compression segmentby
-- (normalized_points: organization_id, device_id, ...; point_telemetry_1h:
-- device_id, ...), and energy_consumption_daily's (organization_id,
-- site_id) index/segmentby, so each probe is an indexed EXISTS that stops
-- at the first row.
--
-- The trigger fires only when the value actually changes, so saving a
-- site form without touching the timezone is unaffected. Creating a site
-- is unaffected (INSERT). There is no override: effective-dated timezone
-- history is explicitly a separate future decision (D2).
--
-- Error: SQLSTATE 23514 (check_violation), the code the sibling
-- organization-change guard already uses. The Admin Portal maps the
-- message to a user-facing sentence in app/src/onboarding/database_errors.py.
--
-- Not changed: admin.update_site_workspace() and every other function,
-- view, job and grant. No data is read or written by the migration itself
-- beyond catalog checks.
--
-- Rollback: DROP TRIGGER sites_prevent_timezone_change_with_telemetry ON
-- metadata.sites; DROP FUNCTION metadata.prevent_site_timezone_change_with_telemetry();
-- ============================================================================

DO $pre$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'sites' AND column_name = 'timezone'
    ) THEN
        RAISE EXCEPTION 'Migration 271 precondition failed: metadata.sites.timezone is missing.';
    END IF;
    IF to_regclass('telemetry.normalized_points') IS NULL THEN
        RAISE EXCEPTION 'Migration 271 precondition failed: telemetry.normalized_points is missing.';
    END IF;
    IF to_regclass('analytics.point_telemetry_1h') IS NULL THEN
        RAISE EXCEPTION 'Migration 271 precondition failed: analytics.point_telemetry_1h is missing (migration 265).';
    END IF;
    IF to_regclass('analytics.energy_consumption_daily') IS NULL THEN
        RAISE EXCEPTION 'Migration 271 precondition failed: analytics.energy_consumption_daily is missing (migration 183).';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'metadata.sites'::regclass
          AND tgname = 'sites_prevent_timezone_change_with_telemetry'
    ) THEN
        RAISE EXCEPTION 'Migration 271 precondition failed: trigger sites_prevent_timezone_change_with_telemetry already exists.';
    END IF;
END;
$pre$;

CREATE OR REPLACE FUNCTION metadata.prevent_site_timezone_change_with_telemetry()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, metadata, telemetry, analytics
AS $function$
BEGIN
    IF NEW.timezone IS NOT DISTINCT FROM OLD.timezone THEN
        RETURN NEW;
    END IF;

    IF EXISTS (
            SELECT 1
            FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = OLD.organization_id
              AND d.site_id = OLD.id
        )
        OR EXISTS (
            SELECT 1
            FROM metadata.devices AS dv
            JOIN metadata.gateways AS g
              ON g.id = dv.gateway_id
            WHERE g.site_id = OLD.id
              AND (
                  EXISTS (
                      SELECT 1
                      FROM telemetry.normalized_points AS np
                      WHERE np.organization_id = dv.organization_id
                        AND np.device_id = dv.id
                        AND np.site_id = OLD.id
                  )
                  OR EXISTS (
                      SELECT 1
                      FROM analytics.point_telemetry_1h AS h
                      WHERE h.device_id = dv.id
                        AND h.site_id = OLD.id
                  )
              )
        )
    THEN
        RAISE EXCEPTION
            'Site timezone cannot be changed once the site has telemetry.'
            USING ERRCODE = '23514',
                  DETAIL = format('Site %s has telemetry recorded in timezone %s.', OLD.id, OLD.timezone),
                  HINT = 'Effective-dated timezone history is not supported (ADR-019 D2).';
    END IF;

    RETURN NEW;
END;
$function$;

ALTER FUNCTION metadata.prevent_site_timezone_change_with_telemetry() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION metadata.prevent_site_timezone_change_with_telemetry() FROM PUBLIC;

COMMENT ON FUNCTION metadata.prevent_site_timezone_change_with_telemetry() IS
'ADR-019 D2 (migration 271): rejects a change to metadata.sites.timezone once the site has telemetry (normalized_points or point_telemetry_1h rows from its current devices, or any energy_consumption_daily row for the site). SQLSTATE 23514. No override: effective-dated timezone history is a separate future decision.';

CREATE TRIGGER sites_prevent_timezone_change_with_telemetry
BEFORE UPDATE OF timezone ON metadata.sites
FOR EACH ROW
WHEN (OLD.timezone IS DISTINCT FROM NEW.timezone)
EXECUTE FUNCTION metadata.prevent_site_timezone_change_with_telemetry();

DO $post$
DECLARE
    v_sig  TEXT := 'metadata.prevent_site_timezone_change_with_telemetry()';
    v_body TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'metadata.sites'::regclass
          AND tgname = 'sites_prevent_timezone_change_with_telemetry'
          AND tgfoid = v_sig::regprocedure
          AND tgenabled = 'O'
    ) THEN
        RAISE EXCEPTION 'Migration 271 postcondition failed: the timezone guard trigger is missing or disabled.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND r.rolname = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 271 postcondition failed: % is not SECURITY DEFINER / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 271 postcondition failed: % is executable by PUBLIC.', v_sig;
    END IF;
    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position('execute ' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 271 postcondition failed: the guard contains a write statement or dynamic SQL.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgrelid = 'metadata.sites'::regclass
          AND tgname = 'sites_prevent_organization_change'
    ) THEN
        RAISE EXCEPTION 'Migration 271 postcondition failed: the existing organization-change guard is missing.';
    END IF;
    RAISE NOTICE 'Migration 271: all postconditions passed (site timezone guard installed; ADR-019 D2).';
END;
$post$;
