-- ============================================================================
-- Migration 282
-- Analytics v1 Data Quality read contract (ADR-022; Analytics Data Quality
-- decisions 1-22). Replaces analytics.get_portal_asset_energy_series
-- (migration 279, body as corrected by 281) and adds a site-aware variant of
-- analytics.get_analytics_energy_resolution_floors (migration 280).
--
-- Energy VALUES ARE UNCHANGED: every kWh is still the attributed register
-- delta from the same persisted tiers, the same semantic rollup tail, the
-- same checkpoint gating (including 281's floored 15-minute checkpoint) and
-- the same effective-dated asset_points attribution. What changes:
--
-- 1. Signature: a seventh argument p_as_of (the request's single "now");
--    every time-dependent output is evaluated at it. The 6-argument function
--    is dropped (its only caller is the Analytics API service, updated in
--    the same change).
--
-- 2. Site-local grid for 30m and 1h (decision D24 / Data Quality decision 3).
--    The grid starts at the site-local bucket boundary at or before p_from
--    (local wall clock, converted to UTC) and steps by the bucket width in
--    absolute time; 15-minute rows are binned from that origin. Every IANA
--    offset is a multiple of 15 minutes, so a local 30m/1h bucket is an exact
--    union of 15-minute rows. For 1m, 15m and 1d, and for 30m/1h on any site
--    whose offset is a multiple of the width, the grid is identical to
--    migration 281's. The persisted UTC hourly tier is used only when the
--    local hours coincide with UTC hours (v_hour_aligned); otherwise every
--    hour is summed from 15-minute rows. Known limitation: zones with a
--    30-minute DST shift (Australia/Lord_Howe) are not exact at the shift;
--    no such site exists (ADR-019 D2 blocks timezone edits once telemetry
--    exists).
--
-- 3. Per bucket and direction: valid / invalid / reconstructed / gap / reset /
--    rollover interval counts (summed, not ranked), assigned expected
--    intervals, and data_state (FUTURE / NOT_ASSIGNED / BEFORE_DATA /
--    AFTER_LATEST_DATA / MEASURED / GAP). The worst-status column is kept for
--    compatibility (same precedence as 281).
--    - The device's first-ever reading is INITIAL by construction (the
--      1-minute classifier has no predecessor register): it is removed from
--      both the invalid count and the expected intervals (decision 6). Its
--      instant is the device's earliest measured interval across the daily
--      tier (no retention), the persisted 15-minute tier and the native rows.
--    - Every other rejected interval stays invalid.
--
-- 4. Per asset and direction (repeated on each row): first/last data
--    instants, whether a binding overlaps the requested range, and stale.
--    first/last data are the first/last measured interval of the bound
--    source device(s) inside their binding windows, from the native rows,
--    the persisted 15-minute tier and the daily tier. The tiers carry
--    device-level first/last source buckets; with reconstruction OFF every
--    measured row is measured for both directions, so device-level equals
--    per-direction. Diverging per-direction bounds once ADR-020 writes
--    INTERIOR/synthetic rows are an ADR-020 prerequisite, not solved here.
--    stale (decisions 17, 18, 21):
--        as_of - last_data_at > capture_interval + late_arrival_tolerance
--                               (policy in effect at last_data_at)
--                             + live schedule_interval of each forward stage
--                               on the site's path + that path's CAGG end_offset
--      1-minute path (capture <= 60 s): telemetry.run_normalization_job,
--        telemetry.run_energy_routing_job, the ca_energy_1min refresh policy,
--        analytics.run_energy_consumption_1min_job;
--      5-minute path (capture = 300 s): the same with ca_energy_5min and
--        analytics.run_energy_consumption_5min_job.
--      Other capture intervals (900 s) are unverified: stale is NULL.
--      A stage's configured schedule_interval counts whether or not the job
--      is scheduled. No operator margin (migration 214), no pipeline
--      checkpoint, no cross-site MAX. Only the boolean is returned.
--      stale is also only true while last_data_at is inside the requested
--      range and a binding extends beyond last_data_at + threshold.
--
-- 5. Unavailable reasons are returned separately as an array:
--    CAPTURE_POLICY_GAP / CAPTURE_POLICY_CHANGE / CAPTURE_INTERVAL_TOO_COARSE
--    / BEFORE_RETENTION_FLOOR (1m raw retention) / TIMEZONE_MISMATCH. The
--    gating and precedence are migration 281's; 281 folded GAP into CHANGE
--    and TOO_COARSE / raw retention into RESOLUTION_UNAVAILABLE.
--
-- 6. analytics.get_analytics_energy_resolution_floors(p_site_id, p_as_of):
--    per resolution, the earliest instant its Energy source retains at
--    p_as_of; for 1h, the 15-minute floor when the site's local hours are not
--    UTC hours (local 1h is then built from 15-minute rows). The 0-argument
--    function from migration 280 is unchanged.
--
-- Not changed: analytics.get_canonical_energy_read, every Grafana object,
-- the Asset View reads, the persisted tiers, their jobs and retention,
-- telemetry.pipeline_state, metadata.asset_points (including staging
-- parity-bridge rows), energy reconstruction (still OFF). No data written.
--
-- Rollback: DROP the two functions created here and re-apply migration
-- 281's CREATE OR REPLACE FUNCTION (after re-creating the 6-argument
-- signature from migration 279).
-- ============================================================================

