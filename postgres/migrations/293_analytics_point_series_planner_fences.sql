-- ============================================================================
-- Migration 293
-- Analytics B3 performance fix: planner fences in
-- analytics.get_portal_asset_point_series (migration 292).
--
-- Staging verification of migration 292 (2026-10-09) found every measurement
-- series read timing out (> 30 s; 55 s measured for one 75-minute 15m
-- series) and per-phase Energy taking ~5 s. auto_explain showed the planner
-- flattening the per-window LATERAL probes of the src CTE into a hash join
-- (sequential scan of every analytics.point_telemetry_15m chunk, ~10 M rows)
-- and a merge join (every telemetry.normalized_points chunk for the logical
-- point, ~2.6 M rows, sorted on disk), because the MATERIALIZED windows CTE
-- is estimated at 1000 rows and its time bounds cannot be pushed into a
-- hash / merge join. An OFFSET 0 fence in each probe keeps it a
-- parameterized nested-loop index range scan with runtime chunk exclusion
-- (0.4 ms for the same 15-minute probe on staging).
--
-- Change: CREATE OR REPLACE of analytics.get_portal_asset_point_series with
-- the migration 292 body, plus OFFSET 0 at the end of its four source probes
-- (raw 1m samples, persisted 15-minute rows, raw edge samples, register
-- deltas). OFFSET 0 returns every row: results are identical. Signature,
-- result columns, owner, SECURITY DEFINER, search_path and grants are
-- unchanged. No table, index, tier, job or data change.
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_portal_asset_point_series(bigint, uuid, uuid[], text[], text[], timestamptz, timestamptz, text, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 293 precondition failed: analytics.get_portal_asset_point_series (migration 292) does not exist.';
    END IF;
    IF position('OFFSET 0' IN pg_get_functiondef('analytics.get_portal_asset_point_series(bigint, uuid, uuid[], text[], text[], timestamptz, timestamptz, text, timestamptz)'::regprocedure)) > 0 THEN
        RAISE EXCEPTION 'Migration 293 precondition failed: the series read already carries planner fences.';
    END IF;
END;
$pre$;


CREATE OR REPLACE FUNCTION analytics.get_portal_asset_point_series
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_asset_ids      UUID[],
    p_parameters     TEXT[],
    p_qualifiers     TEXT[],
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT,
    p_as_of          TIMESTAMPTZ
)
RETURNS TABLE
(
    series_index                INTEGER,
    asset_id                    UUID,
    data_point                  TEXT,
    qualifier                   TEXT,
    source_kind                 TEXT,
    bucket_start                TIMESTAMPTZ,
    bucket_end                  TIMESTAMPTZ,
    value                       NUMERIC,
    min_value                   NUMERIC,
    max_value                   NUMERIC,
    valid_intervals             BIGINT,
    invalid_intervals           BIGINT,
    gap_intervals               BIGINT,
    reset_intervals             BIGINT,
    rollover_intervals          BIGINT,
    expected_intervals          BIGINT,
    assigned_expected_intervals BIGINT,
    data_state                  TEXT,
    quality                     TEXT,
    unavailable_reasons         TEXT[],
    first_data_at               TIMESTAMPTZ,
    last_data_at                TIMESTAMPTZ,
    assigned_in_range           BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry, config
AS $function$
DECLARE
    c_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    c_local_origin CONSTANT TIMESTAMP := TIMESTAMP '2000-01-01 00:00:00';
    c_15m CONSTANT INTERVAL := INTERVAL '15 minutes';
    v_now          TIMESTAMPTZ;
    v_org          UUID;
    v_tz           TEXT;
    v_width        INTERVAL;
    v_local        TIMESTAMP;
    v_grid_from    TIMESTAMPTZ;
    v_grid_to      TIMESTAMPTZ;
    v_policy_from  TIMESTAMPTZ;
    v_capture      INTEGER;
    v_capture_n    INTEGER;
    v_policy_gap   BOOLEAN;
    v_reasons      TEXT[] := ARRAY[]::TEXT[];
    v_accessible   UUID[];
    v_i            INTEGER;
    v_asset        UUID;
    v_code         TEXT;
    v_qual         TEXT;
    v_point        UUID;
    v_kind         TEXT;
    v_floor        TIMESTAMPTZ;
    v_series_reasons TEXT[];
    v_first        TIMESTAMPTZ;
    v_last         TIMESTAMPTZ;
    v_in_range     BOOLEAN;
BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('1m', '15m', '30m', '1h', '1d') THEN
        RAISE EXCEPTION 'p_resolution must be one of 1m, 15m, 30m, 1h, 1d; got %', p_resolution
            USING ERRCODE = '22023';
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RAISE EXCEPTION 'p_from and p_to are required and p_to must be later than p_from'
            USING ERRCODE = '22023';
    END IF;
    IF p_asset_ids IS NULL OR p_parameters IS NULL OR p_qualifiers IS NULL
       OR cardinality(p_asset_ids) <> cardinality(p_parameters)
       OR cardinality(p_asset_ids) <> cardinality(p_qualifiers) THEN
        RAISE EXCEPTION 'p_asset_ids, p_parameters and p_qualifiers must be parallel arrays'
            USING ERRCODE = '22023';
    END IF;
    v_now := COALESCE(p_as_of, now());

    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    SELECT s.organization_id, s.timezone INTO v_org, v_tz
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;

    SELECT array_agg(la.asset_id) INTO v_accessible
    FROM admin.list_accessible_assets(p_portal_user_id) AS la
    WHERE la.site_id = p_site_id;

    -- ------------------------------------------------------------------
    -- Grid: the Energy read's (migration 282). 1d = site-local days;
    -- otherwise the site-local boundary at or before p_from, stepping by the
    -- width in absolute time.
    -- ------------------------------------------------------------------
    IF p_resolution = '1d' THEN
        v_grid_from := date_trunc('day', p_from AT TIME ZONE v_tz) AT TIME ZONE v_tz;
        v_grid_to   := date_trunc('day', p_to AT TIME ZONE v_tz) AT TIME ZONE v_tz;
        IF v_grid_to < p_to THEN
            v_grid_to := (date_trunc('day', p_to AT TIME ZONE v_tz) + INTERVAL '1 day') AT TIME ZONE v_tz;
        END IF;
    ELSE
        v_width := CASE p_resolution
                       WHEN '1m'  THEN INTERVAL '1 minute'
                       WHEN '15m' THEN INTERVAL '15 minutes'
                       WHEN '30m' THEN INTERVAL '30 minutes'
                       ELSE INTERVAL '1 hour'
                   END;
        v_local     := p_from AT TIME ZONE v_tz;
        v_grid_from := p_from - (v_local - date_bin(v_width, v_local, c_local_origin));
        v_local     := p_to AT TIME ZONE v_tz;
        v_grid_to   := p_to - (v_local - date_bin(v_width, v_local, c_local_origin));
        IF v_grid_to < p_to THEN
            v_grid_to := v_grid_to + v_width;
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Capture-policy gating: identical to the Energy read (migration 282).
    -- ------------------------------------------------------------------
    SELECT MIN(p.effective_from) INTO v_policy_from
    FROM config.telemetry_capture_policies AS p
    WHERE p.is_enabled AND (p.site_id = p_site_id OR p.site_id IS NULL);

    IF v_policy_from IS NOT NULL AND v_grid_to > v_policy_from THEN
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

        IF v_policy_gap THEN
            v_reasons := v_reasons || 'CAPTURE_POLICY_GAP'::TEXT;
        END IF;
        IF v_capture_n <> 1 THEN
            v_reasons := v_reasons || 'CAPTURE_POLICY_CHANGE'::TEXT;
        END IF;
        IF cardinality(v_reasons) = 0
           AND ((p_resolution = '1m' AND v_capture <> 60)
                OR (p_resolution <> '1m' AND v_capture > 900)) THEN
            v_reasons := v_reasons || 'CAPTURE_INTERVAL_TOO_COARSE'::TEXT;
        END IF;
    END IF;

    FOR v_i IN 1 .. cardinality(p_asset_ids) LOOP
        v_asset := p_asset_ids[v_i];
        v_code  := p_parameters[v_i];
        v_qual  := p_qualifiers[v_i];
        v_series_reasons := v_reasons;

        -- The logical point, only for an ACTIVE, accessible asset of this
        -- site and organization; anything else returns no rows (the API
        -- reports NOT_AVAILABLE).
        SELECT lp.id INTO v_point
        FROM metadata.logical_points AS lp
        JOIN config.parameters AS p ON p.id = lp.parameter_id
        WHERE p.code = v_code
          AND lp.qualifier::TEXT IS NOT DISTINCT FROM v_qual
        ORDER BY lp.id
        LIMIT 1;

        IF v_point IS NULL OR NOT EXISTS (
            SELECT 1 FROM metadata.assets AS a
            WHERE a.id = v_asset
              AND a.id = ANY(v_accessible)
              AND a.site_id = p_site_id
              AND a.organization_id = v_org
              AND a.lifecycle_status = 'ACTIVE'
        ) THEN
            CONTINUE;
        END IF;

        -- Register (delta) point when any bound device has register
        -- semantics for it; otherwise a measurement (mean).
        v_kind := CASE WHEN EXISTS (
                           SELECT 1 FROM metadata.asset_points AS ap
                           JOIN metadata.devices AS d ON d.id = ap.device_id
                           JOIN config.energy_register_semantics AS ers
                             ON ers.profile_id = d.profile_id AND ers.logical_point_id = ap.logical_point_id
                            AND ers.is_active
                           WHERE ap.asset_id = v_asset AND ap.logical_point_id = v_point)
                       THEN 'delta' ELSE 'mean' END;

        IF v_kind = 'delta' AND p_resolution = '1m' THEN
            RAISE EXCEPTION 'register (delta) points have no 1-minute source; request 15m or coarser'
                USING ERRCODE = '22023';
        END IF;

        IF cardinality(v_series_reasons) = 0 THEN
            SELECT f.earliest_available INTO v_floor
            FROM analytics.get_analytics_point_resolution_floors(v_now) AS f
            WHERE f.source_kind = v_kind AND f.resolution = p_resolution;
            IF v_floor IS NOT NULL AND v_grid_from < v_floor THEN
                v_series_reasons := v_series_reasons || 'BEFORE_RETENTION_FLOOR'::TEXT;
            END IF;
        END IF;

        IF cardinality(v_series_reasons) > 0 THEN
            RETURN QUERY SELECT v_i, v_asset, v_code, v_qual, v_kind,
                                NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::NUMERIC, NULL::NUMERIC, NULL::NUMERIC,
                                NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BIGINT, NULL::BIGINT, NULL::TEXT, NULL::TEXT,
                                v_series_reasons, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::BOOLEAN;
            CONTINUE;
        END IF;

        -- --------------------------------------------------------------
        -- Series-level data bounds across every binding up to as_of: the
        -- first / last persisted 15-minute row inside a window; for
        -- measurements the last is refined by the newest raw sample of the
        -- last two hours (the 15-minute tier lags by up to its refresh).
        -- --------------------------------------------------------------
        IF v_kind = 'mean' THEN
            -- The first / last whole 15-minute row inside a binding, or a raw
            -- GOOD sample in its partial first 15 minutes / its last two
            -- hours (or its partial last 15 minutes when it has ended).
            SELECT MIN(LEAST(
                       (SELECT q.bucket_start FROM analytics.point_telemetry_15m AS q
                        WHERE q.device_id = ap.device_id AND q.logical_point_id = v_point
                          AND q.bucket_start >= ap.effective_from
                          AND q.bucket_start + c_15m <= COALESCE(ap.effective_to, 'infinity')
                          AND q.bucket_start < v_now
                        ORDER BY q.bucket_start LIMIT 1),
                       (SELECT np.event_time FROM telemetry.normalized_points AS np
                        WHERE isfinite(ap.effective_from)
                          AND np.device_id = ap.device_id AND np.logical_point_id = v_point
                          AND np.event_time >= ap.effective_from
                          AND np.event_time < LEAST(date_bin(c_15m, ap.effective_from, c_origin) + c_15m,
                                                    COALESCE(ap.effective_to, 'infinity'), v_now)
                          AND np.numeric_value IS NOT NULL AND np.quality_code = 'GOOD'
                        ORDER BY np.event_time LIMIT 1))),
                   MAX(GREATEST(
                       (SELECT LEAST(q.bucket_start + c_15m, v_now) FROM analytics.point_telemetry_15m AS q
                        WHERE q.device_id = ap.device_id AND q.logical_point_id = v_point
                          AND q.bucket_start >= ap.effective_from
                          AND q.bucket_start + c_15m <= COALESCE(ap.effective_to, 'infinity')
                          AND q.bucket_start < v_now
                        ORDER BY q.bucket_start DESC LIMIT 1),
                       (SELECT LEAST(np.event_time + make_interval(secs => COALESCE(v_capture, 60)),
                                     COALESCE(ap.effective_to, 'infinity'), v_now)
                        FROM telemetry.normalized_points AS np
                        WHERE np.device_id = ap.device_id AND np.logical_point_id = v_point
                          AND np.event_time >= GREATEST(ap.effective_from,
                                                        LEAST(v_now, COALESCE(ap.effective_to, 'infinity')) - INTERVAL '2 hours')
                          AND np.event_time < LEAST(COALESCE(ap.effective_to, 'infinity'), v_now)
                          AND np.numeric_value IS NOT NULL AND np.quality_code = 'GOOD'
                        ORDER BY np.event_time DESC LIMIT 1)))
            INTO v_first, v_last
            FROM metadata.asset_points AS ap
            WHERE ap.asset_id = v_asset AND ap.logical_point_id = v_point
              AND ap.effective_from < v_now;
        ELSE
            SELECT MIN((SELECT r.bucket_start FROM analytics.energy_register_delta_15min AS r
                        WHERE r.organization_id = v_org
                          AND r.device_id = ap.device_id AND r.logical_point_id = v_point
                          AND r.bucket_start >= ap.effective_from
                          AND r.bucket_start + c_15m <= COALESCE(ap.effective_to, 'infinity')
                          AND r.bucket_start < v_now AND r.valid_interval_count > 0
                        ORDER BY r.bucket_start LIMIT 1)),
                   MAX((SELECT LEAST(r.bucket_start + c_15m, v_now) FROM analytics.energy_register_delta_15min AS r
                        WHERE r.organization_id = v_org
                          AND r.device_id = ap.device_id AND r.logical_point_id = v_point
                          AND r.bucket_start >= ap.effective_from
                          AND r.bucket_start + c_15m <= COALESCE(ap.effective_to, 'infinity')
                          AND r.bucket_start < v_now AND r.valid_interval_count > 0
                        ORDER BY r.bucket_start DESC LIMIT 1))
            INTO v_first, v_last
            FROM metadata.asset_points AS ap
            WHERE ap.asset_id = v_asset AND ap.logical_point_id = v_point
              AND ap.effective_from < v_now;
        END IF;

        SELECT EXISTS (
            SELECT 1 FROM metadata.asset_points AS ap
            WHERE ap.asset_id = v_asset AND ap.logical_point_id = v_point
              AND ap.effective_from < v_grid_to
              AND (ap.effective_to IS NULL OR ap.effective_to > v_grid_from)
        ) INTO v_in_range;

        RETURN QUERY
        WITH windows AS MATERIALIZED (
            SELECT ap.device_id AS w_device,
                   GREATEST(ap.effective_from, v_grid_from) AS w_from,
                   LEAST(COALESCE(ap.effective_to, 'infinity'::TIMESTAMPTZ), v_grid_to) AS w_to,
                   sc.scale AS w_scale, sc.value_offset AS w_offset, sc.delta_scale AS w_delta_scale
            FROM metadata.asset_points AS ap
            CROSS JOIN LATERAL analytics.analytics_point_source_scale(ap.device_id, v_point) AS sc
            WHERE ap.asset_id = v_asset AND ap.logical_point_id = v_point
              AND ap.effective_from < v_grid_to
              AND (ap.effective_to IS NULL OR ap.effective_to > v_grid_from)
        ),
        grid AS MATERIALIZED (
            SELECT g.b_start, g.b_end
            FROM (
                SELECT (d::TIMESTAMP AT TIME ZONE v_tz) AS b_start,
                       ((d + INTERVAL '1 day')::TIMESTAMP AT TIME ZONE v_tz) AS b_end
                FROM generate_series((v_grid_from AT TIME ZONE v_tz)::DATE::TIMESTAMP,
                                     (v_grid_to AT TIME ZONE v_tz)::DATE::TIMESTAMP - INTERVAL '1 day',
                                     INTERVAL '1 day') AS d
                WHERE p_resolution = '1d'
                UNION ALL
                SELECT s, s + v_width
                FROM generate_series(v_grid_from, v_grid_to - v_width, v_width) AS s
                WHERE p_resolution <> '1d'
            ) AS g
        ),
        -- One row per source row inside a window, already converted. Every
        -- source is probed per window through LATERAL, so each read is an
        -- index range scan on (device_id, logical_point_id, time). Each probe
        -- ends in OFFSET 0 (migration 293): without that fence the planner
        -- pulls the probe up into a hash / merge join over every chunk of the
        -- source (the windows CTE is estimated at 1000 rows), which on
        -- staging volumes took 30-55 s per series instead of milliseconds.
        src AS (
            -- Measurements at 1m: every sample, attributed by its own time.
            SELECT date_bin(INTERVAL '1 minute', x.t, c_origin) AS s_bucket,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END AS s_sum,
                   CASE WHEN x.good THEN 1 ELSE 0 END::BIGINT AS s_count,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END AS s_min,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END AS s_max,
                   CASE WHEN x.good THEN 0 ELSE 1 END::BIGINT AS s_invalid,
                   0::BIGINT AS s_gap, 0::BIGINT AS s_reset, 0::BIGINT AS s_rollover
            FROM windows AS w
            CROSS JOIN LATERAL (
                SELECT np.event_time AS t, np.numeric_value AS v, np.quality_code = 'GOOD' AS good
                FROM telemetry.normalized_points AS np
                WHERE np.device_id = w.w_device
                  AND np.logical_point_id = v_point
                  AND np.event_time >= w.w_from
                  AND np.event_time < w.w_to
                  AND np.numeric_value IS NOT NULL
                OFFSET 0   -- planner fence (migration 293)
            ) AS x
            WHERE v_kind = 'mean' AND p_resolution = '1m'
            UNION ALL
            -- Measurements at 15m and coarser: persisted 15-minute rows
            -- lying entirely inside a window.
            SELECT q.bucket_start,
                   q.sum_value * w.w_scale + w.w_offset * q.sample_count,
                   q.sample_count,
                   LEAST(q.min_value * w.w_scale, q.max_value * w.w_scale) + w.w_offset,
                   GREATEST(q.min_value * w.w_scale, q.max_value * w.w_scale) + w.w_offset,
                   0::BIGINT, 0::BIGINT, 0::BIGINT, 0::BIGINT
            FROM windows AS w
            CROSS JOIN LATERAL (
                SELECT p.bucket_start, p.sum_value, p.sample_count, p.min_value, p.max_value
                FROM analytics.point_telemetry_15m AS p
                WHERE p.device_id = w.w_device
                  AND p.logical_point_id = v_point
                  AND p.bucket_start >= w.w_from
                  AND p.bucket_start + c_15m <= w.w_to
                OFFSET 0   -- planner fence (migration 293)
            ) AS q
            WHERE v_kind = 'mean' AND p_resolution <> '1m'
            UNION ALL
            -- Measurements at 15m and coarser: the raw samples of a window's
            -- partial first / last 15 minutes (a binding that starts or ends
            -- mid-bucket), attributed by their own time. Windows are clipped
            -- to the grid, which is on the 15-minute grid, so only binding
            -- edges are partial.
            SELECT x.t,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END,
                   CASE WHEN x.good THEN 1 ELSE 0 END::BIGINT,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END,
                   CASE WHEN x.good THEN x.v * w.w_scale + w.w_offset END,
                   CASE WHEN x.good THEN 0 ELSE 1 END::BIGINT,
                   0::BIGINT, 0::BIGINT, 0::BIGINT
            FROM windows AS w
            CROSS JOIN LATERAL (
                SELECT w.w_from AS e_from,
                       LEAST(w.w_to, date_bin(c_15m, w.w_from, c_origin) + c_15m) AS e_to
                WHERE date_bin(c_15m, w.w_from, c_origin) <> w.w_from
                UNION ALL
                SELECT GREATEST(w.w_from, date_bin(c_15m, w.w_to, c_origin)), w.w_to
                WHERE date_bin(c_15m, w.w_to, c_origin) <> w.w_to
                  AND date_bin(c_15m, w.w_to, c_origin) > date_bin(c_15m, w.w_from, c_origin)
            ) AS edge
            CROSS JOIN LATERAL (
                SELECT np.event_time AS t, np.numeric_value AS v, np.quality_code = 'GOOD' AS good
                FROM telemetry.normalized_points AS np
                WHERE np.device_id = w.w_device
                  AND np.logical_point_id = v_point
                  AND np.event_time >= edge.e_from
                  AND np.event_time < edge.e_to
                  AND np.numeric_value IS NOT NULL
                OFFSET 0   -- planner fence (migration 293)
            ) AS x
            WHERE v_kind = 'mean' AND p_resolution <> '1m'
            UNION ALL
            -- Per-phase Energy: valid register deltas.
            SELECT r.bucket_start,
                   r.delta_value * w.w_delta_scale,
                   r.valid_interval_count::BIGINT,
                   NULL::NUMERIC, NULL::NUMERIC,
                   r.invalid_interval_count::BIGINT, r.gap_interval_count::BIGINT,
                   r.reset_interval_count::BIGINT, r.rollover_interval_count::BIGINT
            FROM windows AS w
            CROSS JOIN LATERAL (
                SELECT d.bucket_start, d.delta_value, d.valid_interval_count, d.invalid_interval_count,
                       d.gap_interval_count, d.reset_interval_count, d.rollover_interval_count
                FROM analytics.energy_register_delta_15min AS d
                WHERE d.device_id = w.w_device
                  AND d.logical_point_id = v_point
                  AND d.organization_id = v_org
                  AND d.bucket_start >= w.w_from
                  AND d.bucket_start + c_15m <= w.w_to
                OFFSET 0   -- planner fence (migration 293)
            ) AS r
            WHERE v_kind = 'delta'
        ),
        agg AS (
            SELECT CASE WHEN p_resolution = '1d'
                        THEN date_trunc('day', s.s_bucket AT TIME ZONE v_tz) AT TIME ZONE v_tz
                        ELSE v_grid_from + v_width * floor(EXTRACT(EPOCH FROM (s.s_bucket - v_grid_from))
                                                           / EXTRACT(EPOCH FROM v_width))
                   END AS a_start,
                   SUM(s.s_sum) AS a_sum,
                   SUM(s.s_count) AS a_count,
                   MIN(s.s_min) AS a_min,
                   MAX(s.s_max) AS a_max,
                   SUM(s.s_invalid) AS a_invalid,
                   SUM(s.s_gap) AS a_gap,
                   SUM(s.s_reset) AS a_reset,
                   SUM(s.s_rollover) AS a_rollover
            FROM src AS s
            GROUP BY 1
        ),
        shaped AS (
            SELECT g.b_start, g.b_end,
                   CASE WHEN v_kind = 'delta' THEN a.a_sum
                        WHEN COALESCE(a.a_count, 0) > 0 THEN a.a_sum / a.a_count END AS s_value,
                   CASE WHEN v_kind = 'mean' AND COALESCE(a.a_count, 0) > 0 THEN a.a_min END AS s_min,
                   CASE WHEN v_kind = 'mean' AND COALESCE(a.a_count, 0) > 0 THEN a.a_max END AS s_max,
                   COALESCE(a.a_count, 0) AS s_count,
                   COALESCE(a.a_invalid, 0) AS s_invalid,
                   COALESCE(a.a_gap, 0) AS s_gap,
                   COALESCE(a.a_reset, 0) AS s_reset,
                   COALESCE(a.a_rollover, 0) AS s_rollover,
                   CASE WHEN v_capture IS NULL THEN NULL
                        ELSE (EXTRACT(EPOCH FROM (g.b_end - g.b_start)) / v_capture)::BIGINT END AS s_expected,
                   CASE WHEN v_capture IS NULL THEN NULL
                        ELSE COALESCE((
                            SELECT SUM(GREATEST(
                                ceil(EXTRACT(EPOCH FROM LEAST(g.b_end, w.w_to, v_last, v_now)) / v_capture)
                              - ceil(EXTRACT(EPOCH FROM GREATEST(g.b_start, w.w_from, v_first)) / v_capture), 0))
                            FROM windows AS w
                            WHERE v_first IS NOT NULL AND v_last IS NOT NULL
                        ), 0)::BIGINT END AS s_assigned_expected,
                   EXISTS (SELECT 1 FROM windows AS w WHERE w.w_from < g.b_end AND w.w_to > g.b_start) AS s_assigned
            FROM grid AS g
            LEFT JOIN agg AS a ON a.a_start = g.b_start
        ),
        stated AS (
            SELECT sh.*,
                   CASE
                       WHEN sh.b_start >= v_now THEN 'FUTURE'
                       WHEN NOT sh.s_assigned THEN 'NOT_ASSIGNED'
                       WHEN v_first IS NOT NULL AND sh.b_end <= v_first THEN 'BEFORE_DATA'
                       WHEN v_last IS NOT NULL AND sh.b_start >= v_last THEN 'AFTER_LATEST_DATA'
                       WHEN sh.s_value IS NOT NULL THEN 'MEASURED'
                       ELSE 'GAP'
                   END AS s_state
            FROM shaped AS sh
        )
        SELECT v_i, v_asset, v_code, v_qual, v_kind,
               st.b_start, st.b_end, st.s_value, st.s_min, st.s_max,
               (CASE WHEN v_kind = 'mean' AND st.s_expected IS NOT NULL
                     THEN LEAST(st.s_count, st.s_expected) ELSE st.s_count END)::BIGINT,
               st.s_invalid::BIGINT, st.s_gap::BIGINT, st.s_reset::BIGINT, st.s_rollover::BIGINT,
               st.s_expected::BIGINT, st.s_assigned_expected::BIGINT,
               st.s_state,
               CASE WHEN v_kind <> 'mean' THEN NULL
                    WHEN st.s_state = 'GAP' THEN 'GAP'
                    WHEN st.s_state <> 'MEASURED' THEN NULL
                    WHEN st.s_assigned_expected IS NULL THEN NULL
                    WHEN LEAST(st.s_count, COALESCE(st.s_expected, st.s_count)) >= st.s_assigned_expected THEN 'GOOD'
                    ELSE 'PARTIAL'
               END,
               ARRAY[]::TEXT[], v_first, v_last, v_in_range
        FROM stated AS st
        ORDER BY st.b_start;
    END LOOP;
END;
$function$;

ALTER FUNCTION analytics.get_portal_asset_point_series(BIGINT, UUID, UUID[], TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_point_series(BIGINT, UUID, UUID[], TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_point_series(BIGINT, UUID, UUID[], TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_asset_point_series(BIGINT, UUID, UUID[], TEXT[], TEXT[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) IS
'Migration 292 (Analytics B3), planner fences migration 293: generic Analytics series for explicit (asset, parameter code, qualifier) selections (parallel arrays; series_index = 1-based position). Measurements (no register semantics): 1m from telemetry.normalized_points, 15m/30m/1h/1d from analytics.point_telemetry_15m composed into the site-local grid; value = exact mean (sum / GOOD samples), min / max of the samples, all converted to the logical point''s unit with the field-mapping scale/offset (live telemetry''s rule). Per-phase Energy (register semantics): 15m-1d from analytics.energy_register_delta_15min, value = sum of valid deltas in the logical point''s unit; no 1m. Telemetry is attributed only inside effective metadata.asset_points windows (15-minute rows only when entirely inside one). Per bucket: interval counts at the site capture interval, data_state and (measurements) the GOOD/PARTIAL/GAP quality; per series first/last data and assigned_in_range; capture-policy and retention-floor reasons. Portal-scoped (portal_user_can_access_site + list_accessible_assets, ACTIVE assets of the site and organization); no row for an inaccessible or unknown selection. Read-only; never Grafana-keyed.';


DO $post$
DECLARE
    v_sig  CONSTANT TEXT := 'analytics.get_portal_asset_point_series(bigint, uuid, uuid[], text[], text[], timestamptz, timestamptz, text, timestamptz)';
    v_def  TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef AND p.provolatile = 's' AND r.rolname = 'ems_admin'
          AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 293 postcondition failed: % is not SECURITY DEFINER / STABLE / ems_admin / pinned search_path.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 293 postcondition failed: % grants are not ems_app-only.', v_sig;
    END IF;
    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF (length(v_def) - length(replace(v_def, 'OFFSET 0   -- planner fence (migration 293)', '')))
       / length('OFFSET 0   -- planner fence (migration 293)') <> 4 THEN
        RAISE EXCEPTION 'Migration 293 postcondition failed: expected exactly 4 planner fences in %.', v_sig;
    END IF;
    RAISE NOTICE 'Migration 293: all postconditions passed (4 planner fences; grants and security unchanged).';
END;
$post$;
