-- ============================================================================
-- Migration 265
-- Analytical backbone M2 (stage 1 of 2): generic 1-hour point-telemetry tier
-- (analytics.point_telemetry_1h), built from analytics.point_telemetry_15m.
--
-- Decision record: docs/00-governance/decisions/ADR-019-analytical-backbone-
-- time-basis-and-tiers.md (M2 decisions of 2026-09-24).
--
-- TWO-STAGE ROLLOUT
--   265 (this file) creates everything with EVERY job UNSCHEDULED: the
--   forward job, the reconcile job, and the retention and compression
--   policies. Nothing writes to the table until an operator runs the bounded
--   backfill and the result is validated. Migration 266 (separate) activates
--   the jobs.
--
-- WHAT (additive only)
--   1. analytics.point_telemetry_1h -- hypertable (7-day chunks), UTC hour
--      grid enforced by CHECK, identity (organization_id, site_id, device_id,
--      logical_point_id, bucket_start) all NOT NULL with a plain unique index.
--      Values compose exactly from 15m: sum of sum_value, sum of sample_count,
--      min of min_value, max of max_value, and source_bucket_count = number of
--      contributing 15m buckets (1-4; source-coverage metadata for the
--      analytical read layer, not a customer-facing field). No asset_id, no
--      timezone column: storage is UTC; timezone is presentation-only.
--   2. analytics.point_telemetry_15m_watermark() -- the 15m materialization
--      watermark (UTC). An hour is closed for 1h purposes only once the 15m
--      watermark has reached its end.
--   3. analytics.refresh_point_telemetry_1h(p_from, p_to) -- bounded,
--      hour-aligned (max 7 days), never past the closed-15m watermark,
--      value-aware upsert (unchanged rows are not rewritten). It never
--      removes rows.
--   4. analytics.detect_point_telemetry_1h_deficits(...) -- read-only
--      detector: per coarse bucket, compares 15m-derived vs persisted 1h on
--      group count, total sample_count, total sum_value, MIN(min_value),
--      MAX(max_value) and total source_bucket_count.
--   5. analytics.run_point_telemetry_1h_job -- forward job (Energy hourly /
--      migration 217 pattern). The ONLY writer of
--      telemetry.pipeline_state('point_telemetry_1h').last_received_at.
--   6. analytics.reconcile_point_telemetry_1h -- bounded 35-day trailing
--      reconcile: repairs every mismatching coarse day (up to n_max per run)
--      by re-running the refresh, then re-checks it. A mismatch the upsert
--      cannot clear (a 1h row with no 15m source, or a 15m row with NULL
--      identity) is reported as FAILED; no row is ever removed.
--   7. analytics.backfill_point_telemetry_1h(p_from, p_to, p_slice) --
--      bounded, sliced, committed backfill (operator step between 265 and 266).
--   8. pipeline_state row 'point_telemetry_1h' (checkpoint NULL).
--   9. pipeline_reconciliation_log_tier_chk widened additively to accept
--      'point_telemetry_1h' (migration 230 precedent).
--  10. Policies: 1-year retention, compression after 30 days (segmentby
--      device_id, logical_point_id) -- both registered UNSCHEDULED.
--  11. Grants: table SELECT to ems_app, ems_readonly (not grafana_reader);
--      functions/procedures EXECUTE to ems_admin only.
--
-- INVARIANTS relied on
--   * telemetry.normalized_points is insert-only (only the retention policy
--     removes rows) and unique on (event_time, device_id, logical_point_id),
--     so a 15m group can only gain samples: any change raises sample_count,
--     and upserting from 15m is always sufficient to converge.
--   * Every read of analytics.point_telemetry_15m is bounded on bucket_start.
--
-- NOT in this migration
--   M1 (analytics.point_telemetry_15m and its jobs), the legacy Explorer
--   aggregates generic_telemetry_15m/_1h and get_grafana_explorer_intervals,
--   every Energy tier and job, telemetry.normalized_points, and
--   analytics.v_pipeline_health are untouched. Nothing is dropped or
--   unscheduled. No job is activated.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. Job-id sequence guard (migration 213): before any add_job /
--    add_retention_policy / add_compression_policy.
-- ----------------------------------------------------------------------------
DO $seqfix$
BEGIN
    IF to_regclass('_timescaledb_catalog.bgw_job_id_seq') IS NOT NULL THEN
        PERFORM setval(
            '_timescaledb_catalog.bgw_job_id_seq',
            GREATEST(
                (SELECT last_value FROM _timescaledb_catalog.bgw_job_id_seq),
                (SELECT COALESCE(max(id), 0) FROM _timescaledb_config.bgw_job)
            ),
            true
        );
    END IF;
END
$seqfix$;


