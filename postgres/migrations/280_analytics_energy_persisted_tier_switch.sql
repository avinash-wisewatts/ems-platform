-- ============================================================================
-- Migration 280
-- Analytics Energy on the persisted tiers (ADR-022 Option B, step 5):
-- retire the canonical-read-era Analytics Energy series, align availability
-- with the persisted tiers, and expose per-resolution retention floors.
--
-- Precondition: migration 279 (analytics.get_portal_asset_energy_series) is
-- deployed and passed the staging parity gate PT-1..PT-11 on 2026-09-27
-- (zero parity mismatches; docs/platform-manual/25-change-history.md).
--
-- 1. DROP analytics.get_portal_analytics_energy_series (migration 278).
--    It read Energy through analytics.get_canonical_energy_read -- keyed on
--    the Grafana organization mapping and limited to raw retention -- and
--    carried the canonical-read-era 1d split (daily pipeline frontier vs
--    15-minute days). The Analytics API now calls migration 279's
--    analytics.get_portal_asset_energy_series directly; its output shape is
--    identical, so the HTTP contract is unchanged. Nothing else calls the
--    dropped function (postcondition).
--
-- 2. analytics.get_portal_analytics_energy_availability (migration 277),
--    same signature and columns, re-based on the tiers the Analytics read
--    uses:
--      available_from  earliest persisted daily day with a value for the
--                      direction (the daily tier has no retention), clipped to
--                      the binding window -- unchanged from 277;
--      available_to    the freshest data the read can serve: the later of the
--                      latest persisted 15-minute bucket end and the latest
--                      raw 1-minute bucket end (the read's fresh tail), clipped
--                      to the binding window; falls back to the latest daily
--                      day end.
--
-- 3. New analytics.get_analytics_energy_resolution_floors(): per Analytics
--    resolution, the earliest instant its Energy source still retains,
--    derived from the live TimescaleDB retention policies (now() minus
--    drop_after): 1m <- energy_consumption_1min; 15m and 30m <-
--    energy_consumption_15min; 1h <- energy_consumption_hourly; 1d <-
--    energy_consumption_daily (NULL = no retention policy = no floor). The
--    API reports RESOLUTION_UNAVAILABLE for a request starting before the
--    floor instead of returning silently empty buckets.
--
-- Not changed: analytics.get_canonical_energy_read, every Grafana function
-- and view, the Asset View Energy tile path, migration 279's function, and
-- metadata.asset_points (including staging parity-bridge rows). No data
-- written.
--
-- Rollback: re-apply migration 278's CREATE FUNCTION and 277's availability
-- body; DROP FUNCTION analytics.get_analytics_energy_resolution_floors().
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 280 precondition failed: analytics.get_portal_asset_energy_series is missing (migration 279).';
    END IF;
    IF to_regprocedure('analytics.get_portal_analytics_energy_availability(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 280 precondition failed: analytics.get_portal_analytics_energy_availability is missing (migration 277).';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prokind IN ('f', 'p')
          AND n.nspname IN ('analytics', 'admin', 'metadata', 'telemetry', 'config')
          AND p.proname <> 'get_portal_analytics_energy_series'
          AND pg_get_functiondef(p.oid) ILIKE '%get_portal_analytics_energy_series%'
    ) THEN
        RAISE EXCEPTION 'Migration 280 precondition failed: a database routine still calls analytics.get_portal_analytics_energy_series.';
    END IF;
END;
$pre$;

-- ----------------------------------------------------------------------------
-- 1. Retire the canonical-read-era Analytics Energy series (migration 278).
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS analytics.get_portal_analytics_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT);

-- ----------------------------------------------------------------------------
-- 2. Availability aligned with the persisted-tier read.
-- ----------------------------------------------------------------------------
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
    bounds AS (
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

ALTER FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_analytics_energy_availability(BIGINT, UUID) IS
'Analytics v1 Energy availability (migration 277, aligned with the persisted-tier read by migration 280): per ACTIVE asset of the site and Energy direction with a currently effective binding, the earliest persisted daily day and the latest persisted-15m or raw-1m bucket end across all of the direction''s asset_points windows. NULL bounds = no data yet. Portal-scoped; read-only.';

-- ----------------------------------------------------------------------------
-- 3. Per-resolution retention floors.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.get_analytics_energy_resolution_floors()
RETURNS TABLE
(
    resolution         TEXT,
    earliest_available TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics
AS $function$
    WITH sources (resolution, table_name) AS (
        VALUES ('1m', 'energy_consumption_1min'),
               ('15m', 'energy_consumption_15min'),
               ('30m', 'energy_consumption_15min'),
               ('1h', 'energy_consumption_hourly'),
               ('1d', 'energy_consumption_daily')
    )
    SELECT s.resolution,
           now() - (
               SELECT (j.config ->> 'drop_after')::INTERVAL
               FROM timescaledb_information.jobs AS j
               WHERE j.hypertable_schema = 'analytics'
                 AND j.hypertable_name = s.table_name
                 AND j.proc_name = 'policy_retention'
               LIMIT 1
           )
    FROM sources AS s;
$function$;

ALTER FUNCTION analytics.get_analytics_energy_resolution_floors() OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_analytics_energy_resolution_floors() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_analytics_energy_resolution_floors() TO ems_app;

COMMENT ON FUNCTION analytics.get_analytics_energy_resolution_floors() IS
'Analytics v1 (migration 280): per Analytics resolution, the earliest instant its Energy source tier still retains (now() minus the TimescaleDB retention policy''s drop_after); NULL = no retention policy. 1m raw 1min; 15m/30m persisted 15min; 1h persisted hourly; 1d persisted daily. Read-only.';

DO $post$
DECLARE
    v_avail  TEXT := 'analytics.get_portal_analytics_energy_availability(bigint, uuid)';
    v_floors TEXT := 'analytics.get_analytics_energy_resolution_floors()';
    v_sig    TEXT;
    v_body   TEXT;
BEGIN
    IF to_regprocedure('analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 280 postcondition failed: the canonical-read-era Analytics Energy series still exists.';
    END IF;
    FOREACH v_sig IN ARRAY ARRAY[v_avail, v_floors] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 280 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR has_function_privilege('grafana_reader', v_sig, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 280 postcondition failed: % must be executable by ems_app only.', v_sig;
        END IF;
        v_body := lower(pg_get_functiondef(v_sig::regprocedure));
        IF position('insert into' IN v_body) > 0
           OR position('update ' IN v_body) > 0
           OR position('delete from' IN v_body) > 0
           OR position('execute ' IN v_body) > 0
           OR position('grafana' IN v_body) > 0
           OR position('get_canonical_energy_read' IN v_body) > 0
           OR position('primary_meter' IN v_body) > 0 THEN
            RAISE EXCEPTION 'Migration 280 postcondition failed: % writes, uses dynamic SQL, or depends on the Grafana mapping / canonical read / PRIMARY_METER.', v_sig;
        END IF;
    END LOOP;
    IF (SELECT count(*) FROM analytics.get_analytics_energy_resolution_floors()) <> 5 THEN
        RAISE EXCEPTION 'Migration 280 postcondition failed: resolution floors must cover exactly 1m, 15m, 30m, 1h, 1d.';
    END IF;
    RAISE NOTICE 'Migration 280: all postconditions passed (canonical-read-era Analytics Energy series dropped; availability aligned with the persisted tiers; resolution floors added).';
END;
$post$;
