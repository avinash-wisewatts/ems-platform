-- ============================================================================
-- Migration 281
-- Fix: analytics.get_portal_asset_energy_series (migration 279) trusted a
-- persisted 15-minute row whose bucket had only STARTED before the
-- 'energy_consumption_15min' pipeline checkpoint.
--
-- Found by the migration 275-280 staging parity gate (2026-09-27, read-only,
-- PT-5): with the 15-minute checkpoint at 18:40 IST, the bucket
-- [18:30, 18:45) IST was served from the persisted tier with 14 of 15
-- intervals for 25 assets (45.4237 kWh vs 48.2726 kWh from the canonical
-- read). The 15-minute job's window end is bounded by its 1-minute/5-minute
-- parents (migration 209), so its checkpoint is not always on the 15-minute
-- grid; the persisted row of the bucket it falls inside is partial until the
-- next run. Migration 279's own header states the intended rule -- "15m for
-- buckets ending at/before" the checkpoint -- and its hourly and daily tiers
-- already apply bucket_end <= checkpoint; only the 15-minute source used
-- bucket_start < checkpoint.
--
-- Change: after the checkpoints are read, the 15-minute checkpoint is floored
-- to the 15-minute grid (when finite). Persisted 15-minute rows are then used
-- only for buckets that had ended at the checkpoint, and the straddling bucket
-- -- like every newer one -- comes from analytics.v_energy_semantic_rollup_15min,
-- the persisted tier's own source. Nothing else changes: the rest of the body
-- is byte-identical to migration 279 (postcondition), so attribution,
-- effective-date rules, status precedence, reconstructed-Energy semantics,
-- capture handling, output shape and grants are unchanged.
--
-- Not changed: analytics.get_canonical_energy_read, every Grafana path, the
-- Asset View, analytics.energy_direction_status, and metadata.asset_points.
--
-- Rollback: re-apply migration 279's CREATE OR REPLACE FUNCTION.
-- ============================================================================

DO $pre$
DECLARE
    v_sig TEXT := 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)';
BEGIN
    IF to_regprocedure(v_sig) IS NULL THEN
        RAISE EXCEPTION 'Migration 281 precondition failed: % is missing (migration 279).', v_sig;
    END IF;
    IF md5(pg_get_functiondef(v_sig::regprocedure)) <> '6751768c3dd491486ff67fa81969ec60' THEN
        RAISE EXCEPTION 'Migration 281 precondition failed: % differs from the migration 279 definition.', v_sig;
    END IF;
END;
$pre$;

CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series
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
    v_width        INTERVAL;
    v_grid_from    TIMESTAMPTZ;
    v_grid_to      TIMESTAMPTZ;
    v_policy_from  TIMESTAMPTZ;
    v_capture      INTEGER;
    v_capture_n    INTEGER;
    v_policy_gap   BOOLEAN;
    v_raw_keep     INTERVAL;
    v_reason       TEXT;
    v_c15          TIMESTAMPTZ;
    v_ch           TIMESTAMPTZ;
    v_cd           TIMESTAMPTZ;
    v_asset        UUID;
    v_asset_reason TEXT;
    v_imp_devs     UUID[];
    v_exp_devs     UUID[];
    v_all_devs     UUID[];
    v_fine_from    TIMESTAMPTZ;
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

    -- ------------------------------------------------------------------
    -- Grid.
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
        v_grid_from := date_bin(v_width, p_from, c_origin);
        v_grid_to   := date_bin(v_width, p_to, c_origin);
        IF v_grid_to < p_to THEN
            v_grid_to := v_grid_to + v_width;
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Capture-policy consistency over the grid (a change or a gap makes the
    -- expected-interval arithmetic undefined; never emit a partial series).
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

        IF v_policy_gap OR v_capture_n <> 1 THEN
            v_reason := 'CAPTURE_POLICY_CHANGE';
        ELSIF (p_resolution = '1m' AND v_capture <> 60)
           OR (p_resolution <> '1m' AND v_capture > 900) THEN
            v_reason := 'RESOLUTION_UNAVAILABLE';
        END IF;
    END IF;

    IF v_reason IS NULL AND p_resolution = '1m' THEN
        SELECT (j.config ->> 'drop_after')::INTERVAL INTO v_raw_keep
        FROM timescaledb_information.jobs AS j
        WHERE j.hypertable_schema = 'analytics'
          AND j.hypertable_name = 'energy_consumption_1min'
          AND j.proc_name = 'policy_retention'
        LIMIT 1;
        IF v_raw_keep IS NOT NULL AND v_grid_from < v_now - v_raw_keep THEN
            v_reason := 'RESOLUTION_UNAVAILABLE';
        END IF;
    END IF;

    -- ------------------------------------------------------------------
    -- Tier checkpoints (NULL = the tier has never run: use none of it).
    -- ------------------------------------------------------------------
    SELECT COALESCE(MAX(ps.last_received_at) FILTER (WHERE ps.pipeline_name = 'energy_consumption_15min'), '-infinity'),
           COALESCE(MAX(ps.last_received_at) FILTER (WHERE ps.pipeline_name = 'energy_consumption_hourly'), '-infinity'),
           COALESCE(MAX(ps.last_received_at) FILTER (WHERE ps.pipeline_name = 'energy_consumption_daily'), '-infinity')
    INTO v_c15, v_ch, v_cd
    FROM telemetry.pipeline_state AS ps
    WHERE ps.pipeline_name IN ('energy_consumption_15min', 'energy_consumption_hourly', 'energy_consumption_daily');

    -- Migration 281: the 15-minute checkpoint can fall inside a bucket (the
    -- 15-minute job is bounded by its 1-minute/5-minute parents). Floor it to
    -- the 15-minute grid so a persisted 15-minute row is used only when its
    -- whole bucket had ended at the checkpoint; the straddling bucket comes
    -- from the semantic rollup, like every newer bucket.
    IF isfinite(v_c15) THEN
        v_c15 := date_bin(INTERVAL '15 minutes', v_c15, c_origin);
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
        v_asset_reason := v_reason;

        SELECT array_agg(DISTINCT w.device_id) INTO v_imp_devs
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to) AS w;
        SELECT array_agg(DISTINCT w.device_id) INTO v_exp_devs
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to) AS w;
        SELECT array_agg(DISTINCT d) INTO v_all_devs
        FROM unnest(COALESCE(v_imp_devs, '{}') || COALESCE(v_exp_devs, '{}')) AS d;

        IF v_asset_reason IS NULL AND p_resolution = '1d' AND EXISTS (
            SELECT 1 FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = v_org
              AND d.device_id = ANY(v_all_devs)
              AND d.bucket_start >= v_grid_from - INTERVAL '1 day'
              AND d.bucket_start < v_grid_to
              AND d.site_timezone IS DISTINCT FROM v_tz
        ) THEN
            v_asset_reason := 'TIMEZONE_MISMATCH';
        END IF;

        IF v_asset_reason IS NOT NULL THEN
            RETURN QUERY SELECT v_asset, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::NUMERIC, NULL::NUMERIC,
                                NULL::TEXT, NULL::TEXT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BOOLEAN, v_asset_reason;
            CONTINUE;
        END IF;

        -- --------------------------------------------------------------
        -- 1m: raw native rows, canonical native attribution and status.
        -- --------------------------------------------------------------
        IF p_resolution = '1m' THEN
            RETURN QUERY
            WITH imp_w AS (
                SELECT * FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to)
            ),
            exp_w AS (
                SELECT * FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to)
            ),
            imp AS (
                SELECT DISTINCT ON (n.bucket_start)
                       n.bucket_start AS b, n.import_consumption_kwh AS kwh,
                       CASE
                           WHEN NOT n.is_measured_interval AND n.import_reconstruction_role IS NULL THEN 'INVALID_INTERVALS'
                           WHEN NOT n.import_is_valid THEN 'INVALID_INTERVALS'
                           WHEN n.import_reset_detected THEN 'RESET_DETECTED'
                           WHEN n.import_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                           WHEN n.import_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                           WHEN n.import_rollover_detected THEN 'ROLLOVER_DETECTED'
                           ELSE 'GOOD'
                       END AS st,
                       (n.is_measured_interval AND NOT n.import_is_interior)::INT::BIGINT AS cnt
                FROM analytics.v_energy_consumption_native AS n
                JOIN imp_w AS w
                  ON w.device_id = n.device_id
                 AND n.bucket_start < w.window_to
                 AND n.bucket_start + make_interval(secs => n.native_resolution_seconds) > w.window_from
                WHERE n.organization_id = v_org
                  AND n.device_id = ANY(v_imp_devs)
                  AND n.bucket_start >= v_grid_from - INTERVAL '5 minutes'
                  AND n.bucket_start < v_grid_to
                ORDER BY n.bucket_start, w.window_from DESC
            ),
            exp AS (
                SELECT DISTINCT ON (n.bucket_start)
                       n.bucket_start AS b, n.export_consumption_kwh AS kwh,
                       CASE
                           WHEN NOT n.is_measured_interval AND n.export_reconstruction_role IS NULL THEN 'INVALID_INTERVALS'
                           WHEN NOT n.export_is_valid THEN 'INVALID_INTERVALS'
                           WHEN n.export_reset_detected THEN 'RESET_DETECTED'
                           WHEN n.export_quality_code = 'GAP' THEN 'GAPS_DETECTED'
                           WHEN n.export_reconstruction_role IS NOT NULL THEN 'RECONSTRUCTED_TIMING'
                           WHEN n.export_rollover_detected THEN 'ROLLOVER_DETECTED'
                           ELSE 'GOOD'
                       END AS st,
                       (n.is_measured_interval AND NOT n.export_is_interior)::INT::BIGINT AS cnt
                FROM analytics.v_energy_consumption_native AS n
                JOIN exp_w AS w
                  ON w.device_id = n.device_id
                 AND n.bucket_start < w.window_to
                 AND n.bucket_start + make_interval(secs => n.native_resolution_seconds) > w.window_from
                WHERE n.organization_id = v_org
                  AND n.device_id = ANY(v_exp_devs)
                  AND n.bucket_start >= v_grid_from - INTERVAL '5 minutes'
                  AND n.bucket_start < v_grid_to
                ORDER BY n.bucket_start, w.window_from DESC
            ),
            imp_c AS (
                SELECT date_bin(v_width, i.b, c_origin) AS b, SUM(i.kwh) AS kwh,
                       MIN(array_position(c_status, i.st)) AS rnk, SUM(i.cnt)::BIGINT AS cnt
                FROM imp AS i GROUP BY 1
            ),
            exp_c AS (
                SELECT date_bin(v_width, e.b, c_origin) AS b, SUM(e.kwh) AS kwh,
                       MIN(array_position(c_status, e.st)) AS rnk, SUM(e.cnt)::BIGINT AS cnt
                FROM exp AS e GROUP BY 1
            )
            SELECT v_asset, g.gs, g.gs + v_width, i.kwh, e.kwh, c_status[i.rnk], c_status[e.rnk],
                   COALESCE(i.cnt, 0), COALESCE(e.cnt, 0),
                   (EXTRACT(EPOCH FROM v_width) / v_capture)::BIGINT,
                   g.gs + v_width > v_now, NULL::TEXT
            FROM generate_series(v_grid_from, v_grid_to - v_width, v_width) AS g(gs)
            LEFT JOIN imp_c AS i ON i.b = g.gs
            LEFT JOIN exp_c AS e ON e.b = g.gs
            ORDER BY g.gs;
            CONTINUE;
        END IF;

        -- --------------------------------------------------------------
        -- 15m / 30m / 1h / 1d. First, where 15-minute rows are needed:
        -- 15m/30m everywhere; 1h/1d only from the first bucket the coarse
        -- tier cannot serve (its checkpoint, or the earliest bucket a
        -- binding starts/ends inside).
        -- --------------------------------------------------------------
        IF p_resolution IN ('15m', '30m') THEN
            v_fine_from := v_grid_from;
        ELSE
            SELECT MIN(t) INTO v_fine_from
            FROM (
                SELECT CASE WHEN p_resolution = '1h' THEN date_bin(INTERVAL '1 hour', GREATEST(v_ch, v_grid_from), c_origin)
                            ELSE date_trunc('day', GREATEST(v_cd, v_grid_from) AT TIME ZONE v_tz) AT TIME ZONE v_tz END AS t
                UNION ALL
                SELECT CASE WHEN p_resolution = '1h' THEN date_bin(INTERVAL '1 hour', b.t, c_origin)
                            ELSE date_trunc('day', b.t AT TIME ZONE v_tz) AT TIME ZONE v_tz END
                FROM (
                    SELECT w.window_from AS t
                    FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to) AS w
                    WHERE w.window_from > v_grid_from
                    UNION ALL
                    SELECT w.window_to
                    FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to) AS w
                    WHERE w.window_to < v_grid_to
                    UNION ALL
                    SELECT w.window_from
                    FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to) AS w
                    WHERE w.window_from > v_grid_from
                    UNION ALL
                    SELECT w.window_to
                    FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to) AS w
                    WHERE w.window_to < v_grid_to
                ) AS b
            ) AS starts;
            v_fine_from := LEAST(GREATEST(v_fine_from, v_grid_from), v_grid_to);
        END IF;

        RETURN QUERY
        WITH imp_w AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to)
        ),
        exp_w AS (
            SELECT * FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to)
        ),
        grid AS (
            SELECT gs AS b_start, gs + v_width AS b_end
            FROM generate_series(v_grid_from, v_grid_to - v_width, v_width) AS gs
            WHERE p_resolution <> '1d'
            UNION ALL
            SELECT (d::date::timestamp AT TIME ZONE v_tz), ((d::date + 1)::timestamp AT TIME ZONE v_tz)
            FROM generate_series((v_grid_from AT TIME ZONE v_tz)::date,
                                 (v_grid_to AT TIME ZONE v_tz)::date - 1, INTERVAL '1 day') AS d
            WHERE p_resolution = '1d'
        ),
        -- 15-minute device rows: persisted up to the 15m checkpoint, the
        -- semantic rollup (the persisted tier's own source) after it.
        src15 AS (
            SELECT p.device_id, p.bucket_start,
                   p.import_consumption_kwh, p.export_consumption_kwh,
                   p.valid_import_intervals, p.invalid_import_intervals,
                   p.valid_export_intervals, p.invalid_export_intervals,
                   p.import_reset_intervals, p.export_reset_intervals,
                   p.import_gap_intervals, p.export_gap_intervals,
                   p.import_reconstructed_intervals, p.export_reconstructed_intervals,
                   p.import_rollover_intervals, p.export_rollover_intervals
            FROM analytics.energy_consumption_15min AS p
            WHERE p.organization_id = v_org
              AND p.device_id = ANY(v_all_devs)
              AND p.bucket_start >= v_fine_from
              AND p.bucket_start < LEAST(v_c15, v_grid_to)
            UNION ALL
            SELECT r.device_id, r.bucket_start,
                   r.import_consumption_kwh, r.export_consumption_kwh,
                   r.valid_import_intervals, r.invalid_import_intervals,
                   r.valid_export_intervals, r.invalid_export_intervals,
                   r.import_reset_intervals, r.export_reset_intervals,
                   r.import_gap_intervals, r.export_gap_intervals,
                   r.import_reconstructed_intervals, r.export_reconstructed_intervals,
                   r.import_rollover_intervals, r.export_rollover_intervals
            FROM analytics.v_energy_semantic_rollup_15min AS r
            WHERE r.organization_id = v_org
              AND r.device_id = ANY(v_all_devs)
              AND r.bucket_start >= GREATEST(v_c15, v_fine_from)
              AND r.bucket_start < v_grid_to
        ),
        imp15 AS (
            SELECT DISTINCT ON (s.bucket_start)
                   s.bucket_start AS b, s.import_consumption_kwh AS kwh,
                   analytics.energy_direction_status(s.valid_import_intervals, s.invalid_import_intervals,
                       s.import_reset_intervals, s.import_gap_intervals,
                       s.import_reconstructed_intervals, s.import_rollover_intervals) AS st,
                   (s.valid_import_intervals + s.invalid_import_intervals)::BIGINT AS cnt
            FROM src15 AS s
            JOIN imp_w AS w
              ON w.device_id = s.device_id
             AND s.bucket_start < w.window_to
             AND s.bucket_start + INTERVAL '15 minutes' > w.window_from
            ORDER BY s.bucket_start, w.window_from DESC
        ),
        exp15 AS (
            SELECT DISTINCT ON (s.bucket_start)
                   s.bucket_start AS b, s.export_consumption_kwh AS kwh,
                   analytics.energy_direction_status(s.valid_export_intervals, s.invalid_export_intervals,
                       s.export_reset_intervals, s.export_gap_intervals,
                       s.export_reconstructed_intervals, s.export_rollover_intervals) AS st,
                   (s.valid_export_intervals + s.invalid_export_intervals)::BIGINT AS cnt
            FROM src15 AS s
            JOIN exp_w AS w
              ON w.device_id = s.device_id
             AND s.bucket_start < w.window_to
             AND s.bucket_start + INTERVAL '15 minutes' > w.window_from
            ORDER BY s.bucket_start, w.window_from DESC
        ),
        -- Persisted coarse rows usable whole: processed by their pipeline and
        -- inside exactly one binding window of the direction.
        coarse AS (
            SELECT h.device_id, h.bucket_start AS b, h.bucket_start + INTERVAL '1 hour' AS e,
                   h.import_consumption_kwh, h.export_consumption_kwh,
                   h.valid_import_intervals, h.invalid_import_intervals,
                   h.valid_export_intervals, h.invalid_export_intervals,
                   h.import_reset_intervals, h.export_reset_intervals,
                   h.import_gap_intervals, h.export_gap_intervals,
                   h.import_reconstructed_intervals, h.export_reconstructed_intervals,
                   h.import_rollover_intervals, h.export_rollover_intervals
            FROM analytics.energy_consumption_hourly AS h
            WHERE p_resolution = '1h'
              AND h.organization_id = v_org
              AND h.device_id = ANY(v_all_devs)
              AND h.bucket_start >= v_grid_from
              AND h.bucket_start + INTERVAL '1 hour' <= LEAST(v_ch, v_grid_to)
            UNION ALL
            SELECT d.device_id, d.bucket_start, ((d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone),
                   d.import_consumption_kwh, d.export_consumption_kwh,
                   d.valid_import_intervals, d.invalid_import_intervals,
                   d.valid_export_intervals, d.invalid_export_intervals,
                   d.import_reset_intervals, d.export_reset_intervals,
                   d.import_gap_intervals, d.export_gap_intervals,
                   d.import_reconstructed_intervals, d.export_reconstructed_intervals,
                   d.import_rollover_intervals, d.export_rollover_intervals
            FROM analytics.energy_consumption_daily AS d
            WHERE p_resolution = '1d'
              AND d.organization_id = v_org
              AND d.device_id = ANY(v_all_devs)
              AND d.bucket_start >= v_grid_from
              AND d.bucket_start < v_grid_to
              AND ((d.consumption_date + 1)::timestamp AT TIME ZONE d.site_timezone) <= LEAST(v_cd, v_grid_to)
        ),
        imp_coarse AS (
            SELECT c.b, c.import_consumption_kwh AS kwh,
                   array_position(c_status, analytics.energy_direction_status(c.valid_import_intervals, c.invalid_import_intervals,
                       c.import_reset_intervals, c.import_gap_intervals,
                       c.import_reconstructed_intervals, c.import_rollover_intervals)) AS rnk,
                   (c.valid_import_intervals + c.invalid_import_intervals)::BIGINT AS cnt
            FROM coarse AS c
            JOIN imp_w AS w
              ON w.device_id = c.device_id AND w.window_from <= c.b AND c.e <= w.window_to
            WHERE (SELECT COUNT(*) FROM imp_w AS w2 WHERE w2.window_from < c.e AND w2.window_to > c.b) = 1
        ),
        exp_coarse AS (
            SELECT c.b, c.export_consumption_kwh AS kwh,
                   array_position(c_status, analytics.energy_direction_status(c.valid_export_intervals, c.invalid_export_intervals,
                       c.export_reset_intervals, c.export_gap_intervals,
                       c.export_reconstructed_intervals, c.export_rollover_intervals)) AS rnk,
                   (c.valid_export_intervals + c.invalid_export_intervals)::BIGINT AS cnt
            FROM coarse AS c
            JOIN exp_w AS w
              ON w.device_id = c.device_id AND w.window_from <= c.b AND c.e <= w.window_to
            WHERE (SELECT COUNT(*) FROM exp_w AS w2 WHERE w2.window_from < c.e AND w2.window_to > c.b) = 1
        ),
        -- Every grid bucket per direction: a usable persisted coarse row, or
        -- its attributed 15-minute rows summed.
        imp_c AS (
            SELECT ic.b, ic.kwh, ic.rnk, ic.cnt FROM imp_coarse AS ic
            UNION ALL
            SELECT k.b, SUM(k.kwh), MIN(array_position(c_status, k.st)), SUM(k.cnt)::BIGINT
            FROM (
                SELECT CASE WHEN p_resolution = '1d'
                            THEN (f.b AT TIME ZONE v_tz)::date::timestamp AT TIME ZONE v_tz
                            ELSE date_bin(v_width, f.b, c_origin) END AS b,
                       f.kwh, f.st, f.cnt
                FROM imp15 AS f
            ) AS k
            WHERE NOT EXISTS (SELECT 1 FROM imp_coarse AS ic WHERE ic.b = k.b)
            GROUP BY k.b
        ),
        exp_c AS (
            SELECT ec.b, ec.kwh, ec.rnk, ec.cnt FROM exp_coarse AS ec
            UNION ALL
            SELECT k.b, SUM(k.kwh), MIN(array_position(c_status, k.st)), SUM(k.cnt)::BIGINT
            FROM (
                SELECT CASE WHEN p_resolution = '1d'
                            THEN (f.b AT TIME ZONE v_tz)::date::timestamp AT TIME ZONE v_tz
                            ELSE date_bin(v_width, f.b, c_origin) END AS b,
                       f.kwh, f.st, f.cnt
                FROM exp15 AS f
            ) AS k
            WHERE NOT EXISTS (SELECT 1 FROM exp_coarse AS ec WHERE ec.b = k.b)
            GROUP BY k.b
        )
        SELECT v_asset, g.b_start, g.b_end, i.kwh, e.kwh, c_status[i.rnk], c_status[e.rnk],
               COALESCE(i.cnt, 0), COALESCE(e.cnt, 0),
               (EXTRACT(EPOCH FROM (g.b_end - g.b_start)) / v_capture)::BIGINT,
               g.b_end > v_now, NULL::TEXT
        FROM grid AS g
        LEFT JOIN imp_c AS i ON i.b = g.b_start
        LEFT JOIN exp_c AS e ON e.b = g.b_start
        ORDER BY g.b_start;
    END LOOP;
END;
$function$;

DO $post$
DECLARE
    v_sig   TEXT := 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)';
    v_block TEXT := E'\n    -- Migration 281: the 15-minute checkpoint can fall inside a bucket (the\n    -- 15-minute job is bounded by its 1-minute/5-minute parents). Floor it to\n    -- the 15-minute grid so a persisted 15-minute row is used only when its\n    -- whole bucket had ended at the checkpoint; the straddling bucket comes\n    -- from the semantic rollup, like every newer bucket.\n    IF isfinite(v_c15) THEN\n        v_c15 := date_bin(INTERVAL ''15 minutes'', v_c15, c_origin);\n    END IF;\n';
    v_def   TEXT;
BEGIN
    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF position(v_block IN v_def) = 0 THEN
        RAISE EXCEPTION 'Migration 281 postcondition failed: the 15-minute checkpoint floor is missing.';
    END IF;
    IF md5(replace(v_def, v_block, '')) <> '6751768c3dd491486ff67fa81969ec60' THEN
        RAISE EXCEPTION 'Migration 281 postcondition failed: the function changed outside the migration 281 addition.';
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
        RAISE EXCEPTION 'Migration 281 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR has_function_privilege('grafana_reader', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 281 postcondition failed: % must remain executable by ems_app only.', v_sig;
    END IF;
    RAISE NOTICE 'Migration 281: all postconditions passed (15-minute checkpoint floored; body otherwise identical to migration 279).';
END;
$post$;
