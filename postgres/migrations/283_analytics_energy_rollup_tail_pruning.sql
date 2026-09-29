-- ============================================================================
-- Migration 283
-- Analytics read latency, Option 1: prune the 15-minute rollup-tail read.
--
-- Found by the 2026-09-29 staging investigation of migration 282 (read-only):
-- in analytics.get_portal_asset_energy_series the fresh 15-minute tail (buckets
-- newer than the floored 15-minute checkpoint) is read from
-- analytics.v_energy_semantic_rollup_15min with a filter on the view's grouped
-- bucket_start. The planner pushes that filter down as a condition on the
-- date_bin(...) grouping expression, which neither prunes chunks nor uses a
-- bucket_start range, so every chunk of the device's native 1-minute/5-minute
-- rows was scanned by device_id alone (cold cache: 0.6-1.6 s per asset, to
-- produce about one row). The pattern is unchanged since migration 279.
--
-- Change (read layer only):
-- 1. New analytics.energy_semantic_rollup_15min_range(p_org, p_device_ids,
--    p_from, p_to), RETURNS SETOF analytics.v_energy_semantic_rollup_15min.
--    Its body is the view's current definition (pg_get_viewdef) verbatim, with
--    one WHERE added to the grouping CTE that restricts the native rows to the
--    organization, the devices and [p_from, p_to) widened to whole buckets of
--    the UTC 15-minute grid (the view's own grid). Because only whole buckets
--    are aggregated, every returned row is identical to the view's row for that
--    bucket. LANGUAGE sql, STABLE, SECURITY INVOKER and no SET, so it can be
--    inlined; not executable by PUBLIC, ems_app or grafana_reader (only the
--    definer series function, owned by ems_admin, calls it).
-- 2. analytics.get_portal_asset_energy_series (same 7-argument signature,
--    return type, owner, SECURITY DEFINER, search_path and grants): its body is
--    migration 282's with exactly one line changed -- the rollup-tail FROM now
--    calls the helper with (organization, devices, GREATEST(v_c15, v_fine_from),
--    v_grid_to). The existing WHERE on organization, devices and bucket_start is
--    kept, so the rows used are exactly those the view returned.
--
-- Not changed: the view itself, the persisted tiers, their refresh jobs,
-- retention, indexes, configuration, get_canonical_energy_read, every Grafana
-- object, the Asset View, metadata.asset_points, energy reconstruction (OFF),
-- and every Data Quality output of migration 282.
--
-- Rollback: re-apply migration 282's function body (CREATE OR REPLACE), then
-- DROP FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz).
-- ============================================================================

