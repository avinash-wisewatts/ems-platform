-- ============================================================================
-- Migration 278
-- Analytics v1 Energy series (ADR-022, step B2): the portal-scoped read
-- behind the Energy selections of GET /api/v1/sites/{site_id}/analytics/series.
--
-- analytics.get_portal_analytics_energy_series(p_portal_user_id, p_site_id,
--     p_asset_ids, p_from, p_to, p_resolution)
-- returns, for every requested ACTIVE asset of the site, one row per bucket of
-- the Analytics bucket grid covering [p_from, p_to), with Import and Export
-- kWh, per-direction evidence status and measured-interval counts, the
-- expected interval count, and whether the bucket is still open.
--
-- Energy values come ONLY from analytics.get_canonical_energy_read (migrations
-- 263/269/270): asset_points attribution, ADR-020 measured/reconstructed
-- semantics and the canonical status vocabulary are reused, never re-derived.
-- This function adds the Analytics grid and the coarser Analytics buckets:
--
--   1m   canonical 'native' buckets (requires a 60 s capture interval)
--   15m  canonical '15m'
--   30m  canonical '15m' summed into UTC-grid 30-minute buckets
--   1h   canonical '15m' summed into UTC hours (ADR-019 D3, ADR-022 decision
--        9) -- deliberately NOT the canonical '1h' tier, which is site-local
--        hours (analytics.v_energy_reporting_hourly); existing Energy screens
--        keep that tier unchanged
--   1d   site-local calendar days [local midnight, next local midnight),
--        23/24/25 hours on DST days (ADR-022 decision 13). Days the daily
--        pipeline has finalized (day end <= telemetry.pipeline_state
--        'energy_consumption_daily'.last_received_at) come from canonical '1d';
--        later days -- including the open current day, whose persisted daily
--        row is only partially computed (verified on staging 2026-09-27) --
--        are canonical '15m' summed per local day. 15-minute buckets nest in
--        every IANA local day (ADR-019).
--
-- Grid (ADR-019 D4: overlapping buckets are returned whole, never clipped):
--   UTC grids from date_bin(width, p_from) up to the first boundary >= p_to;
--   1d from the local midnight at/before p_from to the local midnight at/after
--   p_to. Every grid bucket is returned; a bucket with no Energy row has NULL
--   values and zero measured intervals.
--
-- Aggregating 15-minute rows: kWh are summed per direction (NULL when every
-- constituent is NULL); the status is the most severe constituent status in
-- the canonical read's own precedence (INVALID_INTERVALS > RESET_DETECTED >
-- GAPS_DETECTED > RECONSTRUCTED_TIMING > ROLLOVER_DETECTED > GOOD); measured
-- intervals are summed. Energy is not mapped onto the GOOD/GAP/ESTIMATED/
-- INVALID/PARTIAL lattice (MVP-4 decision pack: Energy evidence is its own
-- mechanism).
--
-- Unavailable rows: when a whole asset series cannot be served, one row with
-- NULL bucket_start and unavailable_reason set is returned for that asset:
--   NO_TENANT_MAPPING       the organization has no active Grafana org mapping
--                           the canonical read is keyed on;
--   RESOLUTION_UNAVAILABLE  the requested resolution is finer than the site's
--                           capture interval (e.g. 1m on a 5-minute site);
--   CAPTURE_POLICY_CHANGE   the grid crosses a capture-interval change or a
--                           gap between capture policies (the canonical read
--                           rejects such ranges);
--   ENERGY_READ_FAILED      the canonical read raised for any other reason.
--
-- Scope: requested assets that are not ACTIVE assets of the site are silently
-- skipped; tenant access is admin.portal_user_can_access_site. Read-only;
-- asset_points (including the staging parity-bridge rows) is never written.
--
-- Rollback: DROP FUNCTION analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text);
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 278 precondition failed: analytics.get_canonical_energy_read is missing.';
    END IF;
    IF to_regprocedure('telemetry.resolve_site_capture_bucket(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 278 precondition failed: telemetry.resolve_site_capture_bucket is missing.';
    END IF;
    IF to_regprocedure('admin.portal_user_can_access_site(bigint, uuid)') IS NULL THEN
        RAISE EXCEPTION 'Migration 278 precondition failed: admin.portal_user_can_access_site is missing.';
    END IF;
    IF to_regclass('telemetry.pipeline_state') IS NULL THEN
        RAISE EXCEPTION 'Migration 278 precondition failed: telemetry.pipeline_state is missing.';
    END IF;
END;
$pre$;

CREATE OR REPLACE FUNCTION analytics.get_portal_analytics_energy_series
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_asset_ids      UUID[],
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT
)
RETURNS TABLE
(
    asset_id           UUID,
    bucket_start       TIMESTAMPTZ,
    bucket_end         TIMESTAMPTZ,
    import_kwh         NUMERIC,
    export_kwh         NUMERIC,
    import_status      TEXT,
    export_status      TEXT,
    import_intervals   BIGINT,
    export_intervals   BIGINT,
    expected_intervals BIGINT,
    is_partial         BOOLEAN,
    unavailable_reason TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry, config
AS $function$
DECLARE
    c_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    c_status CONSTANT TEXT[] := ARRAY['INVALID_INTERVALS', 'RESET_DETECTED', 'GAPS_DETECTED',
                                      'RECONSTRUCTED_TIMING', 'ROLLOVER_DETECTED', 'GOOD'];
    v_now          TIMESTAMPTZ := now();
    v_org          UUID;
    v_tz           TEXT;
    v_grafana_org  BIGINT;
    v_width        INTERVAL;
    v_source       TEXT;
    v_grid_from    TIMESTAMPTZ;
    v_grid_to      TIMESTAMPTZ;
    v_policy_from  TIMESTAMPTZ;
    v_capture      INTEGER;
    v_capture_n    INTEGER;
    v_policy_gap   BOOLEAN;
    v_split        TIMESTAMPTZ;
    v_reason       TEXT;
    v_asset        UUID;
BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('1m', '15m', '30m', '1h', '1d') THEN
        RAISE EXCEPTION 'p_resolution must be one of 1m, 15m, 30m, 1h, 1d; got %', p_resolution
            USING ERRCODE = '22023';
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RAISE EXCEPTION 'p_from and p_to are required and p_to must be later than p_from'
            USING ERRCODE = '22023';
    END IF;

    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    SELECT s.organization_id, s.timezone INTO v_org, v_tz
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;

    SELECT gom.grafana_org_id INTO v_grafana_org
    FROM metadata.grafana_organization_map AS gom
    WHERE gom.organization_id = v_org
      AND gom.is_active
    ORDER BY gom.grafana_org_id
    LIMIT 1;

    -- ------------------------------------------------------------------
    -- Grid.
    -- ------------------------------------------------------------------
    IF p_resolution = '1d' THEN
        v_grid_from := date_trunc('day', p_from AT TIME ZONE v_tz) AT TIME ZONE v_tz;
        v_grid_to   := date_trunc('day', p_to AT TIME ZONE v_tz) AT TIME ZONE v_tz;
        IF v_grid_to < p_to THEN
            v_grid_to := (date_trunc('day', p_to AT TIME ZONE v_tz) + INTERVAL '1 day') AT TIME ZONE v_tz;
        END IF;
        v_width  := INTERVAL '15 minutes';   -- source width for the capture check
        v_source := '1d';
    ELSE
        v_width := CASE p_resolution
                       WHEN '1m'  THEN INTERVAL '1 minute'
                       WHEN '15m' THEN INTERVAL '15 minutes'
                       WHEN '30m' THEN INTERVAL '30 minutes'
                       ELSE INTERVAL '1 hour'
                   END;
        v_grid_from := date_bin(v_width, p_from, c_origin);
        v_grid_to   := date_bin(v_width, p_to, c_origin);
        IF v_grid_to < p_to THEN
            v_grid_to := v_grid_to + v_width;
        END IF;
        v_source := CASE WHEN p_resolution = '1m' THEN 'native' ELSE '15m' END;
    END IF;

    -- ------------------------------------------------------------------
    -- Capture-policy consistency over the grid (the canonical read raises
    -- on a change or a gap; detect it up front so no partial series is
    -- ever emitted). Mirrors the canonical read's own boundary walk.
    -- ------------------------------------------------------------------
    SELECT MIN(p.effective_from) INTO v_policy_from
    FROM config.telemetry_capture_policies AS p
    WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL);

    IF v_policy_from IS NULL OR v_grid_to <= v_policy_from THEN
        v_reason := NULL;           -- nothing could have been captured: empty grid rows
        v_capture := NULL;
    ELSE
        SELECT COUNT(DISTINCT b.capture_interval_seconds),
               MIN(b.capture_interval_seconds),
               bool_or(b.policy_id IS NULL)
        INTO v_capture_n, v_capture, v_policy_gap
        FROM (
            SELECT GREATEST(v_grid_from, v_policy_from) AS t
            UNION
            SELECT p.effective_from FROM config.telemetry_capture_policies AS p
            WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL)
              AND p.effective_from > GREATEST(v_grid_from, v_policy_from) AND p.effective_from < v_grid_to
            UNION
            SELECT p.effective_to FROM config.telemetry_capture_policies AS p
            WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL)
              AND p.effective_to IS NOT NULL
              AND p.effective_to > GREATEST(v_grid_from, v_policy_from) AND p.effective_to < v_grid_to
        ) AS candidates
        CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket(p_site_id, candidates.t) AS b;

        IF v_policy_gap OR v_capture_n <> 1 THEN
            v_reason := 'CAPTURE_POLICY_CHANGE';
        ELSIF (p_resolution = '1m' AND v_capture <> 60)
           OR (p_resolution <> '1m' AND v_capture > 900) THEN
            v_reason := 'RESOLUTION_UNAVAILABLE';
        END IF;
    END IF;

    IF v_grafana_org IS NULL THEN
        v_reason := 'NO_TENANT_MAPPING';
    END IF;

    -- Daily finalization frontier -> the latest local midnight at/before it.
    IF p_resolution = '1d' THEN
        SELECT date_trunc('day', ps.last_received_at AT TIME ZONE v_tz) AT TIME ZONE v_tz
        INTO v_split
        FROM telemetry.pipeline_state AS ps
        WHERE ps.pipeline_name = 'energy_consumption_daily';
        v_split := LEAST(GREATEST(COALESCE(v_split, v_grid_from), v_grid_from), v_grid_to);
    END IF;

    FOR v_asset IN
        SELECT a.id
        FROM metadata.assets AS a
        WHERE a.id = ANY(p_asset_ids)
          AND a.site_id = p_site_id
          AND a.organization_id = v_org
          AND a.lifecycle_status = 'ACTIVE'
        ORDER BY a.id
    LOOP
        IF v_reason IS NOT NULL THEN
            RETURN QUERY SELECT v_asset, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::NUMERIC, NULL::NUMERIC,
                                NULL::TEXT, NULL::TEXT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BOOLEAN, v_reason;
            CONTINUE;
        END IF;

        BEGIN
            IF p_resolution = '1d' THEN
                RETURN QUERY
                WITH days AS (
                    SELECT (d::date::timestamp AT TIME ZONE v_tz) AS b_start,
                           ((d::date + 1)::timestamp AT TIME ZONE v_tz) AS b_end
                    FROM generate_series(
                        (v_grid_from AT TIME ZONE v_tz)::date,
                        (v_grid_to AT TIME ZONE v_tz)::date - 1,
                        INTERVAL '1 day'
                    ) AS d
                ),
                finalized_range AS (
                    SELECT v_grid_from AS f, v_split AS t WHERE v_split > v_grid_from
                ),
                open_range AS (
                    SELECT v_split AS f, v_grid_to AS t WHERE v_grid_to > v_split
                ),
                src AS (
                    SELECT c.interval_start AS b_start,
                           c.import_consumption_kwh AS imp, c.export_consumption_kwh AS exp,
                           array_position(c_status, c.import_quality_status) AS imp_rank,
                           array_position(c_status, c.export_quality_status) AS exp_rank,
                           COALESCE(c.valid_import_intervals, 0) + COALESCE(c.invalid_import_intervals, 0) AS imp_n,
                           COALESCE(c.valid_export_intervals, 0) + COALESCE(c.invalid_export_intervals, 0) AS exp_n
                    FROM finalized_range AS r
                    CROSS JOIN LATERAL analytics.get_canonical_energy_read(
                        v_grafana_org, v_asset, r.f, r.t, '1d', 'strict') AS c
                    WHERE c.interval_start IS NOT NULL
                    UNION ALL
                    SELECT (c.interval_start AT TIME ZONE v_tz)::date::timestamp AT TIME ZONE v_tz,
                           c.import_consumption_kwh, c.export_consumption_kwh,
                           array_position(c_status, c.import_quality_status),
                           array_position(c_status, c.export_quality_status),
                           COALESCE(c.valid_import_intervals, 0) + COALESCE(c.invalid_import_intervals, 0),
                           COALESCE(c.valid_export_intervals, 0) + COALESCE(c.invalid_export_intervals, 0)
                    FROM open_range AS r
                    CROSS JOIN LATERAL analytics.get_canonical_energy_read(
                        v_grafana_org, v_asset, r.f, r.t, '15m', 'strict') AS c
                    WHERE c.interval_start IS NOT NULL
                ),
                agg AS (
                    SELECT s.b_start, SUM(s.imp) AS imp, SUM(s.exp) AS exp,
                           c_status[MIN(s.imp_rank)] AS imp_status, c_status[MIN(s.exp_rank)] AS exp_status,
                           SUM(s.imp_n)::BIGINT AS imp_n, SUM(s.exp_n)::BIGINT AS exp_n
                    FROM src AS s
                    GROUP BY s.b_start
                )
                SELECT v_asset, g.b_start, g.b_end, a.imp, a.exp, a.imp_status, a.exp_status,
                       COALESCE(a.imp_n, 0), COALESCE(a.exp_n, 0),
                       (EXTRACT(EPOCH FROM (g.b_end - g.b_start)) / v_capture)::BIGINT,
                       g.b_end > v_now, NULL::TEXT
                FROM days AS g
                LEFT JOIN agg AS a ON a.b_start = g.b_start
                ORDER BY g.b_start;
            ELSE
                RETURN QUERY
                WITH grid AS (
                    SELECT gs AS b_start, gs + v_width AS b_end
                    FROM generate_series(v_grid_from, v_grid_to - v_width, v_width) AS gs
                ),
                src AS (
                    SELECT date_bin(v_width, c.interval_start, c_origin) AS b_start,
                           c.import_consumption_kwh AS imp, c.export_consumption_kwh AS exp,
                           array_position(c_status, c.import_quality_status) AS imp_rank,
                           array_position(c_status, c.export_quality_status) AS exp_rank,
                           COALESCE(c.valid_import_intervals, 0) + COALESCE(c.invalid_import_intervals, 0) AS imp_n,
                           COALESCE(c.valid_export_intervals, 0) + COALESCE(c.invalid_export_intervals, 0) AS exp_n
                    FROM analytics.get_canonical_energy_read(
                        v_grafana_org, v_asset, v_grid_from, v_grid_to, v_source, 'strict') AS c
                    WHERE c.interval_start IS NOT NULL
                ),
                agg AS (
                    SELECT s.b_start, SUM(s.imp) AS imp, SUM(s.exp) AS exp,
                           c_status[MIN(s.imp_rank)] AS imp_status, c_status[MIN(s.exp_rank)] AS exp_status,
                           SUM(s.imp_n)::BIGINT AS imp_n, SUM(s.exp_n)::BIGINT AS exp_n
                    FROM src AS s
                    GROUP BY s.b_start
                )
                SELECT v_asset, g.b_start, g.b_end, a.imp, a.exp, a.imp_status, a.exp_status,
                       COALESCE(a.imp_n, 0), COALESCE(a.exp_n, 0),
                       (EXTRACT(EPOCH FROM v_width) / v_capture)::BIGINT,
                       g.b_end > v_now, NULL::TEXT
                FROM grid AS g
                LEFT JOIN agg AS a ON a.b_start = g.b_start
                ORDER BY g.b_start;
            END IF;
        EXCEPTION WHEN raise_exception THEN
            -- Defensive: the capture-policy walk above prevents the known
            -- canonical-read exceptions. Any other RAISE is reported per
            -- asset rather than failing the whole request.
            RETURN QUERY SELECT v_asset, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::NUMERIC, NULL::NUMERIC,
                                NULL::TEXT, NULL::TEXT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BOOLEAN, 'ENERGY_READ_FAILED'::TEXT;
        END;
    END LOOP;