DO $pre$
DECLARE
    v_old TEXT := 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)';
BEGIN
    IF to_regprocedure(v_old) IS NULL THEN
        RAISE EXCEPTION 'Migration 282 precondition failed: % is missing (migrations 279/281).', v_old;
    END IF;
    IF md5(pg_get_functiondef(v_old::regprocedure)) <> '26a408f48786cb8b43fd5989d1595afa' THEN
        RAISE EXCEPTION 'Migration 282 precondition failed: % differs from the migration 281 definition.', v_old;
    END IF;
    IF to_regprocedure('analytics.get_analytics_energy_resolution_floors()') IS NULL THEN
        RAISE EXCEPTION 'Migration 282 precondition failed: analytics.get_analytics_energy_resolution_floors() is missing (migration 280).';
    END IF;
    IF to_regprocedure('telemetry.resolve_site_capture_bucket(uuid, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 282 precondition failed: telemetry.resolve_site_capture_bucket is missing.';
    END IF;
END;
$pre$;

DROP FUNCTION analytics.get_portal_asset_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT);

CREATE FUNCTION analytics.get_portal_asset_energy_series
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
            )
            SELECT v_asset, q.b_start, q.b_end, q.i_kwh, q.e_kwh, c_status[q.i_rnk], c_status[q.e_rnk],
                   q.i_v, GREATEST(q.i_iv - ii.n, 0), q.i_rc, q.i_gp, q.i_rs, q.i_ro,
                   q.e_v, GREATEST(q.e_iv - ei.n, 0), q.e_rc, q.e_gp, q.e_rs, q.e_ro,
                   (EXTRACT(EPOCH FROM (q.b_end - q.b_start)) / v_capture)::BIGINT,
                   CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(ia.n - ii.n, 0) END,
                   CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(ea.n - ei.n, 0) END,
                   CASE WHEN q.b_start > v_now THEN 'FUTURE'
                        WHEN NOT EXISTS (SELECT 1 FROM imp_w AS w WHERE w.window_from < q.b_end AND w.window_to > q.b_start) THEN 'NOT_ASSIGNED'
                        WHEN v_imp_first IS NULL OR q.b_end <= v_imp_first THEN 'BEFORE_DATA'
                        WHEN v_imp_last IS NULL OR q.b_start >= v_imp_last THEN 'AFTER_LATEST_DATA'
                        WHEN q.i_kwh IS NOT NULL THEN 'MEASURED'
                        ELSE 'GAP' END,
                   CASE WHEN q.b_start > v_now THEN 'FUTURE'
                        WHEN NOT EXISTS (SELECT 1 FROM exp_w AS w WHERE w.window_from < q.b_end AND w.window_to > q.b_start) THEN 'NOT_ASSIGNED'
                        WHEN v_exp_first IS NULL OR q.b_end <= v_exp_first THEN 'BEFORE_DATA'
                        WHEN v_exp_last IS NULL OR q.b_start >= v_exp_last THEN 'AFTER_LATEST_DATA'
                        WHEN q.e_kwh IS NOT NULL THEN 'MEASURED'
                        ELSE 'GAP' END,
                   q.b_end > v_now, NULL::TEXT[],
                   v_imp_first, v_imp_last, v_exp_first, v_exp_last,
                   v_imp_in_range, v_exp_in_range, v_imp_stale, v_exp_stale
            FROM q
            CROSS JOIN LATERAL (
                SELECT COUNT(*) AS n FROM imp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
                WHERE f.t >= w.window_from AND f.t < w.window_to AND f.t >= q.b_start AND f.t < q.b_end
            ) AS ii
            CROSS JOIN LATERAL (
                SELECT COUNT(*) AS n FROM exp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
                WHERE f.t >= w.window_from AND f.t < w.window_to AND f.t >= q.b_start AND f.t < q.b_end
            ) AS ei
            CROSS JOIN LATERAL (
                SELECT COALESCE(SUM(CASE WHEN x.hi > x.lo
                                         THEN ceil(EXTRACT(EPOCH FROM x.hi) / v_capture) - ceil(EXTRACT(EPOCH FROM x.lo) / v_capture)
                                         ELSE 0 END), 0)::BIGINT AS n
                FROM (SELECT GREATEST(q.b_start, w.window_from, v_imp_first) AS lo,
                             LEAST(q.b_end, w.window_to, v_imp_last, v_now) AS hi
                      FROM imp_w AS w
                      WHERE v_imp_first IS NOT NULL AND v_imp_last IS NOT NULL) AS x
            ) AS ia
            CROSS JOIN LATERAL (
                SELECT COALESCE(SUM(CASE WHEN x.hi > x.lo
                                         THEN ceil(EXTRACT(EPOCH FROM x.hi) / v_capture) - ceil(EXTRACT(EPOCH FROM x.lo) / v_capture)
                                         ELSE 0 END), 0)::BIGINT AS n
                FROM (SELECT GREATEST(q.b_start, w.window_from, v_exp_first) AS lo,
                             LEAST(q.b_end, w.window_to, v_exp_last, v_now) AS hi
                      FROM exp_w AS w
                      WHERE v_exp_first IS NOT NULL AND v_exp_last IS NOT NULL) AS x
            ) AS ea
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
        )
        SELECT v_asset, q.b_start, q.b_end, q.i_kwh, q.e_kwh, c_status[q.i_rnk], c_status[q.e_rnk],
               q.i_v, GREATEST(q.i_iv - ii.n, 0), q.i_rc, q.i_gp, q.i_rs, q.i_ro,
               q.e_v, GREATEST(q.e_iv - ei.n, 0), q.e_rc, q.e_gp, q.e_rs, q.e_ro,
               (EXTRACT(EPOCH FROM (q.b_end - q.b_start)) / v_capture)::BIGINT,
               CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(ia.n - ii.n, 0) END,
               CASE WHEN v_capture IS NULL THEN NULL ELSE GREATEST(ea.n - ei.n, 0) END,
               CASE WHEN q.b_start > v_now THEN 'FUTURE'
                    WHEN NOT EXISTS (SELECT 1 FROM imp_w AS w WHERE w.window_from < q.b_end AND w.window_to > q.b_start) THEN 'NOT_ASSIGNED'
                    WHEN v_imp_first IS NULL OR q.b_end <= v_imp_first THEN 'BEFORE_DATA'
                    WHEN v_imp_last IS NULL OR q.b_start >= v_imp_last THEN 'AFTER_LATEST_DATA'
                    WHEN q.i_kwh IS NOT NULL THEN 'MEASURED'
                    ELSE 'GAP' END,
               CASE WHEN q.b_start > v_now THEN 'FUTURE'
                    WHEN NOT EXISTS (SELECT 1 FROM exp_w AS w WHERE w.window_from < q.b_end AND w.window_to > q.b_start) THEN 'NOT_ASSIGNED'
                    WHEN v_exp_first IS NULL OR q.b_end <= v_exp_first THEN 'BEFORE_DATA'
                    WHEN v_exp_last IS NULL OR q.b_start >= v_exp_last THEN 'AFTER_LATEST_DATA'
                    WHEN q.e_kwh IS NOT NULL THEN 'MEASURED'
                    ELSE 'GAP' END,
               q.b_end > v_now, NULL::TEXT[],
               v_imp_first, v_imp_last, v_exp_first, v_exp_last,
               v_imp_in_range, v_exp_in_range, v_imp_stale, v_exp_stale
        FROM q
        CROSS JOIN LATERAL (
            SELECT COUNT(*) AS n FROM imp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
            WHERE f.t >= w.window_from AND f.t < w.window_to AND f.t >= q.b_start AND f.t < q.b_end
        ) AS ii
        CROSS JOIN LATERAL (
            SELECT COUNT(*) AS n FROM exp_w AS w JOIN dev_first AS f ON f.device_id = w.device_id
            WHERE f.t >= w.window_from AND f.t < w.window_to AND f.t >= q.b_start AND f.t < q.b_end
        ) AS ei
        CROSS JOIN LATERAL (
            SELECT COALESCE(SUM(CASE WHEN x.hi > x.lo
                                     THEN ceil(EXTRACT(EPOCH FROM x.hi) / v_capture) - ceil(EXTRACT(EPOCH FROM x.lo) / v_capture)
                                     ELSE 0 END), 0)::BIGINT AS n
            FROM (SELECT GREATEST(q.b_start, w.window_from, v_imp_first) AS lo,
                         LEAST(q.b_end, w.window_to, v_imp_last, v_now) AS hi
                  FROM imp_w AS w
                  WHERE v_imp_first IS NOT NULL AND v_imp_last IS NOT NULL) AS x
        ) AS ia
        CROSS JOIN LATERAL (
            SELECT COALESCE(SUM(CASE WHEN x.hi > x.lo
                                     THEN ceil(EXTRACT(EPOCH FROM x.hi) / v_capture) - ceil(EXTRACT(EPOCH FROM x.lo) / v_capture)
                                     ELSE 0 END), 0)::BIGINT AS n
            FROM (SELECT GREATEST(q.b_start, w.window_from, v_exp_first) AS lo,
                         LEAST(q.b_end, w.window_to, v_exp_last, v_now) AS hi
                  FROM exp_w AS w
                  WHERE v_exp_first IS NOT NULL AND v_exp_last IS NOT NULL) AS x
        ) AS ea
        ORDER BY q.b_start;
    END LOOP;