DO $pre$
BEGIN
    IF to_regprocedure('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)') IS NULL THEN
        RAISE EXCEPTION 'Migration 283 precondition failed: the migration 282 series function is missing.';
    END IF;
    IF md5(pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure)) <> '4d3ead0684b9b75938126020455d15d3' THEN
        RAISE EXCEPTION 'Migration 283 precondition failed: the series function differs from the migration 282 definition.';
    END IF;
    IF md5(pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass)) <> '7a79ad575ed8e50d3b2300e946a23dd2' THEN
        RAISE EXCEPTION 'Migration 283 precondition failed: analytics.v_energy_semantic_rollup_15min differs from the definition this helper copies.';
    END IF;
    IF to_regprocedure('analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 283 precondition failed: the helper already exists.';
    END IF;
END;
$pre$;

CREATE FUNCTION analytics.energy_semantic_rollup_15min_range
(
    p_org        UUID,
    p_device_ids UUID[],
    p_from       TIMESTAMPTZ,
    p_to         TIMESTAMPTZ
)
RETURNS SETOF analytics.v_energy_semantic_rollup_15min
LANGUAGE sql
STABLE
AS $function$ WITH grouped AS (
         SELECT date_bin('00:15:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone) AS bucket_start,
            n.organization_id,
            n.site_id,
            n.device_id,
            count(*) FILTER (WHERE n.is_measured_interval) AS source_interval_count,
            sum(n.source_sample_count) AS source_sample_count,
            count(*) FILTER (WHERE (n.import_is_valid AND n.is_measured_interval AND (NOT n.import_is_interior))) AS valid_import_intervals,
            count(*) FILTER (WHERE ((NOT n.import_is_valid) AND n.is_measured_interval AND (NOT n.import_is_interior))) AS invalid_import_intervals,
            count(*) FILTER (WHERE (n.export_is_valid AND n.is_measured_interval AND (NOT n.export_is_interior))) AS valid_export_intervals,
            count(*) FILTER (WHERE ((NOT n.export_is_valid) AND n.is_measured_interval AND (NOT n.export_is_interior))) AS invalid_export_intervals,
            count(*) FILTER (WHERE ((n.import_quality_code = 'GAP'::text) AND n.is_measured_interval)) AS import_gap_intervals,
            count(*) FILTER (WHERE ((n.export_quality_code = 'GAP'::text) AND n.is_measured_interval)) AS export_gap_intervals,
            count(*) FILTER (WHERE (n.import_reset_detected AND n.is_measured_interval)) AS import_reset_intervals,
            count(*) FILTER (WHERE (n.export_reset_detected AND n.is_measured_interval)) AS export_reset_intervals,
            count(*) FILTER (WHERE (n.import_rollover_detected AND n.is_measured_interval)) AS import_rollover_intervals,
            count(*) FILTER (WHERE (n.export_rollover_detected AND n.is_measured_interval)) AS export_rollover_intervals,
            sum(n.import_consumption_wh) FILTER (WHERE n.import_is_valid) AS import_consumption_wh,
            sum(n.import_consumption_kwh) FILTER (WHERE n.import_is_valid) AS import_consumption_kwh,
            sum(n.export_consumption_wh) FILTER (WHERE n.export_is_valid) AS export_consumption_wh,
            sum(n.export_consumption_kwh) FILTER (WHERE n.export_is_valid) AS export_consumption_kwh,
            min(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS first_native_bucket_start,
            max(n.bucket_start) FILTER (WHERE n.is_measured_interval) AS last_native_bucket_start,
            (array_agg(n.previous_bucket_start ORDER BY n.bucket_start) FILTER (WHERE n.is_measured_interval))[1] AS first_previous_bucket_start,
            (array_agg(n.previous_import_register_wh ORDER BY n.bucket_start) FILTER (WHERE (n.is_measured_interval AND (NOT n.import_is_interior))))[1] AS previous_import_register_wh,
            (array_agg(n.import_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE (n.is_measured_interval AND (NOT n.import_is_interior))))[1] AS import_register_wh,
            (array_agg(n.previous_export_register_wh ORDER BY n.bucket_start) FILTER (WHERE (n.is_measured_interval AND (NOT n.export_is_interior))))[1] AS previous_export_register_wh,
            (array_agg(n.export_register_wh ORDER BY n.bucket_start DESC) FILTER (WHERE (n.is_measured_interval AND (NOT n.export_is_interior))))[1] AS export_register_wh,
            array_agg(DISTINCT n.import_quality_code ORDER BY n.import_quality_code) FILTER (WHERE n.is_measured_interval) AS import_quality_codes,
            array_agg(DISTINCT n.export_quality_code ORDER BY n.export_quality_code) FILTER (WHERE n.is_measured_interval) AS export_quality_codes,
            min(n.native_resolution_seconds) AS minimum_native_resolution_seconds,
            max(n.native_resolution_seconds) AS maximum_native_resolution_seconds,
            count(*) FILTER (WHERE (n.gap_detected AND n.is_measured_interval)) AS gap_interval_count,
            count(*) FILTER (WHERE (n.reset_detected AND n.is_measured_interval)) AS reset_interval_count,
            count(*) FILTER (WHERE (n.rollover_detected AND n.is_measured_interval)) AS rollover_interval_count,
            count(*) FILTER (WHERE (n.invalid_detected AND n.is_measured_interval)) AS invalid_interval_count,
            count(*) FILTER (WHERE n.is_reconstructed) AS reconstructed_interval_count,
            count(*) FILTER (WHERE (n.import_reconstruction_role IS NOT NULL)) AS import_reconstructed_intervals,
            count(*) FILTER (WHERE (n.export_reconstruction_role IS NOT NULL)) AS export_reconstructed_intervals,
            COALESCE(sum(n.import_consumption_wh) FILTER (WHERE (n.import_is_valid AND (n.import_reconstruction_role IS NOT NULL))), (0)::numeric) AS import_reconstructed_wh,
            COALESCE(sum(n.import_consumption_kwh) FILTER (WHERE (n.import_is_valid AND (n.import_reconstruction_role IS NOT NULL))), (0)::numeric) AS import_reconstructed_kwh,
            COALESCE(sum(n.export_consumption_wh) FILTER (WHERE (n.export_is_valid AND (n.export_reconstruction_role IS NOT NULL))), (0)::numeric) AS export_reconstructed_wh,
            COALESCE(sum(n.export_consumption_kwh) FILTER (WHERE (n.export_is_valid AND (n.export_reconstruction_role IS NOT NULL))), (0)::numeric) AS export_reconstructed_kwh
           FROM analytics.v_energy_consumption_native n
          WHERE n.organization_id = p_org
            AND n.device_id = ANY (p_device_ids)
            AND p_from < p_to
            AND n.bucket_start >= CASE WHEN isfinite(p_from)
                THEN date_bin('00:15:00'::interval, p_from, '2000-01-01 00:00:00+00'::timestamp with time zone)
                ELSE p_from END
            AND n.bucket_start < CASE WHEN isfinite(p_to)
                THEN date_bin('00:15:00'::interval, p_to - '00:00:00.000001'::interval, '2000-01-01 00:00:00+00'::timestamp with time zone) + '00:15:00'::interval
                ELSE p_to END
          GROUP BY (date_bin('00:15:00'::interval, n.bucket_start, '2000-01-01 05:30:00+05:30'::timestamp with time zone)), n.organization_id, n.site_id, n.device_id
        )
 SELECT bucket_start,
    organization_id,
    site_id,
    device_id,
    source_interval_count,
    source_sample_count,
    valid_import_intervals,
    invalid_import_intervals,
    valid_export_intervals,
    invalid_export_intervals,
    import_gap_intervals,
    export_gap_intervals,
    import_reset_intervals,
    export_reset_intervals,
    import_rollover_intervals,
    export_rollover_intervals,
    import_consumption_wh,
    import_consumption_kwh,
    export_consumption_wh,
    export_consumption_kwh,
    first_native_bucket_start,
    last_native_bucket_start,
    first_previous_bucket_start,
    previous_import_register_wh,
    import_register_wh,
    previous_export_register_wh,
    export_register_wh,
    import_quality_codes,
    export_quality_codes,
    minimum_native_resolution_seconds,
    maximum_native_resolution_seconds,
        CASE
            WHEN (invalid_interval_count > 0) THEN 'INVALID_INTERVALS'::text
            WHEN (reset_interval_count > 0) THEN 'RESET_DETECTED'::text
            WHEN (gap_interval_count > 0) THEN 'GAPS_DETECTED'::text
            WHEN (reconstructed_interval_count > 0) THEN 'RECONSTRUCTED_TIMING'::text
            WHEN (rollover_interval_count > 0) THEN 'ROLLOVER_DETECTED'::text
            ELSE 'GOOD'::text
        END AS quality_status,
    gap_interval_count,
    reset_interval_count,
    rollover_interval_count,
    invalid_interval_count,
    reconstructed_interval_count,
    import_reconstructed_intervals,
    export_reconstructed_intervals,
    import_reconstructed_wh,
    import_reconstructed_kwh,
    export_reconstructed_wh,
    export_reconstructed_kwh
   FROM grouped g;$function$;

ALTER FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) OWNER TO ems_admin;
REVOKE ALL ON FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) FROM ems_app;
REVOKE ALL ON FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) FROM grafana_reader;