-- ----------------------------------------------------------------------------
-- 1. Preconditions.
-- ----------------------------------------------------------------------------
DO $pre$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM _timescaledb_catalog.continuous_agg
        WHERE user_view_schema = 'analytics' AND user_view_name = 'point_telemetry_15m'
    ) THEN
        RAISE EXCEPTION 'Migration 265 precondition failed: analytics.point_telemetry_15m (migration 264) is missing.';
    END IF;

    IF to_regclass('analytics.point_telemetry_1h') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 265 precondition failed: analytics.point_telemetry_1h already exists.';
    END IF;

    IF to_regclass('analytics.pipeline_reconciliation_log') IS NULL
       OR to_regprocedure('analytics.record_reconciliation_run(uuid, text, timestamptz, timestamptz, timestamptz, integer, integer, bigint, bigint, integer, text, text, text)') IS NULL THEN
        RAISE EXCEPTION 'Migration 265 precondition failed: migration-213 reconciliation infrastructure is missing.';
    END IF;

    IF to_regprocedure('config.assert_analytical_lookback_job_config(jsonb)') IS NULL
       OR to_regprocedure('config.assert_reconciliation_job_config(jsonb)') IS NULL THEN
        RAISE EXCEPTION 'Migration 265 precondition failed: job config validators are missing.';
    END IF;

    IF EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = 'point_telemetry_1h') THEN
        RAISE EXCEPTION 'Migration 265 precondition failed: pipeline_state row point_telemetry_1h already exists.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Table.
