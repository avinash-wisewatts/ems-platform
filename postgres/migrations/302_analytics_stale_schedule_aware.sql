-- ============================================================================
-- Migration 302
-- Analytics stale flag: schedule-aware pipeline allowance (staging
-- optimization plan T3.10, decision D-020).
--
-- WHAT THE FLAG IS
--   analytics.get_portal_asset_energy_series returns import_stale /
--   export_stale per asset (migration 282, decisions 17/18/21): TRUE when
--       as_of - last_data_at > capture_interval + late_arrival_tolerance
--                              (policy in effect at last_data_at)
--                            + pipeline allowance of the site's path
--   and a binding still extends past last_data_at + threshold. The Analytics
--   page shows "No recent data" for it. last_data_at is the end of the newest
--   measured 1-minute (or 5-minute) interval of the bound device(s).
--
-- WHY IT CHANGES
--   Migration 282 set the pipeline allowance to the SUM of the four
--   forward-stage schedule_intervals plus the CAGG end_offset. That was
--   7 minutes in total with every stage on 1 minute. Migration 300 (D-018)
--   moved the stages to a phased 5-minute batch (normalization +2:40,
--   routing +4:10, ca_energy_1min refresh +4:40, 1-minute tier +0:00 on the
--   UTC 5-minute grid), and the sum became 4 x 5 + 1 = 21 minutes: the flag
--   only appeared 23 minutes after data stopped. The stages run in sequence
--   inside ONE 5-minute cycle, so the sum overstates the latency by ~3 cycles.
--
-- NEW ALLOWANCE (analytics.energy_stale_pipeline_allowance(native_seconds))
--   Phased pipeline: when every stage of the path is exactly one job on a
--   fixed schedule with the same schedule_interval C, and the CAGG end_offset
--   is no longer than the normalization->refresh wait (so the refresh always
--   covers the routed batch):
--       allowance = C + span + 60 s
--       span      = w(norm->routing) + w(routing->refresh) + w(refresh->tier)
--       w(a->b)   = (phase_b - phase_a) mod C, phase = initial_start mod C;
--                   a wait under 10 s is a race (the next stage can start
--                   before the previous one commits) and counts one more C.
--   Otherwise (stages not phased, e.g. the 1-minute production schedule where
--   the CAGG refresh is not fixed, or the 5-minute path whose 1080 runs every
--   minute): the migration-282 sum, unchanged.
--   NULL when any stage is missing (stale stays NULL, as before).
--
--   Why C + span bounds the healthy age: normalization at time N finalizes
--   every bucket whose deadline (end + tolerance) is <= N; the newest
--   finalized bucket therefore ends after N - tolerance - capture. The 1-minute
--   tier publishes it at N + span, and the next publication is one cycle
--   later. Just before it the age is < capture + tolerance + C + span. The
--   60 s margin covers job execution time (1-3 s measured) and scheduler
--   jitter.
--
--   Staging today (60 s capture, 60 s tolerance; phases 160/250/280/0 s):
--   span = 90 + 30 + 20 = 140 s, allowance = 300 + 140 + 60 = 8 min 20 s,
--   threshold = 2 min + 8 min 20 s = 10 min 20 s (was 23 min). With the
--   900 s default tolerance: 24 min 20 s (was 37 min).
--   Measured on staging (2026-10-14 11:55 .. 2026-10-15 12:15 UTC, 591
--   publication cycles of two devices on two sites): healthy peak age p50
--   9:00, p99 9:03, max 9:03 -> 77 s headroom. A normalization retry
--   (retry_period 1 min, lands before routing) adds nothing. A missed batch,
--   or a routing / refresh retry (lands after the 1-minute tier's slot),
--   delays the batch one full cycle -> peak 14:03 -> stale (decided by the
--   user, run 22: detect the missed batch; a routing retry shows stale for
--   up to ~3 min 40 s and clears).
--
-- CHANGE
--   1. New analytics.energy_stale_pipeline_allowance(integer): LANGUAGE sql,
--      STABLE, SECURITY INVOKER, no SET, owned by ems_admin, EXECUTE revoked
--      from PUBLIC / ems_app / grafana_reader (the migration-283 helper
--      convention; it is called only from the SECURITY DEFINER series
--      function). Reads timescaledb_information.jobs only.
--   2. analytics.get_portal_asset_energy_series: the two "SELECT ... INTO
--      v_stage_1m / v_stage_5m" blocks become calls of the helper. Every
--      other byte of the migration-284 body is unchanged (postcondition:
--      swapping the block back gives the 284 md5 3f43cdae..., the definition
--      live on staging 2026-10-15). Signature, return type, owner, SECURITY
--      DEFINER, STABLE, search_path and grants are unchanged.
--   Semantics kept: no data -> FALSE; no capture policy at last_data_at ->
--   NULL; unverified capture interval (900 s) or a missing stage -> NULL;
--   stale only while last_data_at is inside the range and a binding extends
--   past it; a paused (unscheduled) stage still counts its schedule.
--
-- Not changed: jobs, schedules, configuration, capture policies, every other
-- function or view, Grafana, data. Read-only at runtime.
--
-- Rollback: re-apply migration 284's CREATE OR REPLACE FUNCTION
-- analytics.get_portal_asset_energy_series, then
-- DROP FUNCTION analytics.energy_stale_pipeline_allowance(integer).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 302 precondition failed: the series function is missing.';
    END IF;
    IF md5(pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure)) <> '3f43cdae3e4dbb21087d31bc77c7bab0' THEN
        RAISE EXCEPTION 'Migration 302 precondition failed: the series function differs from the migration 284 definition.';
    END IF;
    IF to_regprocedure('analytics.energy_stale_pipeline_allowance(integer)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 302 precondition failed: analytics.energy_stale_pipeline_allowance(integer) already exists.';
    END IF;
END;
$pre$;

CREATE FUNCTION analytics.energy_stale_pipeline_allowance(p_native_seconds integer)
RETURNS interval
LANGUAGE sql
STABLE
AS $function$
    WITH stage AS (
        -- The four forward stages of the path, one row per stage.
        SELECT s.ord,
               count(*)                                                   AS jobs,
               min(j.schedule_interval)                                   AS si_min,
               max(j.schedule_interval)                                   AS si,
               max((j.config ->> 'end_offset')::interval)                 AS eo,
               bool_and(j.fixed_schedule AND j.initial_start IS NOT NULL) AS fixed,
               max(extract(epoch FROM j.initial_start))                   AS start_epoch
        FROM (VALUES (1, 'telemetry', 'run_normalization_job'),
                     (2, 'telemetry', 'run_energy_routing_job'),
                     (3, NULL,        'policy_refresh_continuous_aggregate'),
                     (4, 'analytics', CASE p_native_seconds WHEN 60  THEN 'run_energy_consumption_1min_job'
                                                            WHEN 300 THEN 'run_energy_consumption_5min_job' END)
             ) AS s (ord, proc_schema, proc_name)
        JOIN timescaledb_information.jobs AS j
          ON j.proc_name = s.proc_name
         AND (CASE WHEN s.ord = 3
                   THEN j.hypertable_schema = 'telemetry'
                        AND j.hypertable_name = CASE p_native_seconds WHEN 60  THEN 'ca_energy_1min'
                                                                      WHEN 300 THEN 'ca_energy_5min' END
                   ELSE j.proc_schema = s.proc_schema END)
        GROUP BY s.ord
    ),
    path AS (
        SELECT count(*)                                                      AS stages,
               bool_and(jobs = 1 AND fixed) AND min(si_min) = max(si)        AS phased,
               max(si)                                                       AS cycle,
               extract(epoch FROM max(si))                                   AS c,
               sum(si)                                                       AS si_sum,
               max(eo)                                                       AS eo,
               array_agg(mod(start_epoch, extract(epoch FROM si)) ORDER BY ord) AS phase
        FROM stage
    ),
    waits AS (
        SELECT p.*,
               (SELECT sum(CASE WHEN d < 10 THEN d + p.c ELSE d END)
                FROM (SELECT mod(p.phase[i + 1] - p.phase[i] + p.c, p.c) AS d
                      FROM generate_series(1, 3) AS i) AS w)            AS span,
               (SELECT sum(CASE WHEN d < 10 THEN d + p.c ELSE d END)
                FROM (SELECT mod(p.phase[i + 1] - p.phase[i] + p.c, p.c) AS d
                      FROM generate_series(1, 2) AS i) AS w)            AS to_refresh
        FROM path AS p
    )
    SELECT CASE
               WHEN stages <> 4 THEN NULL
               WHEN phased AND COALESCE(eo, interval '0') <= make_interval(secs => to_refresh)
                   THEN cycle + make_interval(secs => span) + interval '60 seconds'
               ELSE si_sum + COALESCE(eo, interval '0')
           END
    FROM waits;
$function$;

ALTER FUNCTION analytics.energy_stale_pipeline_allowance(integer) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.energy_stale_pipeline_allowance(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.energy_stale_pipeline_allowance(integer) FROM ems_app;
REVOKE ALL ON FUNCTION analytics.energy_stale_pipeline_allowance(integer) FROM grafana_reader;

COMMENT ON FUNCTION analytics.energy_stale_pipeline_allowance(integer) IS
'Migration 302 (T3.10 / D-020): pipeline allowance of the Analytics stale flag for the 1-minute (60) or 5-minute (300) path, from the live forward-stage jobs. Phased (one fixed-schedule job per stage, equal interval C, end_offset within the normalization->refresh wait): C + chained phase waits + 60 s. Otherwise the migration-282 sum of schedule_intervals + end_offset. NULL when a stage is missing.';

CREATE OR REPLACE FUNCTION analytics.get_portal_asset_energy_series
(
    p_portal_user_id BIGINT,
    p_site_id        UUID,
    p_asset_ids      UUID[],
    p_from           TIMESTAMPTZ,
    p_to             TIMESTAMPTZ,
    p_resolution     TEXT,
    p_as_of          TIMESTAMPTZ
)
RETURNS TABLE
(
    asset_id                           UUID,
    bucket_start                       TIMESTAMPTZ,
    bucket_end                         TIMESTAMPTZ,
    import_kwh                         NUMERIC,
    export_kwh                         NUMERIC,
    import_status                      TEXT,
    export_status                      TEXT,
    import_valid_intervals             BIGINT,
    import_invalid_intervals           BIGINT,
    import_reconstructed_intervals     BIGINT,
    import_gap_intervals               BIGINT,
    import_reset_intervals             BIGINT,
    import_rollover_intervals          BIGINT,
    export_valid_intervals             BIGINT,
    export_invalid_intervals           BIGINT,
    export_reconstructed_intervals     BIGINT,
    export_gap_intervals               BIGINT,
    export_reset_intervals             BIGINT,
    export_rollover_intervals          BIGINT,
    expected_intervals                 BIGINT,
    import_assigned_expected_intervals BIGINT,
    export_assigned_expected_intervals BIGINT,
    import_data_state                  TEXT,
    export_data_state                  TEXT,
    is_partial                         BOOLEAN,
    unavailable_reasons                TEXT[],
    import_first_data_at               TIMESTAMPTZ,
    import_last_data_at                TIMESTAMPTZ,
    export_first_data_at               TIMESTAMPTZ,
    export_last_data_at                TIMESTAMPTZ,
    import_assigned_in_range           BOOLEAN,
    export_assigned_in_range           BOOLEAN,
    import_stale                       BOOLEAN,
    export_stale                       BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, admin, metadata, telemetry, config
AS $function$
DECLARE
    c_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    c_local_origin CONSTANT TIMESTAMP := TIMESTAMP '2000-01-01 00:00:00';
    c_status CONSTANT TEXT[] := ARRAY['INVALID_INTERVALS', 'RESET_DETECTED', 'GAPS_DETECTED',
                                      'RECONSTRUCTED_TIMING', 'ROLLOVER_DETECTED', 'GOOD'];
    v_now          TIMESTAMPTZ;
    v_org          UUID;
    v_tz           TEXT;
    v_width        INTERVAL;
    v_local        TIMESTAMP;
    v_grid_from    TIMESTAMPTZ;
    v_grid_to      TIMESTAMPTZ;
    v_hour_aligned BOOLEAN := TRUE;
    v_policy_from  TIMESTAMPTZ;
    v_capture      INTEGER;
    v_capture_n    INTEGER;
    v_policy_gap   BOOLEAN;
    v_raw_keep     INTERVAL;
    v_reasons      TEXT[] := ARRAY[]::TEXT[];
    v_c15          TIMESTAMPTZ;
    v_ch           TIMESTAMPTZ;
    v_cd           TIMESTAMPTZ;
    v_stage_1m     INTERVAL;
    v_stage_5m     INTERVAL;
    v_native_secs  INTEGER;
    v_asset        UUID;
    v_asset_reasons TEXT[];
    v_imp_devs     UUID[];
    v_exp_devs     UUID[];
    v_all_devs     UUID[];
    v_fine_from    TIMESTAMPTZ;
    v_imp_first    TIMESTAMPTZ;
    v_imp_last     TIMESTAMPTZ;
    v_exp_first    TIMESTAMPTZ;
    v_exp_last     TIMESTAMPTZ;
    v_imp_in_range BOOLEAN;
    v_exp_in_range BOOLEAN;
    v_imp_stale    BOOLEAN;
    v_exp_stale    BOOLEAN;
BEGIN
    IF p_resolution IS NULL OR p_resolution NOT IN ('1m', '15m', '30m', '1h', '1d') THEN
        RAISE EXCEPTION 'p_resolution must be one of 1m, 15m, 30m, 1h, 1d; got %', p_resolution
            USING ERRCODE = '22023';
    END IF;
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
        RAISE EXCEPTION 'p_from and p_to are required and p_to must be later than p_from'
            USING ERRCODE = '22023';
    END IF;
    v_now := COALESCE(p_as_of, now());

    IF NOT admin.portal_user_can_access_site(p_portal_user_id, p_site_id) THEN
        RETURN;
    END IF;

    SELECT s.organization_id, s.timezone INTO v_org, v_tz
    FROM metadata.sites AS s
    WHERE s.id = p_site_id;

    -- ------------------------------------------------------------------
    -- Grid. 1d: site-local days (unchanged). Otherwise the site-local
    -- bucket boundary at or before p_from, stepping by the width in
    -- absolute time (D24); identical to the UTC grid whenever the site's
    -- offset is a multiple of the width.
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
        v_hour_aligned := date_bin(INTERVAL '1 hour', v_grid_from, c_origin) = v_grid_from;
    END IF;

    -- ------------------------------------------------------------------
    -- Capture-policy consistency over the grid (unchanged gating; the
    -- reasons are no longer folded together).
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

    IF cardinality(v_reasons) = 0 AND p_resolution = '1m' THEN
        SELECT (j.config ->> 'drop_after')::INTERVAL INTO v_raw_keep
        FROM timescaledb_information.jobs AS j
        WHERE j.hypertable_schema = 'analytics'
          AND j.hypertable_name = 'energy_consumption_1min'
          AND j.proc_name = 'policy_retention'
        LIMIT 1;
        IF v_raw_keep IS NOT NULL AND v_grid_from < v_now - v_raw_keep THEN
            v_reasons := v_reasons || 'BEFORE_RETENTION_FLOOR'::TEXT;
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

    -- Migration 281: a persisted 15-minute row is used only when its whole
    -- bucket had ended at the (floored) checkpoint.
    IF isfinite(v_c15) THEN
        v_c15 := date_bin(INTERVAL '15 minutes', v_c15, c_origin);
    END IF;

    -- ------------------------------------------------------------------
    -- Stale: pipeline allowance per path from the live forward-stage job
    -- schedules (migration 302, D-020). NULL when any stage of a path is
    -- missing.
    -- ------------------------------------------------------------------
    v_stage_1m := analytics.energy_stale_pipeline_allowance(60);
    v_stage_5m := analytics.energy_stale_pipeline_allowance(300);

    -- Native resolution of the capture policy, for tier-derived last-data ends.
    v_native_secs := CASE WHEN COALESCE(v_capture, 60) <= 60 THEN 60 ELSE 300 END;

    FOR v_asset IN
        SELECT a.id
        FROM metadata.assets AS a
        WHERE a.id = ANY(p_asset_ids)
          AND a.site_id = p_site_id
          AND a.organization_id = v_org
          AND a.lifecycle_status = 'ACTIVE'
        ORDER BY a.id
    LOOP
        v_asset_reasons := v_reasons;

        SELECT array_agg(DISTINCT w.device_id) INTO v_imp_devs
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', v_grid_from, v_grid_to) AS w;
        SELECT array_agg(DISTINCT w.device_id) INTO v_exp_devs
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', v_grid_from, v_grid_to) AS w;
        SELECT array_agg(DISTINCT d) INTO v_all_devs
        FROM unnest(COALESCE(v_imp_devs, '{}') || COALESCE(v_exp_devs, '{}')) AS d;

        IF cardinality(v_asset_reasons) = 0 AND p_resolution = '1d' AND EXISTS (
            SELECT 1 FROM analytics.energy_consumption_daily AS d
            WHERE d.organization_id = v_org
              AND d.device_id = ANY(v_all_devs)
              AND d.bucket_start >= v_grid_from - INTERVAL '1 day'
              AND d.bucket_start < v_grid_to
              AND d.site_timezone IS DISTINCT FROM v_tz
        ) THEN
            v_asset_reasons := v_asset_reasons || 'TIMEZONE_MISMATCH'::TEXT;
        END IF;

        IF cardinality(v_asset_reasons) > 0 THEN
            RETURN QUERY SELECT v_asset, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::NUMERIC, NULL::NUMERIC,
                                NULL::TEXT, NULL::TEXT,
                                NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::BIGINT,
                                NULL::BIGINT, NULL::BIGINT, NULL::BIGINT, NULL::TEXT, NULL::TEXT,
                                NULL::BOOLEAN, v_asset_reasons,
                                NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ,
                                NULL::BOOLEAN, NULL::BOOLEAN, NULL::BOOLEAN, NULL::BOOLEAN;
            CONTINUE;
        END IF;

        -- --------------------------------------------------------------
        -- Series-level data bounds per direction: the first / last measured
        -- interval of the bound source(s) inside their binding windows
        -- (all history up to p_as_of), across the daily tier, the persisted
        -- 15-minute tier and the native rows. last is an END instant.
        -- --------------------------------------------------------------
        SELECT MIN(LEAST(
                   (SELECT d.first_source_bucket FROM analytics.energy_consumption_daily AS d
                    WHERE d.organization_id = v_org AND d.device_id = w.device_id
                      AND d.bucket_start >= w.window_from - INTERVAL '1 day' AND d.bucket_start < w.window_to
                      AND d.first_source_bucket >= w.window_from AND d.first_source_bucket < w.window_to
                    ORDER BY d.bucket_start LIMIT 1),
                   (SELECT p.first_source_bucket FROM analytics.energy_consumption_15min AS p
                    WHERE p.organization_id = v_org AND p.device_id = w.device_id
                      AND p.bucket_start >= w.window_from - INTERVAL '15 minutes' AND p.bucket_start < w.window_to
                      AND p.first_source_bucket >= w.window_from AND p.first_source_bucket < w.window_to
                    ORDER BY p.bucket_start LIMIT 1),
                   (SELECT n.bucket_start FROM analytics.v_energy_consumption_native AS n
                    WHERE n.organization_id = v_org AND n.device_id = w.device_id
                      AND n.bucket_start >= w.window_from AND n.bucket_start < w.window_to
                      AND n.is_measured_interval AND NOT n.import_is_interior
                    ORDER BY n.bucket_start LIMIT 1))),
               MAX(GREATEST(
                   (SELECT d.last_source_bucket + make_interval(secs => v_native_secs)
                    FROM analytics.energy_consumption_daily AS d
                    WHERE d.organization_id = v_org AND d.device_id = w.device_id
                      AND d.bucket_start < LEAST(w.window_to, v_now) AND d.bucket_start >= w.window_from - INTERVAL '1 day'
                      AND d.last_source_bucket >= w.window_from AND d.last_source_bucket < LEAST(w.window_to, v_now)
                    ORDER BY d.bucket_start DESC LIMIT 1),
                   (SELECT p.last_source_bucket + make_interval(secs => v_native_secs)
                    FROM analytics.energy_consumption_15min AS p
                    WHERE p.organization_id = v_org AND p.device_id = w.device_id
                      AND p.bucket_start < LEAST(w.window_to, v_now) AND p.bucket_start >= w.window_from - INTERVAL '15 minutes'
                      AND p.last_source_bucket >= w.window_from AND p.last_source_bucket < LEAST(w.window_to, v_now)
                    ORDER BY p.bucket_start DESC LIMIT 1),
                   (SELECT n.bucket_start + make_interval(secs => n.native_resolution_seconds)
                    FROM analytics.v_energy_consumption_native AS n
                    WHERE n.organization_id = v_org AND n.device_id = w.device_id
                      AND n.bucket_start >= w.window_from AND n.bucket_start < LEAST(w.window_to, v_now)
                      AND n.is_measured_interval AND NOT n.import_is_interior
                    ORDER BY n.bucket_start DESC LIMIT 1)))
        INTO v_imp_first, v_imp_last
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', '-infinity'::TIMESTAMPTZ, v_now) AS w;

        SELECT MIN(LEAST(
                   (SELECT d.first_source_bucket FROM analytics.energy_consumption_daily AS d
                    WHERE d.organization_id = v_org AND d.device_id = w.device_id
                      AND d.bucket_start >= w.window_from - INTERVAL '1 day' AND d.bucket_start < w.window_to
                      AND d.first_source_bucket >= w.window_from AND d.first_source_bucket < w.window_to
                    ORDER BY d.bucket_start LIMIT 1),
                   (SELECT p.first_source_bucket FROM analytics.energy_consumption_15min AS p
                    WHERE p.organization_id = v_org AND p.device_id = w.device_id
                      AND p.bucket_start >= w.window_from - INTERVAL '15 minutes' AND p.bucket_start < w.window_to
                      AND p.first_source_bucket >= w.window_from AND p.first_source_bucket < w.window_to
                    ORDER BY p.bucket_start LIMIT 1),
                   (SELECT n.bucket_start FROM analytics.v_energy_consumption_native AS n
                    WHERE n.organization_id = v_org AND n.device_id = w.device_id
                      AND n.bucket_start >= w.window_from AND n.bucket_start < w.window_to
                      AND n.is_measured_interval AND NOT n.export_is_interior
                    ORDER BY n.bucket_start LIMIT 1))),
               MAX(GREATEST(
                   (SELECT d.last_source_bucket + make_interval(secs => v_native_secs)
                    FROM analytics.energy_consumption_daily AS d
                    WHERE d.organization_id = v_org AND d.device_id = w.device_id
                      AND d.bucket_start < LEAST(w.window_to, v_now) AND d.bucket_start >= w.window_from - INTERVAL '1 day'
                      AND d.last_source_bucket >= w.window_from AND d.last_source_bucket < LEAST(w.window_to, v_now)
                    ORDER BY d.bucket_start DESC LIMIT 1),
                   (SELECT p.last_source_bucket + make_interval(secs => v_native_secs)
                    FROM analytics.energy_consumption_15min AS p
                    WHERE p.organization_id = v_org AND p.device_id = w.device_id
                      AND p.bucket_start < LEAST(w.window_to, v_now) AND p.bucket_start >= w.window_from - INTERVAL '15 minutes'
                      AND p.last_source_bucket >= w.window_from AND p.last_source_bucket < LEAST(w.window_to, v_now)
                    ORDER BY p.bucket_start DESC LIMIT 1),
                   (SELECT n.bucket_start + make_interval(secs => n.native_resolution_seconds)
                    FROM analytics.v_energy_consumption_native AS n
                    WHERE n.organization_id = v_org AND n.device_id = w.device_id
                      AND n.bucket_start >= w.window_from AND n.bucket_start < LEAST(w.window_to, v_now)
                      AND n.is_measured_interval AND NOT n.export_is_interior
                    ORDER BY n.bucket_start DESC LIMIT 1)))
        INTO v_exp_first, v_exp_last
        FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', '-infinity'::TIMESTAMPTZ, v_now) AS w;

        v_imp_in_range := EXISTS (
            SELECT 1 FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_IMPORT_TOTAL', p_from, p_to));
        v_exp_in_range := EXISTS (
            SELECT 1 FROM analytics.resolve_asset_energy_source_windows(v_asset, 'ENERGY_EXPORT_TOTAL', p_from, p_to));

        -- Stale per direction (capture policy in effect at last_data_at).
        SELECT CASE
                   WHEN v_imp_last IS NULL THEN FALSE
                   WHEN cap.policy_id IS NULL THEN NULL
                   WHEN (CASE WHEN cap.capture_interval_seconds <= 60 THEN v_stage_1m
                              WHEN cap.capture_interval_seconds = 300 THEN v_stage_5m END) IS NULL THEN NULL
                   ELSE v_imp_last > p_from AND v_imp_last < p_to
                        AND v_now - v_imp_last > thr.t
                        AND EXISTS (SELECT 1 FROM analytics.resolve_asset_energy_source_windows(
                                        v_asset, 'ENERGY_IMPORT_TOTAL', v_imp_last + thr.t, 'infinity'::TIMESTAMPTZ))
               END
        INTO v_imp_stale
        FROM (SELECT 1) AS one
        LEFT JOIN LATERAL telemetry.resolve_site_capture_bucket(p_site_id, v_imp_last - INTERVAL '1 second') AS cap ON TRUE
        LEFT JOIN LATERAL (
            SELECT make_interval(secs => cap.capture_interval_seconds + cap.late_arrival_tolerance_seconds)
                   + CASE WHEN cap.capture_interval_seconds <= 60 THEN v_stage_1m
                          WHEN cap.capture_interval_seconds = 300 THEN v_stage_5m END AS t
        ) AS thr ON TRUE;

        SELECT CASE
                   WHEN v_exp_last IS NULL THEN FALSE
                   WHEN cap.policy_id IS NULL THEN NULL
                   WHEN (CASE WHEN cap.capture_interval_seconds <= 60 THEN v_stage_1m
                              WHEN cap.capture_interval_seconds = 300 THEN v_stage_5m END) IS NULL THEN NULL
                   ELSE v_exp_last > p_from AND v_exp_last < p_to
                        AND v_now - v_exp_last > thr.t
                        AND EXISTS (SELECT 1 FROM analytics.resolve_asset_energy_source_windows(
                                        v_asset, 'ENERGY_EXPORT_TOTAL', v_exp_last + thr.t, 'infinity'::TIMESTAMPTZ))
               END
        INTO v_exp_stale
        FROM (SELECT 1) AS one
        LEFT JOIN LATERAL telemetry.resolve_site_capture_bucket(p_site_id, v_exp_last - INTERVAL '1 second') AS cap ON TRUE
        LEFT JOIN LATERAL (
            SELECT make_interval(secs => cap.capture_interval_seconds + cap.late_arrival_tolerance_seconds)
                   + CASE WHEN cap.capture_interval_seconds <= 60 THEN v_stage_1m
                          WHEN cap.capture_interval_seconds = 300 THEN v_stage_5m END AS t
        ) AS thr ON TRUE;

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
            dev_first AS (
                SELECT dv AS device_id,
                       LEAST((SELECT MIN(d.first_source_bucket) FROM analytics.energy_consumption_daily AS d
                              WHERE d.organization_id = v_org AND d.device_id = dv),
                             (SELECT p.first_source_bucket FROM analytics.energy_consumption_15min AS p
                              WHERE p.organization_id = v_org AND p.device_id = dv
                              ORDER BY p.bucket_start LIMIT 1),
                             (SELECT n.bucket_start FROM analytics.v_energy_consumption_native AS n
                              WHERE n.organization_id = v_org AND n.device_id = dv AND n.is_measured_interval
                              ORDER BY n.bucket_start LIMIT 1)) AS t
                FROM unnest(COALESCE(v_all_devs, '{}')) AS dv
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
                       (n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) IS TRUE AS v,
                       (NOT n.import_is_valid AND n.is_measured_interval AND NOT n.import_is_interior) IS TRUE AS iv,
                       (n.import_reconstruction_role IS NOT NULL) AS rc,
                       (n.import_quality_code = 'GAP' AND n.is_measured_interval) IS TRUE AS gp,
                       (n.import_reset_detected AND n.is_measured_interval) IS TRUE AS rs,
                       (n.import_rollover_detected AND n.is_measured_interval) IS TRUE AS ro
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
                       (n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) IS TRUE AS v,
                       (NOT n.export_is_valid AND n.is_measured_interval AND NOT n.export_is_interior) IS TRUE AS iv,
                       (n.export_reconstruction_role IS NOT NULL) AS rc,
                       (n.export_quality_code = 'GAP' AND n.is_measured_interval) IS TRUE AS gp,
                       (n.export_reset_detected AND n.is_measured_interval) IS TRUE AS rs,
                       (n.export_rollover_detected AND n.is_measured_interval) IS TRUE AS ro
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
                SELECT date_bin(v_width, i.b, v_grid_from) AS b, SUM(i.kwh) AS kwh,
                       MIN(array_position(c_status, i.st)) AS rnk,
                       COUNT(*) FILTER (WHERE i.v) AS v, COUNT(*) FILTER (WHERE i.iv) AS iv,
                       COUNT(*) FILTER (WHERE i.rc) AS rc, COUNT(*) FILTER (WHERE i.gp) AS gp,
                       COUNT(*) FILTER (WHERE i.rs) AS rs, COUNT(*) FILTER (WHERE i.ro) AS ro
                FROM imp AS i GROUP BY 1
            ),
            exp_c AS (
                SELECT date_bin(v_width, e.b, v_grid_from) AS b, SUM(e.kwh) AS kwh,
                       MIN(array_position(c_status, e.st)) AS rnk,
                       COUNT(*) FILTER (WHERE e.v) AS v, COUNT(*) FILTER (WHERE e.iv) AS iv,
                       COUNT(*) FILTER (WHERE e.rc) AS rc, COUNT(*) FILTER (WHERE e.gp) AS gp,
                       COUNT(*) FILTER (WHERE e.rs) AS rs, COUNT(*) FILTER (WHERE e.ro) AS ro
                FROM exp AS e GROUP BY 1
            ),
            grid AS (
                SELECT gs AS b_start, gs + v_width AS b_end
                FROM generate_series(v_grid_from, v_grid_to - v_width, v_width) AS gs
            ),
            q AS (
                SELECT g.b_start, g.b_end, i.kwh AS i_kwh, e.kwh AS e_kwh, i.rnk AS i_rnk, e.rnk AS e_rnk,
                       COALESCE(i.v, 0) AS i_v, COALESCE(i.iv, 0) AS i_iv, COALESCE(i.rc, 0) AS i_rc,
                       COALESCE(i.gp, 0) AS i_gp, COALESCE(i.rs, 0) AS i_rs, COALESCE(i.ro, 0) AS i_ro,
                       COALESCE(e.v, 0) AS e_v, COALESCE(e.iv, 0) AS e_iv, COALESCE(e.rc, 0) AS e_rc,
                       COALESCE(e.gp, 0) AS e_gp, COALESCE(e.rs, 0) AS e_rs, COALESCE(e.ro, 0) AS e_ro
                FROM grid AS g
                LEFT JOIN imp_c AS i ON i.b = g.b_start
                LEFT JOIN exp_c AS e ON e.b = g.b_start
            ),
            -- Migration 284: set-based Data Quality work (was per-bucket LATERAL subqueries).
            imp_first_ts AS (
                SELECT f.t FROM imp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
                WHERE f.t >= w.window_from AND f.t < w.window_to
            ),
            imp_cov AS (
                SELECT g.b_start,
                       SUM(CASE WHEN v_imp_first IS NOT NULL AND v_imp_last IS NOT NULL
                                 AND LEAST(g.b_end, w.window_to, v_imp_last, v_now) > GREATEST(g.b_start, w.window_from, v_imp_first)
                                THEN ceil(EXTRACT(EPOCH FROM LEAST(g.b_end, w.window_to, v_imp_last, v_now)) / v_capture)
                                   - ceil(EXTRACT(EPOCH FROM GREATEST(g.b_start, w.window_from, v_imp_first)) / v_capture)
                                ELSE 0 END)::BIGINT AS n
                FROM grid AS g
                JOIN imp_w AS w ON w.window_from < g.b_end AND w.window_to > g.b_start
                GROUP BY g.b_start
            ),
            imp_init AS (
                SELECT g.b_start, COUNT(*) AS n
                FROM grid AS g JOIN imp_first_ts AS f ON f.t >= g.b_start AND f.t < g.b_end
                GROUP BY g.b_start
            ),
            -- Migration 284: set-based Data Quality work (was per-bucket LATERAL subqueries).
            exp_first_ts AS (
                SELECT f.t FROM exp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
                WHERE f.t >= w.window_from AND f.t < w.window_to
            ),
            exp_cov AS (
                SELECT g.b_start,
                       SUM(CASE WHEN v_exp_first IS NOT NULL AND v_exp_last IS NOT NULL
                                 AND LEAST(g.b_end, w.window_to, v_exp_last, v_now) > GREATEST(g.b_start, w.window_from, v_exp_first)
                                THEN ceil(EXTRACT(EPOCH FROM LEAST(g.b_end, w.window_to, v_exp_last, v_now)) / v_capture)
                                   - ceil(EXTRACT(EPOCH FROM GREATEST(g.b_start, w.window_from, v_exp_first)) / v_capture)
                                ELSE 0 END)::BIGINT AS n
                FROM grid AS g
                JOIN exp_w AS w ON w.window_from < g.b_end AND w.window_to > g.b_start
                GROUP BY g.b_start
            ),
            exp_init AS (
                SELECT g.b_start, COUNT(*) AS n
                FROM grid AS g JOIN exp_first_ts AS f ON f.t >= g.b_start AND f.t < g.b_end
                GROUP BY g.b_start
            )
            SELECT v_asset, q.b_start, q.b_end, q.i_kwh, q.e_kwh, c_status[q.i_rnk], c_status[q.e_rnk],
                   q.i_v, GREATEST(q.i_iv - COALESCE(ii.n, 0), 0), q.i_rc, q.i_gp, q.i_rs, q.i_ro,
                   q.e_v, GREATEST(q.e_iv - COALESCE(ei.n, 0), 0), q.e_rc, q.e_gp, q.e_rs, q.e_ro,
                   (EXTRACT(EPOCH FROM (q.b_end - q.b_start)) / v_capture)::BIGINT,
                   CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(COALESCE(ia.n, 0) - COALESCE(ii.n, 0), 0) END,
                   CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(COALESCE(ea.n, 0) - COALESCE(ei.n, 0), 0) END,
                   CASE WHEN q.b_start > v_now THEN 'FUTURE'
                        WHEN ia.b_start IS NULL THEN 'NOT_ASSIGNED'
                        WHEN v_imp_first IS NULL OR q.b_end <= v_imp_first THEN 'BEFORE_DATA'
                        WHEN v_imp_last IS NULL OR q.b_start >= v_imp_last THEN 'AFTER_LATEST_DATA'
                        WHEN q.i_kwh IS NOT NULL THEN 'MEASURED'
                        ELSE 'GAP' END,
                   CASE WHEN q.b_start > v_now THEN 'FUTURE'
                        WHEN ea.b_start IS NULL THEN 'NOT_ASSIGNED'
                        WHEN v_exp_first IS NULL OR q.b_end <= v_exp_first THEN 'BEFORE_DATA'
                        WHEN v_exp_last IS NULL OR q.b_start >= v_exp_last THEN 'AFTER_LATEST_DATA'
                        WHEN q.e_kwh IS NOT NULL THEN 'MEASURED'
                        ELSE 'GAP' END,
                   q.b_end > v_now, NULL::TEXT[],
                   v_imp_first, v_imp_last, v_exp_first, v_exp_last,
                   v_imp_in_range, v_exp_in_range, v_imp_stale, v_exp_stale
            FROM q
            LEFT JOIN imp_init AS ii ON ii.b_start = q.b_start
            LEFT JOIN exp_init AS ei ON ei.b_start = q.b_start
            LEFT JOIN imp_cov AS ia ON ia.b_start = q.b_start
            LEFT JOIN exp_cov AS ea ON ea.b_start = q.b_start
            ORDER BY q.b_start;
            CONTINUE;
        END IF;

        -- --------------------------------------------------------------
        -- 15m / 30m / 1h / 1d. First, where 15-minute rows are needed:
        -- 15m/30m everywhere; 1h/1d only from the first bucket the coarse
        -- tier cannot serve (its checkpoint, or the earliest bucket a
        -- binding starts/ends inside); 1h on a site whose local hours are
        -- not UTC hours never uses the UTC hourly tier.
        -- --------------------------------------------------------------
        IF p_resolution IN ('15m', '30m') OR (p_resolution = '1h' AND NOT v_hour_aligned) THEN
            v_fine_from := v_grid_from;
        ELSE
            SELECT MIN(t) INTO v_fine_from
            FROM (
                SELECT CASE WHEN p_resolution = '1h' THEN date_bin(INTERVAL '1 hour', GREATEST(v_ch, v_grid_from), v_grid_from)
                            ELSE date_trunc('day', GREATEST(v_cd, v_grid_from) AT TIME ZONE v_tz) AT TIME ZONE v_tz END AS t
                UNION ALL
                SELECT CASE WHEN p_resolution = '1h' THEN date_bin(INTERVAL '1 hour', b.t, v_grid_from)
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
        dev_first AS (
            SELECT dv AS device_id,
                   LEAST((SELECT MIN(d.first_source_bucket) FROM analytics.energy_consumption_daily AS d
                          WHERE d.organization_id = v_org AND d.device_id = dv),
                         (SELECT p.first_source_bucket FROM analytics.energy_consumption_15min AS p
                          WHERE p.organization_id = v_org AND p.device_id = dv
                          ORDER BY p.bucket_start LIMIT 1),
                         (SELECT n.bucket_start FROM analytics.v_energy_consumption_native AS n
                          WHERE n.organization_id = v_org AND n.device_id = dv AND n.is_measured_interval
                          ORDER BY n.bucket_start LIMIT 1)) AS t
            FROM unnest(COALESCE(v_all_devs, '{}')) AS dv
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
            FROM analytics.energy_semantic_rollup_15min_range(v_org, v_all_devs, GREATEST(v_c15, v_fine_from), v_grid_to) AS r
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
                   s.valid_import_intervals AS v, s.invalid_import_intervals AS iv,
                   s.import_reconstructed_intervals AS rc, s.import_gap_intervals AS gp,
                   s.import_reset_intervals AS rs, s.import_rollover_intervals AS ro
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
                   s.valid_export_intervals AS v, s.invalid_export_intervals AS iv,
                   s.export_reconstructed_intervals AS rc, s.export_gap_intervals AS gp,
                   s.export_reset_intervals AS rs, s.export_rollover_intervals AS ro
            FROM src15 AS s
            JOIN exp_w AS w
              ON w.device_id = s.device_id
             AND s.bucket_start < w.window_to
             AND s.bucket_start + INTERVAL '15 minutes' > w.window_from
            ORDER BY s.bucket_start, w.window_from DESC
        ),
        -- Persisted coarse rows usable whole: processed by their pipeline and
        -- inside exactly one binding window of the direction. The UTC hourly
        -- tier only when the local hours are UTC hours.
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
              AND v_hour_aligned
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
                   c.valid_import_intervals AS v, c.invalid_import_intervals AS iv,
                   c.import_reconstructed_intervals AS rc, c.import_gap_intervals AS gp,
                   c.import_reset_intervals AS rs, c.import_rollover_intervals AS ro
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
                   c.valid_export_intervals AS v, c.invalid_export_intervals AS iv,
                   c.export_reconstructed_intervals AS rc, c.export_gap_intervals AS gp,
                   c.export_reset_intervals AS rs, c.export_rollover_intervals AS ro
            FROM coarse AS c
            JOIN exp_w AS w
              ON w.device_id = c.device_id AND w.window_from <= c.b AND c.e <= w.window_to
            WHERE (SELECT COUNT(*) FROM exp_w AS w2 WHERE w2.window_from < c.e AND w2.window_to > c.b) = 1
        ),
        -- Every grid bucket per direction: a usable persisted coarse row, or
        -- its attributed 15-minute rows summed.
        imp_c AS (
            SELECT ic.b, ic.kwh, ic.rnk, ic.v, ic.iv, ic.rc, ic.gp, ic.rs, ic.ro FROM imp_coarse AS ic
            UNION ALL
            SELECT k.b, SUM(k.kwh), MIN(array_position(c_status, k.st)),
                   SUM(k.v), SUM(k.iv), SUM(k.rc), SUM(k.gp), SUM(k.rs), SUM(k.ro)
            FROM (
                SELECT CASE WHEN p_resolution = '1d'
                            THEN (f.b AT TIME ZONE v_tz)::date::timestamp AT TIME ZONE v_tz
                            ELSE date_bin(v_width, f.b, v_grid_from) END AS b,
                       f.kwh, f.st, f.v, f.iv, f.rc, f.gp, f.rs, f.ro
                FROM imp15 AS f
            ) AS k
            WHERE NOT EXISTS (SELECT 1 FROM imp_coarse AS ic WHERE ic.b = k.b)
            GROUP BY k.b
        ),
        exp_c AS (
            SELECT ec.b, ec.kwh, ec.rnk, ec.v, ec.iv, ec.rc, ec.gp, ec.rs, ec.ro FROM exp_coarse AS ec
            UNION ALL
            SELECT k.b, SUM(k.kwh), MIN(array_position(c_status, k.st)),
                   SUM(k.v), SUM(k.iv), SUM(k.rc), SUM(k.gp), SUM(k.rs), SUM(k.ro)
            FROM (
                SELECT CASE WHEN p_resolution = '1d'
                            THEN (f.b AT TIME ZONE v_tz)::date::timestamp AT TIME ZONE v_tz
                            ELSE date_bin(v_width, f.b, v_grid_from) END AS b,
                       f.kwh, f.st, f.v, f.iv, f.rc, f.gp, f.rs, f.ro
                FROM exp15 AS f
            ) AS k
            WHERE NOT EXISTS (SELECT 1 FROM exp_coarse AS ec WHERE ec.b = k.b)
            GROUP BY k.b
        ),
        q AS (
            SELECT g.b_start, g.b_end, i.kwh AS i_kwh, e.kwh AS e_kwh, i.rnk AS i_rnk, e.rnk AS e_rnk,
                   COALESCE(i.v, 0)::BIGINT AS i_v, COALESCE(i.iv, 0)::BIGINT AS i_iv, COALESCE(i.rc, 0)::BIGINT AS i_rc,
                   COALESCE(i.gp, 0)::BIGINT AS i_gp, COALESCE(i.rs, 0)::BIGINT AS i_rs, COALESCE(i.ro, 0)::BIGINT AS i_ro,
                   COALESCE(e.v, 0)::BIGINT AS e_v, COALESCE(e.iv, 0)::BIGINT AS e_iv, COALESCE(e.rc, 0)::BIGINT AS e_rc,
                   COALESCE(e.gp, 0)::BIGINT AS e_gp, COALESCE(e.rs, 0)::BIGINT AS e_rs, COALESCE(e.ro, 0)::BIGINT AS e_ro
            FROM grid AS g
            LEFT JOIN imp_c AS i ON i.b = g.b_start
            LEFT JOIN exp_c AS e ON e.b = g.b_start
        ),
        -- Migration 284: set-based Data Quality work (was per-bucket LATERAL subqueries).
        imp_first_ts AS (
            SELECT f.t FROM imp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
            WHERE f.t >= w.window_from AND f.t < w.window_to
        ),
        imp_cov AS (
            SELECT g.b_start,
                   SUM(CASE WHEN v_imp_first IS NOT NULL AND v_imp_last IS NOT NULL
                             AND LEAST(g.b_end, w.window_to, v_imp_last, v_now) > GREATEST(g.b_start, w.window_from, v_imp_first)
                            THEN ceil(EXTRACT(EPOCH FROM LEAST(g.b_end, w.window_to, v_imp_last, v_now)) / v_capture)
                               - ceil(EXTRACT(EPOCH FROM GREATEST(g.b_start, w.window_from, v_imp_first)) / v_capture)
                            ELSE 0 END)::BIGINT AS n
            FROM grid AS g
            JOIN imp_w AS w ON w.window_from < g.b_end AND w.window_to > g.b_start
            GROUP BY g.b_start
        ),
        imp_init AS (
            SELECT g.b_start, COUNT(*) AS n
            FROM grid AS g JOIN imp_first_ts AS f ON f.t >= g.b_start AND f.t < g.b_end
            GROUP BY g.b_start
        ),
        -- Migration 284: set-based Data Quality work (was per-bucket LATERAL subqueries).
        exp_first_ts AS (
            SELECT f.t FROM exp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
            WHERE f.t >= w.window_from AND f.t < w.window_to
        ),
        exp_cov AS (
            SELECT g.b_start,
                   SUM(CASE WHEN v_exp_first IS NOT NULL AND v_exp_last IS NOT NULL
                             AND LEAST(g.b_end, w.window_to, v_exp_last, v_now) > GREATEST(g.b_start, w.window_from, v_exp_first)
                            THEN ceil(EXTRACT(EPOCH FROM LEAST(g.b_end, w.window_to, v_exp_last, v_now)) / v_capture)
                               - ceil(EXTRACT(EPOCH FROM GREATEST(g.b_start, w.window_from, v_exp_first)) / v_capture)
                            ELSE 0 END)::BIGINT AS n
            FROM grid AS g
            JOIN exp_w AS w ON w.window_from < g.b_end AND w.window_to > g.b_start
            GROUP BY g.b_start
        ),
        exp_init AS (
            SELECT g.b_start, COUNT(*) AS n
            FROM grid AS g JOIN exp_first_ts AS f ON f.t >= g.b_start AND f.t < g.b_end
            GROUP BY g.b_start
        )
        SELECT v_asset, q.b_start, q.b_end, q.i_kwh, q.e_kwh, c_status[q.i_rnk], c_status[q.e_rnk],
               q.i_v, GREATEST(q.i_iv - COALESCE(ii.n, 0), 0), q.i_rc, q.i_gp, q.i_rs, q.i_ro,
               q.e_v, GREATEST(q.e_iv - COALESCE(ei.n, 0), 0), q.e_rc, q.e_gp, q.e_rs, q.e_ro,
               (EXTRACT(EPOCH FROM (q.b_end - q.b_start)) / v_capture)::BIGINT,
               CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(COALESCE(ia.n, 0) - COALESCE(ii.n, 0), 0) END,
               CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(COALESCE(ea.n, 0) - COALESCE(ei.n, 0), 0) END,
               CASE WHEN q.b_start > v_now THEN 'FUTURE'
                    WHEN ia.b_start IS NULL THEN 'NOT_ASSIGNED'
                    WHEN v_imp_first IS NULL OR q.b_end <= v_imp_first THEN 'BEFORE_DATA'
                    WHEN v_imp_last IS NULL OR q.b_start >= v_imp_last THEN 'AFTER_LATEST_DATA'
                    WHEN q.i_kwh IS NOT NULL THEN 'MEASURED'
                    ELSE 'GAP' END,
               CASE WHEN q.b_start > v_now THEN 'FUTURE'
                    WHEN ea.b_start IS NULL THEN 'NOT_ASSIGNED'
                    WHEN v_exp_first IS NULL OR q.b_end <= v_exp_first THEN 'BEFORE_DATA'
                    WHEN v_exp_last IS NULL OR q.b_start >= v_exp_last THEN 'AFTER_LATEST_DATA'
                    WHEN q.e_kwh IS NOT NULL THEN 'MEASURED'
                    ELSE 'GAP' END,
               q.b_end > v_now, NULL::TEXT[],
               v_imp_first, v_imp_last, v_exp_first, v_exp_last,
               v_imp_in_range, v_exp_in_range, v_imp_stale, v_exp_stale
        FROM q
        LEFT JOIN imp_init AS ii ON ii.b_start = q.b_start
        LEFT JOIN exp_init AS ei ON ei.b_start = q.b_start
        LEFT JOIN imp_cov AS ia ON ia.b_start = q.b_start
        LEFT JOIN exp_cov AS ea ON ea.b_start = q.b_start
        ORDER BY q.b_start;
    END LOOP;
END;
$function$;

DO $post$
DECLARE
    v_sig   CONSTANT TEXT := 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)';
    v_def   TEXT;
    v_old   CONSTANT TEXT := $old$    -- ------------------------------------------------------------------
    -- Stale: live forward-stage schedules per path (read at query time).
    -- NULL when any stage of a path is missing.
    -- ------------------------------------------------------------------
    SELECT CASE WHEN COUNT(*) = 4 THEN SUM(st.si) + COALESCE(MAX(st.eo), INTERVAL '0') END
    INTO v_stage_1m
    FROM (
        SELECT j.proc_schema, j.proc_name, MAX(j.schedule_interval) AS si,
               MAX((j.config ->> 'end_offset')::INTERVAL) AS eo
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', 'run_energy_consumption_1min_job'))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate'
               AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_1min')
        GROUP BY j.proc_schema, j.proc_name
    ) AS st;

    SELECT CASE WHEN COUNT(*) = 4 THEN SUM(st.si) + COALESCE(MAX(st.eo), INTERVAL '0') END
    INTO v_stage_5m
    FROM (
        SELECT j.proc_schema, j.proc_name, MAX(j.schedule_interval) AS si,
               MAX((j.config ->> 'end_offset')::INTERVAL) AS eo
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', 'run_energy_consumption_5min_job'))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate'
               AND j.hypertable_schema = 'telemetry' AND j.hypertable_name = 'ca_energy_5min')
        GROUP BY j.proc_schema, j.proc_name
    ) AS st;
$old$;
    v_new   CONSTANT TEXT := $new$    -- ------------------------------------------------------------------
    -- Stale: pipeline allowance per path from the live forward-stage job
    -- schedules (migration 302, D-020). NULL when any stage of a path is
    -- missing.
    -- ------------------------------------------------------------------
    v_stage_1m := analytics.energy_stale_pipeline_allowance(60);
    v_stage_5m := analytics.energy_stale_pipeline_allowance(300);
$new$;
    v_1m    INTERVAL;
    v_5m    INTERVAL;
BEGIN
    v_def := pg_get_functiondef(v_sig::regprocedure);
    IF (length(v_def) - length(replace(v_def, v_new, ''))) / length(v_new) <> 1 THEN
        RAISE EXCEPTION 'Migration 302 postcondition failed: the helper calls are not present exactly once.';
    END IF;
    IF md5(replace(v_def, v_new, v_old)) <> '3f43cdae3e4dbb21087d31bc77c7bab0' THEN
        RAISE EXCEPTION 'Migration 302 postcondition failed: the series function differs from migration 284 outside the stale-allowance block.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = v_sig::regprocedure
          AND p.prosecdef AND p.provolatile = 's' AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 302 postcondition failed: the series function is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.';
    END IF;
    IF has_function_privilege('public', v_sig, 'EXECUTE')
       OR has_function_privilege('grafana_reader', v_sig, 'EXECUTE')
       OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 302 postcondition failed: the series function must remain executable by ems_app only.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
        WHERE p.oid = 'analytics.energy_stale_pipeline_allowance(integer)'::regprocedure
          AND l.lanname = 'sql' AND p.provolatile = 's' AND NOT p.prosecdef AND p.proconfig IS NULL
          AND r.rolname = 'ems_admin'
    ) OR has_function_privilege('public', 'analytics.energy_stale_pipeline_allowance(integer)', 'EXECUTE')
       OR has_function_privilege('ems_app', 'analytics.energy_stale_pipeline_allowance(integer)', 'EXECUTE')
       OR has_function_privilege('grafana_reader', 'analytics.energy_stale_pipeline_allowance(integer)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 302 postcondition failed: the helper must be LANGUAGE sql, STABLE, SECURITY INVOKER, without SET, owned by ems_admin, not executable by PUBLIC / ems_app / grafana_reader.';
    END IF;
    v_1m := analytics.energy_stale_pipeline_allowance(60);
    v_5m := analytics.energy_stale_pipeline_allowance(300);
    RAISE NOTICE 'Migration 302: all postconditions passed; pipeline allowance 1-minute path %, 5-minute path % (stale threshold = capture + tolerance + allowance).', v_1m, v_5m;
END;
$post$;