END;
$function$;

ALTER FUNCTION analytics.get_portal_asset_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_portal_asset_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_portal_asset_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) TO ems_app;

COMMENT ON FUNCTION analytics.get_portal_asset_energy_series(BIGINT, UUID, UUID[], TIMESTAMPTZ, TIMESTAMPTZ, TEXT, TIMESTAMPTZ) IS
'Analytics v1 asset Energy series with the Data Quality contract (migration 282; values as migration 279/281): portal/organization scoped, never keyed on the Grafana organization mapping. Site-local 30m/1h grid (D24); per-direction interval counts, assigned expected intervals, data state, first/last data bounds, binding-in-range and stale, all evaluated at p_as_of. Read-only.';

-- ----------------------------------------------------------------------------
-- Site-aware retention floors (the 0-argument function from 280 is kept).
-- ----------------------------------------------------------------------------
CREATE FUNCTION analytics.get_analytics_energy_resolution_floors(p_site_id UUID, p_as_of TIMESTAMPTZ)
RETURNS TABLE
(
    resolution         TEXT,
    earliest_available TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO pg_catalog, analytics, metadata
AS $function$
    WITH sources (resolution, table_name) AS (
        VALUES ('1m', 'energy_consumption_1min'),
               ('15m', 'energy_consumption_15min'),
               ('30m', 'energy_consumption_15min'),
               ('1h', 'energy_consumption_hourly'),
               ('1d', 'energy_consumption_daily')
    ),
    floors AS (
        SELECT s.resolution,
               COALESCE(p_as_of, now()) - (
                   SELECT (j.config ->> 'drop_after')::INTERVAL
                   FROM timescaledb_information.jobs AS j
                   WHERE j.hypertable_schema = 'analytics'
                     AND j.hypertable_name = s.table_name
                     AND j.proc_name = 'policy_retention'
                   LIMIT 1
               ) AS floor_at
        FROM sources AS s
    ),
    -- Local hours are UTC hours when the site's UTC offset is a whole number
    -- of hours now and half a year earlier (covers both sides of any DST).
    site_hours AS (
        SELECT COALESCE(bool_and(EXTRACT(MINUTE FROM (x.t AT TIME ZONE st.timezone) - (x.t AT TIME ZONE 'UTC')) = 0), TRUE) AS aligned
        FROM metadata.sites AS st
        CROSS JOIN (VALUES (COALESCE(p_as_of, now())), (COALESCE(p_as_of, now()) - INTERVAL '6 months')) AS x(t)
        WHERE st.id = p_site_id
    )
    SELECT f.resolution,
           CASE WHEN f.resolution = '1h' AND NOT (SELECT aligned FROM site_hours)
                THEN (SELECT f15.floor_at FROM floors AS f15 WHERE f15.resolution = '15m')
                ELSE f.floor_at END
    FROM floors AS f;
$function$;

ALTER FUNCTION analytics.get_analytics_energy_resolution_floors(UUID, TIMESTAMPTZ) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.get_analytics_energy_resolution_floors(UUID, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION analytics.get_analytics_energy_resolution_floors(UUID, TIMESTAMPTZ) TO ems_app;

COMMENT ON FUNCTION analytics.get_analytics_energy_resolution_floors(UUID, TIMESTAMPTZ) IS
'Analytics v1 (migration 282): per resolution, the earliest instant its Energy source retains at p_as_of (live retention policies); for 1h, the 15-minute floor when the site''s local hours are not UTC hours (local 1h is then built from 15-minute rows).';

DO $post$
DECLARE
    v_sig    TEXT;
    v_def    TEXT;
BEGIN
    IF to_regprocedure('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 282 postcondition failed: the 6-argument series function still exists.';
    END IF;
    FOREACH v_sig IN ARRAY ARRAY[
        'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)',
        'analytics.get_analytics_energy_resolution_floors(uuid, timestamptz)'
    ] LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_proc p
            JOIN pg_roles r ON r.oid = p.proowner
            WHERE p.oid = v_sig::regprocedure
              AND p.prosecdef
              AND p.provolatile = 's'
              AND r.rolname = 'ems_admin'
              AND p.proconfig IS NOT NULL
        ) THEN
            RAISE EXCEPTION 'Migration 282 postcondition failed: % is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.', v_sig;
        END IF;
        IF has_function_privilege('public', v_sig, 'EXECUTE')
           OR has_function_privilege('grafana_reader', v_sig, 'EXECUTE')
           OR NOT has_function_privilege('ems_app', v_sig, 'EXECUTE') THEN
            RAISE EXCEPTION 'Migration 282 postcondition failed: % must be executable by ems_app only.', v_sig;
        END IF;
        v_def := lower(pg_get_functiondef(v_sig::regprocedure));
        IF v_def ~ '(grafana_organization_map|get_canonical_energy_read|v_energy_reporting|primary_meter|insert into|update |delete from)' THEN
            RAISE EXCEPTION 'Migration 282 postcondition failed: % references a forbidden object or writes.', v_sig;
        END IF;
    END LOOP;
    IF to_regprocedure('analytics.get_analytics_energy_resolution_floors()') IS NULL THEN
        RAISE EXCEPTION 'Migration 282 postcondition failed: the migration 280 floors function must remain.';
    END IF;
    RAISE NOTICE 'Migration 282: all postconditions passed.';
END;
$post$;