COMMENT ON FUNCTION analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz) IS
'Migration 283: analytics.v_energy_semantic_rollup_15min (verbatim definition) restricted, before grouping, to one organization, the given devices and [p_from, p_to) widened to whole UTC 15-minute buckets, so chunk exclusion applies. Rows are identical to the view''s. Internal helper for analytics.get_portal_asset_energy_series; not granted.';

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

DO $post$
DECLARE
    v_where  TEXT := E'\n          WHERE n.organization_id = p_org\n            AND n.device_id = ANY (p_device_ids)\n            AND p_from < p_to\n            AND n.bucket_start >= CASE WHEN isfinite(p_from)\n                THEN date_bin(''00:15:00''::interval, p_from, ''2000-01-01 00:00:00+00''::timestamp with time zone)\n                ELSE p_from END\n            AND n.bucket_start < CASE WHEN isfinite(p_to)\n                THEN date_bin(''00:15:00''::interval, p_to - ''00:00:00.000001''::interval, ''2000-01-01 00:00:00+00''::timestamp with time zone) + ''00:15:00''::interval\n                ELSE p_to END';
    v_old    TEXT := E'            FROM analytics.v_energy_semantic_rollup_15min AS r';
    v_new    TEXT := E'            FROM analytics.energy_semantic_rollup_15min_range(v_org, v_all_devs, GREATEST(v_c15, v_fine_from), v_grid_to) AS r';
    v_def    TEXT;
