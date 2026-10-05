-- ============================================================================
-- Migration 286
-- Analytics read latency: compute the per-window availability bounds once.
--
-- analytics.get_portal_analytics_energy_availability (migration 277, re-based
-- on the persisted tiers by migration 280) is read on every Analytics page
-- load (GET /api/v1/sites/{site_id}/analytics/catalog). Its final
-- `eligible LEFT JOIN bounds` is planned as a nested loop with a join filter,
-- so PostgreSQL inlines the `bounds` CTE and re-runs it -- every binding
-- window's resolve_asset_energy_source_windows call and its four probes of
-- the daily, 15-minute and 1-minute Energy tiers -- once per eligible
-- (asset, direction) row: eligible x eligible probe rounds, discarding all
-- but the matching rows. Measured on staging on 2026-09-30 against the
-- deployed migration-280 function (EXPLAIN ANALYZE and auto_explain): all
-- four probes and resolve_asset_energy_source_windows run 62 x 62 = 3,844
-- times for Coimbatore (31 assets; 3,782 rows removed by the join filter)
-- and 44 x 44 = 1,936 times for Unit 2 (22 assets); 1.3-2.3 s per call for
-- Coimbatore and 0.7-1.0 s for Unit 2 across two measurement sessions. With
-- `bounds` materialized: 62 and 44 probe rounds, about 40-55 ms and
-- 19-27 ms, with row-for-row identical results for both sites.
--
-- Change: `bounds AS MATERIALIZED (`. Nothing else: the body is migration
-- 280's byte for byte apart from that keyword, and the signature, result
-- columns, LANGUAGE, SECURITY DEFINER, STABLE, pinned search_path, owner,
-- grants (ems_app only) and comment are unchanged (CREATE OR REPLACE keeps
-- the owner, grants and comment; the postconditions check them). A
-- materialized CTE is computed once per call and then joined; the join
-- condition and aggregation are unchanged, so the result rows are the same.
--
-- Precondition: the deployed definition and comment are migration 280's
-- (md5).
-- Postcondition: reverting the keyword reproduces migration 280's definition
-- exactly (md5); owner, SECURITY DEFINER, STABLE, search_path, grants and
-- comment (md5) are unchanged.
--
-- Rollback: re-apply migration 280's CREATE OR REPLACE FUNCTION
-- analytics.get_portal_analytics_energy_availability (without MATERIALIZED).
-- ============================================================================

DO $pre$
DECLARE
    v_sig TEXT := 'analytics.get_portal_analytics_energy_availability(bigint, uuid)';
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 286 precondition failed: % is missing.', v_sig;
    END IF;
    IF md5(pg_get_functiondef(v_sig::regprocedure)) <> 'b3e0ac271601d0a2f96560742d05dbc4' THEN
        RAISE EXCEPTION 'Migration 286 precondition failed: % differs from the migration 280 definition.', v_sig;
    END IF;
    IF md5(obj_description(v_sig::regprocedure, 'pg_proc')) IS DISTINCT FROM 'bb352ba5380264118a27d102d7a1a70b' THEN
        RAISE EXCEPTION 'Migration 286 precondition failed: the comment on % differs from migration 280.', v_sig;
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
        SELECT DISTINCT a.id AS asset_id, a.organization_id, dir.data_point, dir.logical_point
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
        SELECT e.asset_id, e.organization_id, e.data_point, w.device_id, w.window_from, w.window_to
        FROM eligible AS e
        CROSS JOIN LATERAL analytics.resolve_asset_energy_source_windows(
            e.asset_id, e.logical_point, '-infinity'::timestamptz, 'infinity'::timestamptz
        ) AS w
    ),
    bounds AS MATERIALIZED (
        SELECT
            w.asset_id,
            w.data_point,
            GREATEST(w.window_from, first_day.day_start) AS window_available_from,
            LEAST(
                w.window_to,
                COALESCE(GREATEST(last_15m.bucket_end, last_raw.bucket_end), last_day.day_end)
            ) AS window_available_to
        FROM windows AS w
        LEFT JOIN LATERAL (
            SELECT d.bucket_start AS day_start
            FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = w.organization_id
              AND d.device_id = w.device_id
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
            WHERE d.organization_id = w.organization_id
              AND d.device_id = w.device_id
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
            WHERE q.organization_id = w.organization_id
              AND q.device_id = w.device_id
              AND q.bucket_start < w.window_to
              AND q.bucket_start + INTERVAL '15 minutes' > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN q.import_consumption_kwh IS NOT NULL
                       ELSE q.export_consumption_kwh IS NOT NULL END
            ORDER BY q.bucket_start DESC
            LIMIT 1
        ) AS last_15m ON TRUE
        LEFT JOIN LATERAL (
            SELECT m.bucket_start + INTERVAL '1 minute' AS bucket_end
            FROM analytics.energy_consumption_1min AS m
            WHERE m.organization_id = w.organization_id
              AND m.device_id = w.device_id
              AND m.bucket_start < w.window_to
              AND m.bucket_start + INTERVAL '1 minute' > w.window_from
              AND CASE WHEN w.data_point = 'ENERGY_IMPORT'
                       THEN m.import_consumption_kwh IS NOT NULL
                       ELSE m.export_consumption_kwh IS NOT NULL END
            ORDER BY m.bucket_start DESC
            LIMIT 1
        ) AS last_raw ON TRUE
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

DO $post$
DECLARE
    v_sig     TEXT := 'analytics.get_portal_analytics_energy_availability(bigint, uuid)';
    v_def     TEXT;
BEGIN
    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF position('bounds AS MATERIALIZED (' IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 286 postcondition failed: % does not materialize bounds.', v_sig;
    END IF;
    IF md5(replace(v_def, 'bounds AS MATERIALIZED (', 'bounds AS (')) <> 'b3e0ac271601d0a2f96560742d05dbc4' THEN
        RAISE EXCEPTION 'Migration 286 postcondition failed: % changed beyond the MATERIALIZED keyword.', v_sig;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef
          AND p.provolatile = 's'
          AND r.rolname = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 286 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR has_function_privilege('grafana_reader', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 286 postcondition failed: % must be executable by ems_app only.', v_sig;
    END IF;
    IF md5(obj_description(v_sig::regprocedure, 'pg_proc')) IS DISTINCT FROM 'bb352ba5380264118a27d102d7a1a70b' THEN
        RAISE EXCEPTION 'Migration 286 postcondition failed: the comment on % changed.', v_sig;
    END IF;
    RAISE NOTICE 'Migration 286: all postconditions passed (availability bounds materialized; definition otherwise identical to migration 280; owner, grants and comment unchanged).';
END;
$post$;
