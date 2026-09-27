-- ============================================================================
-- Migration 277
-- Analytics v1 data availability for Energy data points (ADR-022, step B1b).
--
-- analytics.get_portal_analytics_energy_availability(p_portal_user_id,
-- p_site_id) returns, per ACTIVE asset of the site and Energy direction
-- (ENERGY_IMPORT / ENERGY_EXPORT), the earliest and latest instant for which
-- the asset has attributed Energy consumption. The Analytics page bounds its
-- date picker with it (EMS-REQ-133), per data point rather than per site
-- (migration 247 is the site-level equivalent the Main Dashboard uses).
--
-- Attribution: every metadata.asset_points binding of the direction's
-- *_TOTAL logical point -- current or ended -- through
-- analytics.resolve_asset_energy_source_windows (migration 263), exactly as
-- the canonical Energy read attributes history. A binding contributes only
-- its own [window_from, window_to) slice of its device's data, so a moved
-- source never lends the asset history from outside its binding (ADR-018
-- decisions 7/8).
--
-- Bounds, per binding window, then combined across windows:
--   available_from = GREATEST(window_from, earliest analytics.energy_consumption_daily
--                    day start with a non-NULL value for the direction)
--                    -- the daily tier has no retention policy, so it holds
--                    -- the longest history;
--   available_to   = LEAST(window_to, latest analytics.energy_consumption_15min
--                    bucket end with a non-NULL value), falling back to the
--                    latest daily day end when the 15-minute tier holds no row.
-- Both probes use the (device_id, bucket_start) indexes and the device
-- compression segmentby of those tables.
--
-- The assets listed are exactly those that can appear in the Analytics
-- catalogue: ACTIVE assets of the site with a currently effective binding
-- of the direction. Tenant scope: admin.portal_user_can_access_site. Parity-
-- bridge bindings (effective_from = '-infinity') are used as any other
-- binding and are never modified. Read-only.
--
-- Rollback: DROP FUNCTION analytics.get_portal_analytics_energy_availability(bigint, uuid);
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 277 precondition failed: admin.portal_user_can_access_site(bigint, uuid) is missing.';
    END IF;
    IF to_regprocedure('analytics.resolve_asset_energy_source_windows(uuid, text, timestamptz, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 277 precondition failed: analytics.resolve_asset_energy_source_windows is missing (migration 263).';
    END IF;
    IF to_regclass('analytics.energy_consumption_daily') IS NULL
       OR to_regclass('analytics.energy_consumption_15min') IS NULL THEN
        RAISE EXCEPTION 'Migration 277 precondition failed: analytics.energy_consumption_daily / _15min is missing.';
    END IF;
END;
$pre$;

CREATE OR REPLACE FUNCTION analytics.get_portal_analytics_energy_availability
(
    p_portal_user_id BIGINT,
    p_site_id        UUID
)
RETURNS TABLE
(
    asset_id       UUID,
    data_point     TEXT,
    available_from TIMESTAMPTZ,
    available_to   TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata
AS $function$
BEGIN
    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH directions (data_point, logical_point) AS (
        VALUES ('ENERGY_IMPORT', 'ENERGY_IMPORT_TOTAL'),
               ('ENERGY_EXPORT', 'ENERGY_EXPORT_TOTAL')
    ),
    eligible AS (
        SELECT DISTINCT a.id AS asset_id, dir.data_point, dir.logical_point
        FROM metadata.assets AS a
        JOIN metadata.asset_points AS ap
          ON ap.asset_id = a.id
         AND ap.organization_id = a.organization_id
         AND ap.effective_range @> now()
        JOIN metadata.logical_points AS lp
          ON lp.id = ap.logical_point_id
        JOIN directions AS dir
          ON dir.logical_point = lp.name
        WHERE a.site_id = p_site_id
          AND a.lifecycle_status = 'ACTIVE'
    ),
    windows AS (
        SELECT e.asset_id, e.data_point, w.device_id, w.window_from, w.window_to
        FROM eligible AS e
        CROSS JOIN LATERAL analytics.resolve_asset_energy_source_windows(
            e.asset_id, e.logical_point, '-infinity'::timestamptz, 'infinity'::timestamptz
        ) AS w
    ),
    bounds AS (
        SELECT
            w.asset_id,
            w.data_point,
            GREATEST(w.window_from, first_day.day_start) AS window_available_from,
            LEAST(w.window_to, COALESCE(last_15m.bucket_end, last_day.day_end)) AS window_available_to
        FROM windows AS w
        LEFT JOIN LATERAL (
            SELECT d.bucket_start AS day_start
            FROM analytics.energy_consumption_daily AS d
            WHERE d.device_id = w.device_id
              AND d.bucket_start < w.window_to
              AND (d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN d.import_consumption_kwh IS NOT NULL
                       ELSE d.export_consumption_kwh IS NOT NULL END
            ORDER BY d.bucket_start
            LIMIT 1
        ) AS first_day ON TRUE
        LEFT JOIN LATERAL (
            SELECT (d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone AS day_end
            FROM analytics.energy_consumption_daily AS d
            WHERE d.device_id = w.device_id
              AND d.bucket_start < w.window_to
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN d.import_consumption_kwh IS NOT NULL
                       ELSE d.export_consumption_kwh IS NOT NULL END
            ORDER BY d.bucket_start DESC
            LIMIT 1
        ) AS last_day ON TRUE
        LEFT JOIN LATERAL (
            SELECT q.bucket_start + INTERVAL '15 minutes' AS bucket_end
            FROM analytics.energy_consumption_15min AS q
            WHERE q.device_id = w.device_id
              AND q.bucket_start < w.window_to
              AND q.bucket_start + INTERVAL '15 minutes' > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN q.import_consumption_kwh IS NOT NULL
                       ELSE q.export_consumption_kwh IS NOT NULL END
            ORDER BY q.bucket_start DESC
            LIMIT 1
        ) AS last_15m ON TRUE
        WHERE first_day.day_start IS NOT NULL
    )
    SELECT
        e.asset_id,
        e.data_point,
        MIN(b.window_available_from),
        MAX(b.window_available_to)
    FROM eligible AS e
    LEFT JOIN bounds AS b
      ON b.asset_id = e.asset_id
     AND b.data_point = e.data_point
     AND b.window_available_to > b.window_available_from
    GROUP BY e.asset_id, e.data_point;
END;
$function$;

ALTER FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) IS
'Analytics v1 Energy availability (migration 277, ADR-022 B1b): per ACTIVE asset of the site and Energy direction with a currently effective binding, the earliest/latest instant of attributed Energy consumption across all of the direction''s asset_points windows (daily tier for the start, 15-minute tier for the end). NULL bounds = no data yet. Portal-scoped; read-only.';

DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_analytics_energy_availability(bigint, uuid)';
    v_body TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND p.provolatile = 's'
          AND r.rolname = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 277 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 277 postcondition failed: % must be executable by ems_app and not by PUBLIC.', v_sig;
    END IF;
    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 277 postcondition failed: the availability function contains a write statement or dynamic SQL.';
    END IF;
    IF position('primary_meter' IN v_body) > 0 OR position('asset_devices' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 277 postcondition failed: availability must be attributed through asset_points only.';
    END IF;
    RAISE NOTICE 'Migration 277: all postconditions passed (portal-scoped Analytics Energy availability read function created; read-only).';
END;
$post$;