BEGIN
    -- Helper: exactly the view's definition plus the one WHERE.
    IF replace((SELECT prosrc FROM pg_proc WHERE oid = 'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)'::regprocedure), v_where, '')
       <> pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass) THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the helper is not the view definition plus the bounded WHERE.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner JOIN pg_language l ON l.oid = p.prolang
        WHERE p.oid = 'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)'::regprocedure
          AND NOT p.prosecdef AND p.provolatile = 's' AND p.proconfig IS NULL
          AND l.lanname = 'sql' AND r.rolname = 'ems_admin'
    ) THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the helper must be LANGUAGE sql, STABLE, SECURITY INVOKER, without SET, owned by ems_admin.';
    END IF;
    IF has_function_privilege('public', 'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)', 'EXECUTE')
       OR has_function_privilege('ems_app', 'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)', 'EXECUTE')
       OR has_function_privilege('grafana_reader', 'analytics.energy_semantic_rollup_15min_range(uuid, uuid[], timestamptz, timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the helper must not be executable by PUBLIC, ems_app or grafana_reader.';
    END IF;

    -- Series function: migration 282's body with exactly the one line changed.
    v_def := pg_get_functiondef('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure);
    IF position(v_new IN v_def) = 0 OR position(v_old IN v_def) > 0 THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the rollup-tail line was not replaced.';
    END IF;
    IF md5(replace(v_def, v_new, v_old)) <> '4d3ead0684b9b75938126020455d15d3' THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the series function changed outside the rollup-tail line.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
        WHERE p.oid = 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)'::regprocedure
          AND p.prosecdef AND p.provolatile = 's' AND r.rolname = 'ems_admin' AND p.proconfig IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the series function is not SECURITY DEFINER / STABLE / owned by ems_admin / search_path-pinned.';
    END IF;
    IF has_function_privilege('public', 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)', 'EXECUTE')
       OR has_function_privilege('grafana_reader', 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)', 'EXECUTE')
       OR NOT has_function_privilege('ems_app', 'analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)', 'EXECUTE') THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the series function must remain executable by ems_app only.';
    END IF;
    IF md5(pg_get_viewdef('analytics.v_energy_semantic_rollup_15min'::regclass)) <> '7a79ad575ed8e50d3b2300e946a23dd2' THEN
        RAISE EXCEPTION 'Migration 283 postcondition failed: the rollup view changed.';
    END IF;
    RAISE NOTICE 'Migration 283: all postconditions passed (helper = view + bounded WHERE; series function = 282 + one line).';
END;
$post$;