-- ----------------------------------------------------------------------------
CREATE TABLE analytics.point_telemetry_1h
(
    bucket_start        TIMESTAMPTZ NOT NULL,

    organization_id     UUID        NOT NULL,
    site_id             UUID        NOT NULL,
    device_id           UUID        NOT NULL,
    logical_point_id    UUID        NOT NULL,

    sum_value           NUMERIC     NOT NULL,
    sample_count        BIGINT      NOT NULL,
    min_value           NUMERIC     NOT NULL,
    max_value           NUMERIC     NOT NULL,
    source_bucket_count SMALLINT    NOT NULL,

    calculated_at       TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT point_telemetry_1h_utc_hour_grid_chk
        CHECK (bucket_start = date_bin(INTERVAL '1 hour', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')),
    CONSTRAINT point_telemetry_1h_sample_count_chk
        CHECK (sample_count > 0),
    CONSTRAINT point_telemetry_1h_source_bucket_count_chk
        CHECK (source_bucket_count BETWEEN 1 AND 4),
    CONSTRAINT point_telemetry_1h_min_max_chk
        CHECK (min_value <= max_value)
);

SELECT create_hypertable
(
    'analytics.point_telemetry_1h',
    'bucket_start',
    chunk_time_interval => INTERVAL '7 days'
);

CREATE UNIQUE INDEX ux_point_telemetry_1h_identity
    ON analytics.point_telemetry_1h (device_id, logical_point_id, bucket_start, organization_id, site_id);

CREATE INDEX ix_point_telemetry_1h_site_bucket
    ON analytics.point_telemetry_1h (site_id, bucket_start DESC);

ALTER TABLE analytics.point_telemetry_1h SET
(
    timescaledb.compress,
    timescaledb.compress_segmentby = 'device_id, logical_point_id',
    timescaledb.compress_orderby   = 'bucket_start DESC, organization_id, site_id'
);

COMMENT ON TABLE analytics.point_telemetry_1h IS
'Analytical backbone M2 (migration 265, ADR-019): generic 1-hour point telemetry on the UTC hour grid, derived only from analytics.point_telemetry_15m (sum of sum_value, sum of sample_count, min of min_value, max of max_value; source_bucket_count = contributing 15m buckets). Keyed by organization/site/device/logical point (all NOT NULL), not asset: Asset attribution resolves at read time through metadata.asset_points. Not tenant-scoped: read only via tenant-scoped SECURITY DEFINER functions. Written only by analytics.refresh_point_telemetry_1h (forward job, reconcile, bounded backfill); rows are never removed except by the 1-year retention policy. Compressed after 30 days.';

COMMENT ON COLUMN analytics.point_telemetry_1h.bucket_start IS
'UTC hour start (date_bin 1 hour, origin 2000-01-01 00:00 UTC). For half-hour-offset sites this is HH:30 local; the grid is never re-bucketed to local hours (ADR-019 D3).';

COMMENT ON COLUMN analytics.point_telemetry_1h.sample_count IS
'Usable contributing measurements: sum of the GOOD numeric sample counts of the constituent 15m buckets. average = sum_value / sample_count at read time.';

COMMENT ON COLUMN analytics.point_telemetry_1h.source_bucket_count IS
'Number of constituent 15m buckets that had data (1-4). Source-coverage metadata for the analytical read layer (partial hours), not a customer-facing field.';


-- ----------------------------------------------------------------------------
-- 3. Retention and compression policies -- registered UNSCHEDULED (266
--    activates them together with the jobs).
-- ----------------------------------------------------------------------------
SELECT add_retention_policy('analytics.point_telemetry_1h', drop_after => INTERVAL '1 year');

SELECT add_compression_policy('analytics.point_telemetry_1h', compress_after => INTERVAL '30 days');

DO $unschedule_policies$
DECLARE
    v_job_id INTEGER;
BEGIN
    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE hypertable_schema = 'analytics'
          AND hypertable_name = 'point_telemetry_1h'
          AND proc_name IN ('policy_retention', 'policy_compression')
    LOOP
        PERFORM alter_job(v_job_id, scheduled => FALSE);
    END LOOP;
END
$unschedule_policies$;


-- ----------------------------------------------------------------------------
-- 4. 15m materialization watermark (UTC). NULL when nothing has been
--    materialized yet.
-- ----------------------------------------------------------------------------
CREATE FUNCTION analytics.point_telemetry_15m_watermark()
RETURNS TIMESTAMPTZ
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
    SELECT CASE
               WHEN w.watermark IS NULL THEN NULL
               WHEN _timescaledb_functions.to_timestamp(w.watermark) < TIMESTAMPTZ '2000-01-01 00:00:00+00' THEN NULL
               ELSE _timescaledb_functions.to_timestamp(w.watermark)
           END
    FROM _timescaledb_catalog.continuous_agg AS ca
    LEFT JOIN _timescaledb_catalog.continuous_aggs_watermark AS w
           ON w.mat_hypertable_id = ca.mat_hypertable_id
    WHERE ca.user_view_schema = 'analytics'
      AND ca.user_view_name = 'point_telemetry_15m';
$function$;

COMMENT ON FUNCTION analytics.point_telemetry_15m_watermark() IS
'Migration 265: materialization watermark of analytics.point_telemetry_15m (UTC; every 15m bucket before it has been materialized at least once). NULL if nothing has been materialized. The 1h tier only builds hours ending at or before this instant (floored to the UTC hour).';


-- ----------------------------------------------------------------------------
-- 5. Refresh (the only writer of the table).
-- ----------------------------------------------------------------------------
CREATE FUNCTION analytics.refresh_point_telemetry_1h
(
    p_from TIMESTAMPTZ,
    p_to   TIMESTAMPTZ
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_closed TIMESTAMPTZ;
    v_rows   BIGINT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'refresh_point_telemetry_1h: p_from and p_to are required (unbounded refresh is forbidden)'
            USING ERRCODE = '22023';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION 'refresh_point_telemetry_1h: p_to (%) must be later than p_from (%)', p_to, p_from
            USING ERRCODE = '22023';
    END IF;

    IF date_bin(INTERVAL '1 hour', p_from, v_origin) <> p_from
       OR date_bin(INTERVAL '1 hour', p_to, v_origin) <> p_to THEN
        RAISE EXCEPTION 'refresh_point_telemetry_1h: p_from (%) and p_to (%) must be aligned to the UTC hour grid', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    IF p_to - p_from > INTERVAL '7 days' THEN
        RAISE EXCEPTION 'refresh_point_telemetry_1h: window [%, %) exceeds 7 days', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    v_closed := date_bin(INTERVAL '1 hour', analytics.point_telemetry_15m_watermark(), v_origin);

    IF v_closed IS NULL OR p_to > v_closed THEN
        RAISE EXCEPTION 'refresh_point_telemetry_1h: p_to (%) is beyond the last closed hour of analytics.point_telemetry_15m (%)', p_to, v_closed
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO analytics.point_telemetry_1h AS t
    (
        bucket_start,
        organization_id,
        site_id,
        device_id,
        logical_point_id,
        sum_value,
        sample_count,
        min_value,
        max_value,
        source_bucket_count,
        calculated_at
    )
    SELECT
        date_bin(INTERVAL '1 hour', s.bucket_start, v_origin),
        s.organization_id,
        s.site_id,
        s.device_id,
        s.logical_point_id,
        sum(s.sum_value),
        sum(s.sample_count)::BIGINT,
        min(s.min_value),
        max(s.max_value),
        count(*)::SMALLINT,
        clock_timestamp()
    FROM analytics.point_telemetry_15m AS s
    WHERE s.bucket_start >= p_from
      AND s.bucket_start <  p_to
      -- The 1h identity is NOT NULL; a NULL-identity 15m row cannot be stored
      -- and is surfaced by the reconcile detector instead.
      AND s.organization_id IS NOT NULL
      AND s.site_id IS NOT NULL
    GROUP BY
        date_bin(INTERVAL '1 hour', s.bucket_start, v_origin),
        s.organization_id,
        s.site_id,
        s.device_id,
        s.logical_point_id
    ON CONFLICT (device_id, logical_point_id, bucket_start, organization_id, site_id)
    DO UPDATE SET
        sum_value           = EXCLUDED.sum_value,
        sample_count        = EXCLUDED.sample_count,
        min_value           = EXCLUDED.min_value,
        max_value           = EXCLUDED.max_value,
        source_bucket_count = EXCLUDED.source_bucket_count,
        calculated_at       = EXCLUDED.calculated_at
    WHERE (t.sum_value, t.sample_count, t.min_value, t.max_value, t.source_bucket_count)
          IS DISTINCT FROM
          (EXCLUDED.sum_value, EXCLUDED.sample_count, EXCLUDED.min_value, EXCLUDED.max_value, EXCLUDED.source_bucket_count);

    GET DIAGNOSTICS v_rows = ROW_COUNT;

    RETURN v_rows;
END;
$function$;

COMMENT ON FUNCTION analytics.refresh_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ) IS
'Migration 265: the only writer of analytics.point_telemetry_1h. Recomputes every UTC hour in [p_from, p_to) from analytics.point_telemetry_15m (bucket_start-bounded read) and upserts it; a row is written only when its values change. Requires explicit hour-aligned bounds, at most 7 days, ending no later than the last closed 15m hour. Never removes rows. Returns the number of rows inserted or changed.';


-- ----------------------------------------------------------------------------
-- 6. Read-only deficit detector.
-- ----------------------------------------------------------------------------
CREATE FUNCTION analytics.detect_point_telemetry_1h_deficits
(
    p_window_start TIMESTAMPTZ,
    p_window_end   TIMESTAMPTZ,
    p_coarse       INTERVAL,
    p_limit        INTEGER
)
RETURNS TABLE
(
    coarse_bucket_start TIMESTAMPTZ,
    source_groups       BIGINT,
    stored_groups       BIGINT,
    source_samples      NUMERIC,
    stored_samples      NUMERIC,
    source_sum          NUMERIC,
    stored_sum          NUMERIC,
    source_min          NUMERIC,
    stored_min          NUMERIC,
    source_max          NUMERIC,
    stored_max          NUMERIC,
    source_buckets      BIGINT,
    stored_buckets      BIGINT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $function$
DECLARE
    v_origin CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
BEGIN
    IF p_window_start IS NULL OR p_window_end IS NULL OR p_coarse IS NULL OR p_limit IS NULL THEN
        RAISE EXCEPTION 'detect_point_telemetry_1h_deficits: all arguments are required'
            USING ERRCODE = '22023';
    END IF;

    IF p_window_end <= p_window_start
       OR date_bin(INTERVAL '1 hour', p_window_start, v_origin) <> p_window_start
       OR date_bin(INTERVAL '1 hour', p_window_end, v_origin) <> p_window_end THEN
        RAISE EXCEPTION 'detect_point_telemetry_1h_deficits: window [%, %) must be non-empty and hour-aligned', p_window_start, p_window_end
            USING ERRCODE = '22023';
    END IF;

    IF p_coarse < INTERVAL '1 hour'
       OR mod(extract(epoch FROM p_coarse)::NUMERIC, 3600) <> 0
       OR p_limit <= 0 THEN
        RAISE EXCEPTION 'detect_point_telemetry_1h_deficits: p_coarse (%) must be a positive multiple of 1 hour and p_limit (%) positive', p_coarse, p_limit
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH source_hours AS (
        SELECT
            date_bin(INTERVAL '1 hour', s.bucket_start, v_origin) AS hour_start,
            s.organization_id,
            s.site_id,
            s.device_id,
            s.logical_point_id,
            sum(s.sample_count) AS n,
            sum(s.sum_value)    AS sv,
            min(s.min_value)    AS mn,
            max(s.max_value)    AS mx,
            count(*)            AS b
        FROM analytics.point_telemetry_15m AS s
        WHERE s.bucket_start >= p_window_start
          AND s.bucket_start <  p_window_end
        GROUP BY 1, 2, 3, 4, 5
    ),
    source_coarse AS (
        SELECT
            date_bin(p_coarse, sh.hour_start, v_origin) AS c,
            count(*)::BIGINT AS g,
            sum(sh.n)        AS n,
            sum(sh.sv)       AS sv,
            min(sh.mn)       AS mn,
            max(sh.mx)       AS mx,
            sum(sh.b)::BIGINT AS b
        FROM source_hours AS sh
        GROUP BY 1
    ),
    stored_coarse AS (
        SELECT
            date_bin(p_coarse, t.bucket_start, v_origin) AS c,
            count(*)::BIGINT                AS g,
            sum(t.sample_count)::NUMERIC    AS n,
            sum(t.sum_value)                AS sv,
            min(t.min_value)                AS mn,
            max(t.max_value)                AS mx,
            sum(t.source_bucket_count)::BIGINT AS b
        FROM analytics.point_telemetry_1h AS t
        WHERE t.bucket_start >= p_window_start
          AND t.bucket_start <  p_window_end
        GROUP BY 1
    )
    SELECT
        COALESCE(sc.c, st.c),
        sc.g,  st.g,
        sc.n,  st.n,
        sc.sv, st.sv,
        sc.mn, st.mn,
        sc.mx, st.mx,
        sc.b,  st.b
    FROM source_coarse AS sc
    FULL JOIN stored_coarse AS st
           ON st.c = sc.c
    WHERE (sc.g, sc.n, sc.sv, sc.mn, sc.mx, sc.b)
          IS DISTINCT FROM
          (st.g, st.n, st.sv, st.mn, st.mx, st.b)
    ORDER BY 1
    LIMIT p_limit;
END;
$function$;

COMMENT ON FUNCTION analytics.detect_point_telemetry_1h_deficits(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL, INTEGER) IS
'Migration 265: READ-ONLY deficit detector for analytics.point_telemetry_1h. For each coarse bucket in the hour-aligned [p_window_start, p_window_end), compares what the 15m tier implies (group count, total sample_count, total sum_value, MIN(min_value), MAX(max_value), total source_bucket_count) with what is stored in 1h, and returns the oldest p_limit coarse buckets that differ. Both reads are bounded on bucket_start. No writes, no pipeline_state access.';


-- ----------------------------------------------------------------------------
-- 7. Forward job.
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.run_point_telemetry_1h_job
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'point_telemetry_1h';
    v_origin        CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_lookback      INTERVAL := INTERVAL '2 days';
    v_max_catchup   INTERVAL := INTERVAL '2 days';
    v_overlap       INTERVAL := INTERVAL '2 hours';
    v_ckpt          TIMESTAMPTZ;
    v_parent        TIMESTAMPTZ;
    v_now_binned    TIMESTAMPTZ;
    v_start         TIMESTAMPTZ;
    v_to            TIMESTAMPTZ;
    v_from          TIMESTAMPTZ;
    v_rows          BIGINT := 0;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'point_telemetry_1h job config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)',
            v_lookback, v_max_catchup, v_overlap;
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended('analytics.run_point_telemetry_1h_job', 0)) THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline_name
    FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Everything on the UTC hour grid (migration 217 lesson): the parent is
    -- the closed-15m watermark floored to the hour, so an hour is built only
    -- after all four of its 15m buckets have been materialized; the current
    -- (in-progress) hour is always excluded.
    v_parent     := date_bin(INTERVAL '1 hour', analytics.point_telemetry_15m_watermark(), v_origin);
    v_now_binned := date_bin(INTERVAL '1 hour', clock_timestamp(), v_origin);
    v_start      := date_bin(INTERVAL '1 hour', COALESCE(v_ckpt, v_now_binned - v_lookback), v_origin);
    v_to         := date_bin(INTERVAL '1 hour', LEAST(v_now_binned, v_parent, v_start + v_max_catchup), v_origin);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := date_bin(INTERVAL '1 hour', v_start - v_overlap, v_origin);
    v_rows := analytics.refresh_point_telemetry_1h(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = 'SUCCESS',
        last_error         = NULL,
        updated_at         = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.run_point_telemetry_1h_job(INTEGER, JSONB) IS
'Migration 265: forward job for analytics.point_telemetry_1h (Energy hourly / migration 217 pattern). Advisory lock hashtextextended(''analytics.run_point_telemetry_1h_job'',0) -> SKIPPED_LOCKED. Window on the UTC hour grid: v_to = date_bin(1h, LEAST(current hour, closed-15m watermark hour, checkpoint + max_catchup_window)); v_from = checkpoint - overlap (default 2 hours, re-derives recent hours so ordinary late data is absorbed). The only writer of telemetry.pipeline_state(''point_telemetry_1h'').last_received_at, advanced to v_to on success. lookback (2 days) is the first-run floor only. Registered UNSCHEDULED by migration 265; activated by migration 266.';


-- ----------------------------------------------------------------------------
-- 8. Reconcile job (bounded, never writes pipeline_state, never removes rows).
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.reconcile_point_telemetry_1h
(
    job_id INTEGER,
    config JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, analytics
AS $procedure$
DECLARE
    v_pipeline    CONSTANT TEXT := 'point_telemetry_1h';
    v_fwd_lock    CONSTANT TEXT := 'analytics.run_point_telemetry_1h_job';
    v_origin      CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_rw          INTERVAL := INTERVAL '35 days';
    v_coarse      INTERVAL := INTERVAL '1 day';
    v_nmax        INTEGER  := 7;
    v_run         UUID := gen_random_uuid();
    v_started     TIMESTAMPTZ := clock_timestamp();
    v_cp          TIMESTAMPTZ;
    v_ws          TIMESTAMPTZ;
    v_from        TIMESTAMPTZ;
    v_to          TIMESTAMPTZ;
    v_examined    INTEGER := 0;
    v_mismatch    INTEGER := 0;
    v_rows_ex     BIGINT  := 0;
    v_repaired    BIGINT  := 0;
    v_errs        INTEGER := 0;
    v_sqlstate    TEXT;
    v_errmsg      TEXT;
    v_outcome     TEXT;
    r             RECORD;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw     := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'coarse'           THEN v_coarse := (config ->> 'coarse')::INTERVAL; END IF;
    IF config ? 'n_max'            THEN v_nmax   := (config ->> 'n_max')::INTEGER; END IF;

    IF v_rw > INTERVAL '35 days' THEN
        RAISE EXCEPTION 'point_telemetry_1h reconcile_window (%) must not exceed 35 days', v_rw;
    END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state
    WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := date_bin(INTERVAL '1 hour', v_cp - v_rw, v_origin);

    FOR r IN
        SELECT d.coarse_bucket_start, d.source_groups, d.stored_groups
        FROM analytics.detect_point_telemetry_1h_deficits(v_ws, v_cp, v_coarse, v_nmax + 1) AS d
    LOOP
        v_examined := v_examined + 1;

        IF v_examined > v_nmax THEN
            v_outcome := 'PARTIAL';
            EXIT;
        END IF;

        v_mismatch := v_mismatch + 1;
        v_rows_ex  := v_rows_ex + GREATEST(COALESCE(r.source_groups, 0), COALESCE(r.stored_groups, 0));
        v_from     := GREATEST(r.coarse_bucket_start, v_ws);
        v_to       := LEAST(r.coarse_bucket_start + v_coarse, v_cp);

        BEGIN
            v_repaired := v_repaired + analytics.refresh_point_telemetry_1h(v_from, v_to);

            -- Re-check: a difference the upsert cannot clear (a stored hour
            -- with no 15m source, or a NULL-identity 15m row) is reported, never
            -- resolved by removing rows.
            IF EXISTS (
                SELECT 1 FROM analytics.detect_point_telemetry_1h_deficits(v_from, v_to, v_coarse, 1)
            ) THEN
                v_errs := v_errs + 1;
                IF v_errmsg IS NULL THEN
                    v_sqlstate := 'P0001';
                    v_errmsg   := format(
                        'unrepairable point_telemetry_1h mismatch in [%s, %s): a stored hour without 15m source or a NULL-identity 15m row; rows are never removed by reconcile',
                        v_from, v_to);
                END IF;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            v_errs := v_errs + 1;
            IF v_errmsg IS NULL THEN
                v_sqlstate := SQLSTATE;
                v_errmsg   := left(SQLERRM, 1000);
            END IF;
            EXIT;
        END;
    END LOOP;

    v_outcome := COALESCE(
        CASE WHEN v_errs > 0 THEN 'FAILED' END,
        v_outcome,
        CASE WHEN v_mismatch > 0 THEN 'REPAIRED' ELSE 'HEALTHY' END);

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, v_examined, v_mismatch, v_rows_ex, v_repaired, v_errs,
        v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

COMMENT ON PROCEDURE analytics.reconcile_point_telemetry_1h(INTEGER, JSONB) IS
'Migration 265: bounded trailing reconciliation for analytics.point_telemetry_1h over [checkpoint - reconcile_window (35 days, capped at 35), checkpoint). Takes the forward job''s advisory lock (SKIPPED_LOCKED on contention); NO_CHECKPOINT while the forward checkpoint is NULL. Detector: analytics.detect_point_telemetry_1h_deficits per coarse bucket (1 day) comparing group count, total sample_count, total sum_value, MIN(min_value), MAX(max_value) and total source_bucket_count. Repairs up to n_max (7) mismatching coarse buckets per run with analytics.refresh_point_telemetry_1h, each in its own subtransaction, then re-checks; anything the upsert cannot clear is reported FAILED and no row is removed. Never writes telemetry.pipeline_state. Writes one analytics.pipeline_reconciliation_log row per run. Registered UNSCHEDULED by migration 265.';


-- ----------------------------------------------------------------------------
-- 9. Bounded backfill (operator step between 265 and 266). Commits per
--    slice, so: no SET clause, not SECURITY DEFINER, schema-qualified names,
--    top-level CALL only. Does not touch pipeline_state.
-- ----------------------------------------------------------------------------
CREATE PROCEDURE analytics.backfill_point_telemetry_1h
(
    p_from  TIMESTAMPTZ,
    p_to    TIMESTAMPTZ,
    p_slice INTERVAL DEFAULT INTERVAL '1 day'
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_origin      CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_closed      TIMESTAMPTZ;
    v_floor       TIMESTAMPTZ;
    v_slice_start TIMESTAMPTZ;
    v_slice_end   TIMESTAMPTZ;
    v_rows        BIGINT;
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_slice IS NULL THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_from, p_to and p_slice are required (unbounded refresh is forbidden)'
            USING ERRCODE = '22023';
    END IF;

    IF p_to <= p_from THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_to (%) must be later than p_from (%)', p_to, p_from
            USING ERRCODE = '22023';
    END IF;

    IF pg_catalog.date_bin(INTERVAL '1 hour', p_from, v_origin) <> p_from
       OR pg_catalog.date_bin(INTERVAL '1 hour', p_to, v_origin) <> p_to THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_from (%) and p_to (%) must be aligned to the UTC hour grid', p_from, p_to
            USING ERRCODE = '22023';
    END IF;

    IF p_slice < INTERVAL '1 hour'
       OR p_slice > INTERVAL '7 days'
       OR pg_catalog.mod(extract(epoch FROM p_slice)::NUMERIC, 3600) <> 0 THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_slice (%) must be a multiple of 1 hour between 1 hour and 7 days', p_slice
            USING ERRCODE = '22023';
    END IF;

    v_closed := pg_catalog.date_bin(INTERVAL '1 hour', analytics.point_telemetry_15m_watermark(), v_origin);

    IF v_closed IS NULL OR p_to > v_closed THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_to (%) is beyond the last closed hour of analytics.point_telemetry_15m (%)', p_to, v_closed
            USING ERRCODE = '22023';
    END IF;

    SELECT min(ch.range_start)
    INTO v_floor
    FROM timescaledb_information.continuous_aggregates AS ca
    JOIN timescaledb_information.chunks AS ch
      ON ch.hypertable_schema = ca.materialization_hypertable_schema
     AND ch.hypertable_name   = ca.materialization_hypertable_name
    WHERE ca.view_schema = 'analytics'
      AND ca.view_name = 'point_telemetry_15m';

    IF v_floor IS NULL OR p_from < v_floor THEN
        RAISE EXCEPTION 'backfill_point_telemetry_1h: p_from (%) precedes the oldest retained analytics.point_telemetry_15m chunk (%)', p_from, v_floor
            USING ERRCODE = '22023';
    END IF;

    v_slice_start := p_from;

    WHILE v_slice_start < p_to LOOP
        v_slice_end := LEAST(v_slice_start + p_slice, p_to);

        v_rows := analytics.refresh_point_telemetry_1h(v_slice_start, v_slice_end);

        COMMIT;

        RAISE NOTICE 'backfill_point_telemetry_1h: refreshed [%, %) rows=%', v_slice_start, v_slice_end, v_rows;

        v_slice_start := v_slice_end;
    END LOOP;
END;
$procedure$;

COMMENT ON PROCEDURE analytics.backfill_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) IS
'Migration 265: bounded 1h backfill from analytics.point_telemetry_15m. Requires explicit hour-aligned [p_from, p_to) ending no later than the last closed 15m hour and starting no earlier than the oldest retained 15m chunk; refreshes in p_slice slices (1 hour to 7 days, default 1 day) through analytics.refresh_point_telemetry_1h with a COMMIT after each. Does not touch telemetry.pipeline_state. Top-level CALL only.';


-- ----------------------------------------------------------------------------
-- 10. pipeline_state row (checkpoint NULL until the forward job first runs).
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES ('point_telemetry_1h')
ON CONFLICT (pipeline_name) DO NOTHING;


-- ----------------------------------------------------------------------------
-- 11. Widen the reconciliation-log tier CHECK (additive; migration 230
--     precedent). Every existing tier value stays valid.
-- ----------------------------------------------------------------------------
ALTER TABLE analytics.pipeline_reconciliation_log
    DROP CONSTRAINT IF EXISTS pipeline_reconciliation_log_tier_chk;

ALTER TABLE analytics.pipeline_reconciliation_log
    ADD CONSTRAINT pipeline_reconciliation_log_tier_chk CHECK (tier IN (
        'energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
        'energy_consumption_hourly', 'energy_consumption_daily', 'demand_intervals',
        'environment_daily',
        'derived_space_dew_point_1min',
        'point_telemetry_1h'));


-- ----------------------------------------------------------------------------
-- 12. Register the forward and reconcile jobs UNSCHEDULED.
-- ----------------------------------------------------------------------------
DO $jobs$
DECLARE
    v_origin    CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_fwd_start TIMESTAMPTZ := date_bin(INTERVAL '15 minutes', now(), v_origin) + INTERVAL '22 minutes';
    v_rec_start TIMESTAMPTZ := date_bin(INTERVAL '1 day', now(), v_origin) + INTERVAL '22 hours 30 minutes';
BEGIN
    -- Next 22:30 UTC (one hour after the 15m late-data policy at 21:30 UTC).
    IF v_rec_start <= now() THEN
        v_rec_start := v_rec_start + INTERVAL '1 day';
    END IF;

    PERFORM add_job(
        'analytics.run_point_telemetry_1h_job'::regproc,
        schedule_interval => INTERVAL '15 minutes',
        initial_start     => v_fwd_start,
        config            => jsonb_build_object(
                                 'lookback',           '2 days',
                                 'max_catchup_window', '2 days',
                                 'overlap',            '2 hours'),
        check_config      => 'config.assert_analytical_lookback_job_config'::regproc,
        scheduled         => FALSE,
        fixed_schedule    => TRUE
    );

    PERFORM add_job(
        'analytics.reconcile_point_telemetry_1h'::regproc,
        schedule_interval => INTERVAL '1 day',
        initial_start     => v_rec_start,
        config            => jsonb_build_object(
                                 'reconcile_window', '35 days',
                                 'coarse',           '1 day',
                                 'n_max',            7),
        check_config      => 'config.assert_reconciliation_job_config'::regproc,
        scheduled         => FALSE,
        fixed_schedule    => TRUE
    );

    PERFORM alter_job(j.job_id,
                      max_runtime  => CASE j.proc_name WHEN 'run_point_telemetry_1h_job' THEN INTERVAL '10 minutes' ELSE INTERVAL '30 minutes' END,
                      max_retries  => 3,
                      retry_period => CASE j.proc_name WHEN 'run_point_telemetry_1h_job' THEN INTERVAL '5 minutes' ELSE INTERVAL '30 minutes' END)
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema = 'analytics'
      AND j.proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h');
END
$jobs$;


-- ----------------------------------------------------------------------------
-- 13. Grants.
-- ----------------------------------------------------------------------------
REVOKE ALL ON analytics.point_telemetry_1h FROM PUBLIC;
GRANT SELECT ON analytics.point_telemetry_1h TO ems_app, ems_readonly;

REVOKE ALL ON FUNCTION analytics.point_telemetry_15m_watermark() FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.refresh_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION analytics.detect_point_telemetry_1h_deficits(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL, INTEGER) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.run_point_telemetry_1h_job(INTEGER, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.reconcile_point_telemetry_1h(INTEGER, JSONB) FROM PUBLIC;
REVOKE ALL ON PROCEDURE analytics.backfill_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION analytics.point_telemetry_15m_watermark() TO ems_admin;
GRANT EXECUTE ON FUNCTION analytics.refresh_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ) TO ems_admin;
GRANT EXECUTE ON FUNCTION analytics.detect_point_telemetry_1h_deficits(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL, INTEGER) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.run_point_telemetry_1h_job(INTEGER, JSONB) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.reconcile_point_telemetry_1h(INTEGER, JSONB) TO ems_admin;
GRANT EXECUTE ON PROCEDURE analytics.backfill_point_telemetry_1h(TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL) TO ems_admin;


-- ----------------------------------------------------------------------------
-- 14. Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_count INTEGER;
BEGIN
    -- Identity columns NOT NULL.
    SELECT count(*) INTO v_count
    FROM information_schema.columns
    WHERE table_schema = 'analytics' AND table_name = 'point_telemetry_1h'
      AND column_name IN ('bucket_start', 'organization_id', 'site_id', 'device_id', 'logical_point_id')
      AND is_nullable = 'NO';
    IF v_count <> 5 THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: identity columns must all be NOT NULL.';
    END IF;

    -- No asset / timezone columns.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'point_telemetry_1h'
          AND (column_name LIKE '%asset%' OR column_name LIKE '%timezone%' OR column_name LIKE '%local%')
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: unexpected asset/timezone/local column.';
    END IF;

    -- Plain unique index on the full identity.
    IF NOT EXISTS (
        SELECT 1 FROM pg_index AS i
        JOIN pg_class AS c ON c.oid = i.indexrelid
        WHERE c.relname = 'ux_point_telemetry_1h_identity'
          AND i.indisunique
          AND NOT i.indnullsnotdistinct
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: plain unique identity index missing.';
    END IF;

    -- Hypertable, 7-day chunks, compression enabled.
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.dimensions
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
          AND column_name = 'bucket_start' AND time_interval = INTERVAL '7 days'
    ) OR NOT EXISTS (
        SELECT 1 FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
          AND compression_enabled
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: hypertable / chunk interval / compression settings.';
    END IF;

    -- Every new job registered exactly once and UNSCHEDULED.
    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE NOT scheduled
      AND (
            (proc_schema = 'analytics' AND proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
         OR (hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
             AND proc_name IN ('policy_retention', 'policy_compression'))
          );
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: expected 4 unscheduled point_telemetry_1h jobs, found %.', v_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE scheduled
          AND ((proc_schema = 'analytics' AND proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
               OR (hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'))
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: a point_telemetry_1h job is scheduled.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE hypertable_name = 'point_telemetry_1h' AND proc_name = 'policy_retention'
          AND config ->> 'drop_after' = '1 year'
    ) OR NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE hypertable_name = 'point_telemetry_1h' AND proc_name = 'policy_compression'
          AND config ->> 'compress_after' = '30 days'
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: retention (1 year) / compression (30 days) policy config.';
    END IF;

    -- M1 jobs remain scheduled and unchanged in number.
    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_15m' AND scheduled;
    IF v_count <> 3 THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: expected the 3 M1 point_telemetry_15m jobs to stay scheduled, found %.', v_count;
    END IF;

    -- No routine removes rows.
    IF EXISTS (
        SELECT 1 FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics'
          AND p.proname IN ('refresh_point_telemetry_1h', 'detect_point_telemetry_1h_deficits',
                            'run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h',
                            'backfill_point_telemetry_1h', 'point_telemetry_15m_watermark')
          AND (p.prosrc ~* '\mdelete\s+from\M' OR p.prosrc ~* '\mtruncate\M' OR p.prosrc ~* 'refresh_continuous_aggregate')
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: a point_telemetry_1h routine removes rows or refreshes a continuous aggregate.';
    END IF;

    -- pipeline_state row seeded with a NULL checkpoint.
    IF NOT EXISTS (
        SELECT 1 FROM telemetry.pipeline_state
        WHERE pipeline_name = 'point_telemetry_1h' AND last_received_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: pipeline_state row point_telemetry_1h missing.';
    END IF;

    -- Grants.
    IF NOT has_table_privilege('ems_app', 'analytics.point_telemetry_1h', 'SELECT')
       OR NOT has_table_privilege('ems_readonly', 'analytics.point_telemetry_1h', 'SELECT')
       OR has_table_privilege('grafana_reader', 'analytics.point_telemetry_1h', 'SELECT')
       OR has_table_privilege('ems_app', 'analytics.point_telemetry_1h', 'INSERT') THEN
        RAISE EXCEPTION 'Migration 265 postcondition failed: unexpected grants on analytics.point_telemetry_1h.';
    END IF;

    RAISE NOTICE 'Migration 265: all postconditions passed (analytics.point_telemetry_1h created; forward/reconcile jobs and retention/compression policies registered UNSCHEDULED; M1/Explorer/Energy untouched).';
END
$post$;
