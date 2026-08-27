-- ============================================================================
-- Migration 209
-- Phase 2 Foundation, Phase 1 (part 1 of 4): child-watermark cascade for the
-- persisted energy-consumption analytical tiers.
--
--   telemetry.ca_energy_1min  (CAGG) -> analytics.energy_consumption_1min
--   telemetry.ca_energy_5min  (CAGG) -> analytics.energy_consumption_5min
--   analytics.energy_consumption_1min UNION _5min
--     -> analytics.v_energy_consumption_native
--     -> analytics.v_energy_semantic_rollup_15min
--     -> analytics.energy_consumption_15min
--        -> analytics.energy_consumption_hourly   (reads energy_consumption_15min)
--        -> analytics.energy_consumption_daily    (reads energy_consumption_15min)
--
-- Root cause (Phase 1 Implementation-Readiness Audit): every one of the five
-- run_energy_consumption_*_job wrappers derives its processing window as
-- now() - <fixed lookback>. After an upstream outage/burst the child's window
-- is anchored to wall-clock time, not to what its parent has actually made
-- available, so historical source data that lands outside the fixed window is
-- permanently missed. Migrations 207/208 stopped the routing stall and made
-- these jobs safe to run (advisory lock, pipeline_state, finite runtime), but
-- did NOT change the window semantics.
--
-- This migration replaces the window derivation in the five wrappers with a
-- parent-availability + child-checkpoint + bounded-catch-up model, reusing the
-- migration-205 bounded pattern and the migration-208 pipeline_state rows.
-- It does NOT change any refresh_energy_consumption_* calculation function, any
-- schema, retention, compression, CAGG policy, Grafana object, or the routing/
-- normalization pipeline. It does NOT implement reconciliation (migration 212)
-- -- but it stores the per-tier reconcile_window in job config now so 212 can
-- consume it without re-touching the jobs.
--
-- WATERMARK CONTRACT (identical for all five tiers):
--   v_ckpt   = telemetry.pipeline_state(<child>).last_received_at   -- SELECT ... FOR UPDATE
--   v_parent = <parent_available_through>, read at execution time:
--                1min  : analytics.cagg_available_through('telemetry.ca_energy_1min')
--                5min  : analytics.cagg_available_through('telemetry.ca_energy_5min')
--                15min : LEAST( cp('energy_consumption_1min'), cp('energy_consumption_5min') )   -- LEAST skips NULL
--                hourly: cp('energy_consumption_15min')
--                daily : cp('energy_consumption_15min')
--   v_now_binned = the SAME now-binned expression each wrapper used before 209
--                  (date_trunc('minute'/'hour') / date_bin(5m/15m) / clock_timestamp() for daily)
--   v_start  = COALESCE(v_ckpt, v_now_binned - v_lookback)     -- v_lookback = FIRST-RUN FLOOR only
--   v_to     = LEAST(v_now_binned, v_parent, v_start + v_max_catchup_window)
--   IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start:
--        no forward work is available -> record NO_SOURCE_DATA (or SUCCESS if
--        v_to = v_ckpt), DO NOT advance last_received_at, RETURN.
--   v_from   = v_start - v_overlap
--   v_rows   = analytics.refresh_energy_consumption_<tier>(v_from, v_to)   -- UNCHANGED calc fn
--   -- the checkpoint advance is the LAST write of the run's single transaction:
--   UPDATE telemetry.pipeline_state
--     SET last_received_at = v_to,
--         last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END, ...
--   -- EXCEPTION WHEN OTHERS -> last_status='FAILED', RAISE
--     => the TimescaleDB job runner aborts the whole job transaction (the
--        advance, the refresh writes, RUNNING and FAILED all roll back), so a
--        failed / cancelled / timed-out run leaves last_received_at exactly at
--        its pre-run value. There is one transaction per run and no
--        intermediate COMMIT (approved readiness-audit item R7).
--
-- parent_available_through is NEVER stored in the child's checkpoint. It is
-- read live from the immediate parent each run. A child can never advance past
-- it (v_to <= v_parent by construction). A CAGG watermark being ahead of real
-- data during an upstream stall (readiness-audit finding C3) is handled by the
-- per-tier reconcile_window (= that CAGG's start_offset), stored here and
-- applied by migration 212.
--
-- EMPTY 5-MINUTE TIER: analytics.energy_consumption_5min is empty by design for
-- the current fleet (refresh_energy_consumption_5min only processes
-- capture_interval_seconds=300 sites; the fleet is 60). But telemetry.ca_energy_5min
-- (the CAGG) does contain data (60s rows bucketed into 5-minute buckets), so
-- cagg_available_through('telemetry.ca_energy_5min') advances normally, the 5min
-- wrapper's v_to advances, refresh_energy_consumption_5min returns 0 rows,
-- last_status='NO_SOURCE_DATA', and last_received_at STILL advances to v_to (an
-- empty-but-successfully-processed interval advances the checkpoint). So
-- cp('energy_consumption_5min') tracks the CAGG watermark and never blocks the
-- 15-minute LEAST(). If a 300s site is added later the same wrapper starts
-- producing rows with no further change.
--
-- Migration-208 scaffolding preserved verbatim in every wrapper: the
-- pg_try_advisory_xact_lock self-overlap guard (-> SKIPPED_LOCKED + RETURN),
-- the RUNNING transition, the EXCEPTION -> FAILED -> RAISE handler, SECURITY
-- DEFINER / search_path, owner ems_admin, and job schedule_interval /
-- max_runtime / max_retries / retry_period (unchanged; only config gains
-- max_catchup_window / overlap / reconcile_window keys).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. CAGG materialization-watermark helper (the platform's first).
--    Catalog lookup only -- no scan of the underlying energy hypertable, no
--    per-row work. Returns the point through which the continuous aggregate
--    has been MATERIALIZED (refresh watermark), NOT proof that every
--    underlying source bucket in that range contains data. Returns NULL when
--    the CAGG has never materialized anything (brand-new deployment / empty
--    source hypertable): TimescaleDB stores a BC-era sentinel there, which
--    this function maps to NULL so callers get one clean "not available yet"
--    signal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION analytics.cagg_available_through(p_cagg regclass)
RETURNS timestamptz
LANGUAGE sql
STABLE
AS $fn$
    SELECT NULLIF(
             _timescaledb_functions.to_timestamp(w.watermark),
             '4714-11-24 00:00:00+00 BC'::timestamptz
           )
    FROM _timescaledb_catalog.continuous_agg ca
    JOIN _timescaledb_catalog.continuous_aggs_watermark w
      ON w.mat_hypertable_id = ca.mat_hypertable_id
    WHERE format('%I.%I', ca.user_view_schema, ca.user_view_name)::regclass = p_cagg;
$fn$;

ALTER FUNCTION analytics.cagg_available_through(regclass) OWNER TO ems_admin;

COMMENT ON FUNCTION analytics.cagg_available_through(regclass) IS
'Migration 209 (Phase 2 Foundation, Phase 1). Returns the materialization watermark of a TimescaleDB continuous aggregate as a timestamptz -- the point through which the CAgg has been refreshed. Catalog-only (no data scan). Returns NULL if the CAgg has never materialized real data. This is a refresh watermark, NOT proof that every underlying source bucket in range contains data (see the per-tier reconcile_window, applied by migration 212, for the ahead-of-data case). Used as parent_available_through for analytics.energy_consumption_1min / _5min, whose parents are telemetry.ca_energy_1min / ca_energy_5min (both materialized_only).';

-- ----------------------------------------------------------------------------
-- 2. Extend the migration-208 config validator with the Phase-1 keys.
--    Does NOT weaken any existing check.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION config.assert_analytical_lookback_job_config(config jsonb)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_key  TEXT;
    v_ival INTERVAL;
BEGIN
    IF config IS NULL THEN
        RETURN;
    END IF;

    IF jsonb_typeof(config) <> 'object' THEN
        RAISE EXCEPTION
            'analytical job config must be a JSON object; got %', jsonb_typeof(config);
    END IF;

    FOR v_key IN SELECT jsonb_object_keys(config)
    LOOP
        IF v_key NOT IN ('lookback', 'max_catchup_window', 'overlap', 'reconcile_window') THEN
            RAISE EXCEPTION
                'analytical job config: unrecognised key "%"; allowed keys are lookback, max_catchup_window, overlap, reconcile_window',
                v_key;
        END IF;
    END LOOP;

    -- Every recognised key, when present, must be a positive finite interval.
    FOR v_key IN SELECT * FROM unnest(ARRAY['lookback','max_catchup_window','overlap','reconcile_window'])
    LOOP
        IF config ? v_key THEN
            BEGIN
                v_ival := (config ->> v_key)::INTERVAL;
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION
                    'analytical job config: % ("%") is not a valid interval',
                    v_key, config ->> v_key;
            END;
            IF v_ival IS NULL OR v_ival <= INTERVAL '0 seconds' THEN
                RAISE EXCEPTION
                    'analytical job config: % must be a positive interval; got "%"',
                    v_key, config ->> v_key;
            END IF;
        END IF;
    END LOOP;
END;
$fn$;

COMMENT ON FUNCTION config.assert_analytical_lookback_job_config(jsonb) IS
'Migration 208 check_config validator for the analytical-tier jobs, extended by migration 209. Rejects, at add_job/alter_job time, a config that is not a JSON object, carries a key other than lookback / max_catchup_window / overlap / reconcile_window, or whose value for any of those keys is not a positive finite interval. lookback = per-tier first-run floor; max_catchup_window / overlap drive the migration-209 bounded child-watermark window; reconcile_window is stored for migration 212''s bounded trailing reconciliation pass.';

-- ----------------------------------------------------------------------------
-- 3. pipeline_state rows for the five energy-consumption tiers.
--    Already created by migration 208; re-asserted here idempotently so this
--    migration is self-contained. last_received_at stays NULL until the first
--    successful watermark-driven run.
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES
    ('energy_consumption_1min'),
    ('energy_consumption_5min'),
    ('energy_consumption_15min'),
    ('energy_consumption_hourly'),
    ('energy_consumption_daily')
ON CONFLICT (pipeline_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4. Watermark-driven wrappers. Migration-208 scaffolding is reproduced
--    verbatim; ONLY the window-derivation block and the terminal
--    pipeline_state UPDATE (which now also advances last_received_at) change.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_1min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_1min';
    v_lookback         INTERVAL := INTERVAL '30 minutes';   -- FIRST-RUN FLOOR only
    v_max_catchup      INTERVAL := INTERVAL '2 hours';
    v_overlap          INTERVAL := INTERVAL '2 minutes';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption 1-minute config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    -- Migration 208 self-overlap guard (verbatim).
    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability: the ca_energy_1min materialization watermark.
    v_parent     := analytics.cagg_available_through('telemetry.ca_energy_1min');
    v_now_binned := date_trunc('minute', clock_timestamp());
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_1min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_5min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_5min';
    v_lookback         INTERVAL := INTERVAL '30 minutes';
    v_max_catchup      INTERVAL := INTERVAL '2 hours';
    v_overlap          INTERVAL := INTERVAL '10 minutes';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption 5-minute config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability: the ca_energy_5min materialization watermark. The
    -- CAgg has data (60s rows bucketed to 5-minute); refresh_energy_consumption_5min
    -- itself returns 0 rows for a 60s fleet -> NO_SOURCE_DATA, but the
    -- checkpoint still advances so LEAST(cp_1min, cp_5min) never blocks 15min.
    v_parent     := analytics.cagg_available_through('telemetry.ca_energy_5min');
    v_now_binned := date_bin(INTERVAL '5 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_5min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_15min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_15min';
    v_lookback         INTERVAL := INTERVAL '2 hours';
    v_max_catchup      INTERVAL := INTERVAL '6 hours';
    v_overlap          INTERVAL := INTERVAL '30 minutes';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption 15-minute config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability: the LESSER of the two upstream child checkpoints.
    -- LEAST() ignores NULLs (Postgres), so a not-yet-started or empty 5-minute
    -- tier falls back to the 1-minute checkpoint; only BOTH being NULL blocks.
    v_parent := LEAST(
        (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_1min'),
        (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_5min')
    );
    v_now_binned := date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_15min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_hourly_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_hourly';
    v_lookback         INTERVAL := INTERVAL '2 days';
    v_max_catchup      INTERVAL := INTERVAL '2 days';
    v_overlap          INTERVAL := INTERVAL '2 hours';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'hourly energy consumption config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability: the 15-minute child checkpoint.
    v_parent := (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_15min');
    v_now_binned := date_trunc('hour', clock_timestamp());
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_hourly(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_daily_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name    CONSTANT TEXT := 'energy_consumption_daily';
    v_lookback         INTERVAL := INTERVAL '8 days';
    v_max_catchup      INTERVAL := INTERVAL '8 days';
    v_overlap          INTERVAL := INTERVAL '2 days';
    v_ckpt             TIMESTAMPTZ;
    v_parent           TIMESTAMPTZ;
    v_now_binned       TIMESTAMPTZ;
    v_start            TIMESTAMPTZ;
    v_to               TIMESTAMPTZ;
    v_from             TIMESTAMPTZ;
    v_rows             BIGINT := 0;
    v_lock_acquired    BOOLEAN;
BEGIN
    IF config ? 'lookback'           THEN v_lookback    := (config ->> 'lookback')::INTERVAL; END IF;
    IF config ? 'max_catchup_window' THEN v_max_catchup := (config ->> 'max_catchup_window')::INTERVAL; END IF;
    IF config ? 'overlap'            THEN v_overlap     := (config ->> 'overlap')::INTERVAL; END IF;

    IF v_lookback <= INTERVAL '0 seconds' OR v_max_catchup <= INTERVAL '0 seconds' OR v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'daily energy consumption config intervals must be positive (lookback=%, max_catchup_window=%, overlap=%)', v_lookback, v_max_catchup, v_overlap;
    END IF;

    v_lock_acquired := pg_try_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    SELECT last_received_at INTO v_ckpt
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline_name FOR UPDATE;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Parent availability: the 15-minute child checkpoint (daily reads
    -- analytics.energy_consumption_15min directly, NOT the hourly tier).
    -- v_now_binned is clock_timestamp() (un-truncated), preserving the exact
    -- pre-209 semantics -- refresh_energy_consumption_daily does its own
    -- site-local-day aggregation and idempotently recomputes a partial current
    -- day via ON CONFLICT DO UPDATE on each subsequent run.
    v_parent := (SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = 'energy_consumption_15min');
    v_now_binned := clock_timestamp();
    v_start      := COALESCE(v_ckpt, v_now_binned - v_lookback);
    v_to         := LEAST(v_now_binned, v_parent, v_start + v_max_catchup);

    IF v_parent IS NULL OR v_to IS NULL OR v_to <= v_start THEN
        UPDATE telemetry.pipeline_state
        SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
            last_status = CASE WHEN v_ckpt IS NOT NULL AND v_to = v_ckpt THEN 'SUCCESS' ELSE 'NO_SOURCE_DATA' END,
            last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    v_from := v_start - v_overlap;
    v_rows := analytics.refresh_energy_consumption_daily(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_received_at   = v_to,
        last_completed_at  = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status        = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

ALTER PROCEDURE analytics.run_energy_consumption_1min_job(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_5min_job(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_15min_job(integer, jsonb)  OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_hourly_job(integer, jsonb) OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_daily_job(integer, jsonb)  OWNER TO ems_admin;

-- ----------------------------------------------------------------------------
-- 5. Merge the Phase-1 config keys into each of the five jobs' config.
--    lookback is preserved (first-run floor). schedule_interval / max_runtime
--    / max_retries / retry_period / check_config are NOT touched.
--    reconcile_window is stored now; migration 212 consumes it.
-- ----------------------------------------------------------------------------
DO $cfg$
DECLARE
    r RECORD;
    v_job_id INTEGER;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('run_energy_consumption_1min_job',   '2 hours', '2 minutes',  '2 days'),
            ('run_energy_consumption_5min_job',   '2 hours', '10 minutes', '7 days'),
            ('run_energy_consumption_15min_job',  '6 hours', '30 minutes', '3 days'),
            ('run_energy_consumption_hourly_job', '2 days',  '2 hours',    '10 days'),
            ('run_energy_consumption_daily_job',  '8 days',  '2 days',     '21 days')
        ) AS t(prc, mcw, ov, rw)
    LOOP
        FOR v_job_id IN
            SELECT job_id FROM timescaledb_information.jobs
            WHERE proc_schema = 'analytics' AND proc_name = r.prc
        LOOP
            PERFORM alter_job(
                v_job_id,
                config => (
                    SELECT COALESCE(config, '{}'::jsonb)
                           || jsonb_build_object(
                                'max_catchup_window', r.mcw,
                                'overlap',            r.ov,
                                'reconcile_window',   r.rw)
                    FROM timescaledb_information.jobs WHERE job_id = v_job_id
                )
            );
            RAISE NOTICE 'Migration 209: job % (analytics.%) config += max_catchup_window=%, overlap=%, reconcile_window=%',
                v_job_id, r.prc, r.mcw, r.ov, r.rw;
        END LOOP;
    END LOOP;
END
$cfg$;

COMMIT;