END;
$function$;

ALTER FUNCTION analytics.get_portal_analytics_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_analytics_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_analytics_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_analytics_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT) IS
'Analytics v1 Energy series (migration 278, ADR-022 B2): gap-filled Analytics bucket grid per requested ACTIVE asset of the site with Import/Export kWh, per-direction canonical evidence status and measured intervals, expected intervals and open-bucket flag. Values only from analytics.get_canonical_energy_read; 30m/1h are UTC-grid sums of canonical 15m; 1d is site-local days (finalized days from canonical 1d, later days from canonical 15m). Portal-scoped; read-only.';

DO $post$
DECLARE
    v_sig  TEXT := 'analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)';
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
        RAISE EXCEPTION 'Migration 278 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 278 postcondition failed: % must be executable by ems_app and not by PUBLIC.', v_sig;
    END IF;
    v_body := lower(pg_get_functiondef(v_sig::regprocedure));
    IF position('insert into' IN v_body) > 0
       OR position('update ' IN v_body) > 0
       OR position('delete from' IN v_body) > 0
       OR position('execute ' IN v_body) > 0
       OR position('format(' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 278 postcondition failed: the series function contains a write statement or dynamic SQL.';
    END IF;
    IF position('get_canonical_energy_read' IN v_body) = 0
       OR position('v_energy_reporting_hourly' IN v_body) > 0
       OR position('primary_meter' IN v_body) > 0 THEN
        RAISE EXCEPTION 'Migration 278 postcondition failed: Energy values must come from the canonical read only, never the site-local hourly tier or PRIMARY_METER.';
    END IF;
    RAISE NOTICE 'Migration 278: all postconditions passed (portal-scoped Analytics Energy series read function created; read-only).';
END;
$post$;
