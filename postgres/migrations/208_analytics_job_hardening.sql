-- ============================================================================
-- Migration 208
-- Phase 2 Foundation, Phase 0b: harden the seven analytical-tier background
-- jobs so they are SAFE to run before their window semantics are changed in a
-- later phase. This migration does NOT introduce child-watermark / bounded
-- catch-up processing -- the processing window of every wrapper is preserved
-- byte-for-byte (still a fixed wall-clock lookback).
--
-- Jobs in scope (proc / pipeline_state name):
--   analytics.run_energy_consumption_1min_job    -> energy_consumption_1min
--   analytics.run_energy_consumption_5min_job    -> energy_consumption_5min
--   analytics.run_energy_consumption_15min_job   -> energy_consumption_15min
--   analytics.run_energy_consumption_hourly_job  -> energy_consumption_hourly
--   analytics.run_energy_consumption_daily_job   -> energy_consumption_daily
--   analytics.run_demand_calculation_job         -> demand_intervals
--   telemetry.run_environment_daily_job          -> environment_daily
--
-- Root cause (Phase 2 Foundation Implementation-Planning Design, finding
-- P-C1): none of these seven wrappers took an advisory lock or recorded any
-- pipeline_state, and every one of their jobs was registered with
-- max_runtime = 00:00:00 (unlimited) and max_retries = -1 (infinite). A run
-- that overran its schedule interval could therefore be joined by a second,
-- concurrent invocation processing the SAME window -- wasted work at best,
-- and for run_demand_calculation_job a double-apply of the provisional
-- analytics.demand_state accumulator / a row-lock deadlock at worst. A
-- persistently failing job retried forever with no operator-visible signal
-- other than the raw job-error log.
--
-- What this migration does:
--
--   1. config.assert_analytical_lookback_job_config(jsonb) -- a check_config
--      validator (the TimescaleDB bgw_job check_schema/check_name hook, unused
--      anywhere in this platform until now). It rejects, at add_job/alter_job
--      time, a config that is not a JSON object, carries an unrecognised key,
--      or whose lookback / max_catchup_window is not a positive finite
--      interval. (max_catchup_window is not used yet; it is accepted here so
--      the later child-watermark phase does not have to reopen this
--      function.)
--
--   2. Seven telemetry.pipeline_state rows -- one per analytical pipeline,
--      reusing the existing table and its existing columns unchanged
--      (postgres/ddl/41's own header anticipates "future pipelines"). Inserted
--      ON CONFLICT DO NOTHING so this is idempotent and forward-compatible
--      with a later phase that may already have created them. Introduced now
--      purely for operational state / observability and to give the later
--      watermark phases the same transactional pattern to build on. NO
--      watermark-based processing is implemented here; last_received_at is
--      left NULL and is not read or advanced by any wrapper in this
--      migration.
--
--   3. CREATE OR REPLACE of the seven wrappers, each wrapped -- around its
--      unchanged core -- with the SAME advisory-lock + pipeline_state pattern
--      the telemetry loaders already use:
--        * pg_try_advisory_xact_lock(hashtextextended('<proc>', 0)) on entry;
--          on miss -> pipeline_state.last_status='SKIPPED_LOCKED', RETURN,
--          without touching the processing path or last_started_at.
--        * last_status='RUNNING' after the lock is taken.
--        * on normal completion: last_status='SUCCESS', or 'NO_SOURCE_DATA'
--          when the (full-recompute) refresh reported zero affected rows,
--          i.e. no source rows existed anywhere in the lookback window.
--        * EXCEPTION WHEN OTHERS -> last_status='FAILED', last_error, RAISE
--          -- identical to the telemetry loaders. As with those, the
--          re-RAISE means the TimescaleDB job runner rolls the whole job
--          transaction back (the FAILED write included), so a scheduled
--          failure leaves pipeline_state unchanged rather than showing
--          'FAILED'; the durable failure signal remains
--          _timescaledb_internal.bgw_job_stat / timescaledb_information.
--          job_errors. What matters -- and what this guarantees -- is that a
--          failed / cancelled / timed-out run advances NOTHING and records no
--          success. (A manual, error-swallowing CALL still sees 'FAILED'.)
--      The lookback parsing/validation, the exact v_to / v_from computation
--      (date_trunc / date_bin / clock_timestamp per tier), and the
--      PERFORM/CALL of analytics.refresh_energy_consumption_* /
--      analytics.refresh_demand_analytics / telemetry.refresh_environment_daily
--      are reproduced verbatim from the currently deployed definitions. None
--      of the refresh functions themselves are touched.
--
--   4. alter_job on each of the seven jobs: max_runtime => 5 minutes for the
--      1min/5min/15min tiers and 10 minutes for the hourly/daily/demand/
--      environment-daily tiers (matching the Phase 2 design's tier sizing;
--      local runtime evidence shows the wrapper overhead is sub-millisecond,
--      and the heavier tiers get 10 minutes purely as headroom for the demand
--      site x scope x interval loop and the timezone-aware daily rollups on a
--      production-scale fleet -- staging job_stats.last_run_duration should be
--      sampled before this deploys); max_retries => 3; retry_period =>
--      5 minutes; scheduled => TRUE; check_config => the validator from (1).
--      schedule_interval and config are NOT passed and are preserved exactly
--      (cadence is unchanged; config stays {"lookback": "..."}).
--
-- Explicitly NOT done here (later phases, separate approval):
--   child watermark / bounded catch-up window / cascade dependency /
--   demand ON CONFLICT DO UPDATE / reconciliation / v_pipeline_health /
--   moving the add_job calls out of migrations 013/028/031/179/181/183/184
--   into postgres/jobs/ (deferred: those migrations are checksum-locked and
--   several use a bare, unguarded add_job, so a canonical-layer registration
--   running before them would double-register; fresh-deploy reproducibility
--   is already provided by those migrations and is now enforced by the
--   extended scripts/test/assert_job_schedule_canonical.sql).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. check_config validator for the analytical jobs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION config.assert_analytical_lookback_job_config(config jsonb)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_key  TEXT;
    v_ival INTERVAL;
BEGIN
    -- A NULL config is acceptable: each wrapper applies its own default
    -- lookback when the key is absent.
    IF config IS NULL THEN
        RETURN;
    END IF;

    IF jsonb_typeof(config) <> 'object' THEN
        RAISE EXCEPTION
            'analytical job config must be a JSON object; got %', jsonb_typeof(config);
    END IF;

    FOR v_key IN SELECT jsonb_object_keys(config)
    LOOP
        IF v_key NOT IN ('lookback', 'max_catchup_window') THEN
            RAISE EXCEPTION
                'analytical job config: unrecognised key "%"; allowed keys are lookback, max_catchup_window',
                v_key;
        END IF;
    END LOOP;

    IF config ? 'lookback' THEN
        BEGIN
            v_ival := (config ->> 'lookback')::INTERVAL;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION
                'analytical job config: lookback ("%") is not a valid interval',
                config ->> 'lookback';
        END;
        IF v_ival IS NULL OR v_ival <= INTERVAL '0 seconds' THEN
            RAISE EXCEPTION
                'analytical job config: lookback must be a positive interval; got "%"',
                config ->> 'lookback';
        END IF;
    END IF;

    IF config ? 'max_catchup_window' THEN
        BEGIN
            v_ival := (config ->> 'max_catchup_window')::INTERVAL;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION
                'analytical job config: max_catchup_window ("%") is not a valid interval',
                config ->> 'max_catchup_window';
        END;
        IF v_ival IS NULL OR v_ival <= INTERVAL '0 seconds' THEN
            RAISE EXCEPTION
                'analytical job config: max_catchup_window must be a positive interval; got "%"',
                config ->> 'max_catchup_window';
        END IF;
    END IF;
END;
$fn$;

ALTER FUNCTION config.assert_analytical_lookback_job_config(jsonb) OWNER TO ems_admin;

COMMENT ON FUNCTION config.assert_analytical_lookback_job_config(jsonb) IS
'Migration 208 (Phase 2 Foundation, Phase 0b). check_config validator wired onto the seven analytical-tier background jobs (analytics.run_energy_consumption_{1min,5min,15min,hourly,daily}_job, analytics.run_demand_calculation_job, telemetry.run_environment_daily_job). Rejects, at add_job/alter_job time, a config that is not a JSON object, carries a key other than lookback / max_catchup_window, or whose lookback / max_catchup_window is not a positive finite interval. max_catchup_window is not consumed yet; it is accepted here for the later child-watermark phase.';

-- ----------------------------------------------------------------------------
-- 2. pipeline_state rows for the seven analytical pipelines (idempotent).
--    Existing columns only; last_received_at intentionally left NULL -- this
--    migration does NOT implement watermark processing.
-- ----------------------------------------------------------------------------
INSERT INTO telemetry.pipeline_state (pipeline_name)
VALUES
    ('energy_consumption_1min'),
    ('energy_consumption_5min'),
    ('energy_consumption_15min'),
    ('energy_consumption_hourly'),
    ('energy_consumption_daily'),
    ('demand_intervals'),
    ('environment_daily')
ON CONFLICT (pipeline_name) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Harden the seven wrappers: advisory lock + pipeline_state status around
--    an otherwise byte-for-byte-preserved processing core.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE analytics.run_energy_consumption_1min_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'energy_consumption_1min';
    v_lookback INTERVAL := INTERVAL '30 minutes';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard. If a previous run of this
    -- pipeline is still in flight (the job overran its schedule interval),
    -- skip this invocation cleanly instead of processing the same window
    -- concurrently. The lock is transaction-scoped and releases when this
    -- procedure's transaction ends; identity is the fully-qualified proc name,
    -- stable and collision-free.
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_energy_consumption_1min_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b: still a fixed wall-clock
    -- lookback. Child-watermark-based processing is a later phase.
    -- Only process completed minute buckets.
    v_to   := date_trunc('minute', clock_timestamp());
    v_from := v_to - v_lookback;

    v_rows := analytics.refresh_energy_consumption_1min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
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
    v_pipeline_name CONSTANT TEXT := 'energy_consumption_5min';
    v_lookback INTERVAL := INTERVAL '30 minutes';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_energy_consumption_5min_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b.
    -- Start of the current five-minute bucket. The half-open refresh range
    -- therefore contains completed native five-minute buckets only.
    v_to   := date_bin(INTERVAL '5 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_from := v_to - v_lookback;

    v_rows := analytics.refresh_energy_consumption_5min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
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
    v_pipeline_name CONSTANT TEXT := 'energy_consumption_15min';
    v_lookback INTERVAL := INTERVAL '2 hours';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'energy consumption 15-minute lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_energy_consumption_15min_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b.
    v_to   := date_bin(INTERVAL '15 minutes', clock_timestamp(), TIMESTAMPTZ '2000-01-01 00:00:00+00');
    v_from := v_to - v_lookback;

    v_rows := analytics.refresh_energy_consumption_15min(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
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
    v_pipeline_name CONSTANT TEXT := 'energy_consumption_hourly';
    v_lookback INTERVAL := INTERVAL '2 days';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'hourly energy consumption lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_energy_consumption_hourly_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b.
    -- Beginning of current hour. Only completed hourly buckets are persisted.
    v_to   := date_trunc('hour', clock_timestamp());
    v_from := v_to - v_lookback;

    v_rows := analytics.refresh_energy_consumption_hourly(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
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
    v_pipeline_name CONSTANT TEXT := 'energy_consumption_daily';
    v_lookback INTERVAL := INTERVAL '8 days';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'daily energy consumption lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_energy_consumption_daily_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b.
    v_to   := clock_timestamp();
    v_from := v_to - v_lookback;

    v_rows := analytics.refresh_energy_consumption_daily(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE analytics.run_demand_calculation_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'analytics'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'demand_intervals';
    v_lookback INTERVAL := INTERVAL '3 hours';
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config->>'lookback')::INTERVAL;
    END IF;

    -- Phase 0b (migration 208): self-overlap guard. Without it, a run that
    -- overran its 1-minute schedule could be joined by a concurrent
    -- invocation double-applying the provisional analytics.demand_state
    -- accumulator or deadlocking on analytics.demand_intervals row locks.
    -- analytics.refresh_demand_analytics still validates its own p_lookback.
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('analytics.run_demand_calculation_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Processing window UNCHANGED by Phase 0b: refresh_demand_analytics still
    -- receives clock_timestamp() and the fixed lookback. Child-watermark
    -- processing and the demand ON CONFLICT DO UPDATE change are later phases.
    CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'SUCCESS', last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

CREATE OR REPLACE PROCEDURE telemetry.run_environment_daily_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'telemetry'
AS $procedure$
DECLARE
    v_pipeline_name CONSTANT TEXT := 'environment_daily';
    v_lookback INTERVAL := INTERVAL '8 days';
    v_to   TIMESTAMPTZ;
    v_from TIMESTAMPTZ;
    v_rows BIGINT := 0;
    v_lock_acquired BOOLEAN;
BEGIN
    IF config ? 'lookback' THEN
        v_lookback := (config ->> 'lookback')::INTERVAL;
    END IF;

    IF v_lookback <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION 'environment daily lookback must be positive';
    END IF;

    -- Phase 0b (migration 208): self-overlap guard (see analytics.run_energy_consumption_1min_job).
    v_lock_acquired := pg_try_advisory_xact_lock(
        hashtextextended('telemetry.run_environment_daily_job', 0)
    );
    IF NOT v_lock_acquired THEN
        UPDATE telemetry.pipeline_state
        SET last_status = 'SKIPPED_LOCKED', last_error = NULL, updated_at = now()
        WHERE pipeline_name = v_pipeline_name;
        RETURN;
    END IF;

    UPDATE telemetry.pipeline_state
    SET last_started_at = clock_timestamp(), last_status = 'RUNNING',
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;

    -- Window derivation UNCHANGED by Phase 0b.
    v_to   := clock_timestamp();
    v_from := v_to - v_lookback;

    v_rows := telemetry.refresh_environment_daily(v_from, v_to);

    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(),
        last_inserted_rows = v_rows,
        last_status = CASE WHEN v_rows = 0 THEN 'NO_SOURCE_DATA' ELSE 'SUCCESS' END,
        last_error = NULL, updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
EXCEPTION WHEN OTHERS THEN
    UPDATE telemetry.pipeline_state
    SET last_completed_at = clock_timestamp(), last_inserted_rows = 0,
        last_status = 'FAILED', last_error = SQLSTATE || ': ' || SQLERRM,
        updated_at = now()
    WHERE pipeline_name = v_pipeline_name;
    RAISE;
END;
$procedure$;

-- Ownership (defensive; all seven are already ems_admin-owned).
ALTER PROCEDURE analytics.run_energy_consumption_1min_job(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_5min_job(integer, jsonb)   OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_15min_job(integer, jsonb)  OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_hourly_job(integer, jsonb) OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_energy_consumption_daily_job(integer, jsonb)  OWNER TO ems_admin;
ALTER PROCEDURE analytics.run_demand_calculation_job(integer, jsonb)        OWNER TO ems_admin;
ALTER PROCEDURE telemetry.run_environment_daily_job(integer, jsonb)         OWNER TO ems_admin;

-- ----------------------------------------------------------------------------
-- 4. Finite runtime / retry policy + validator wiring on each job.
--    schedule_interval and config are deliberately NOT passed (preserved).
-- ----------------------------------------------------------------------------
DO $harden$
DECLARE
    r RECORD;
    v_job_id INTEGER;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            ('analytics', 'run_energy_consumption_1min_job',   INTERVAL '5 minutes'),
            ('analytics', 'run_energy_consumption_5min_job',   INTERVAL '5 minutes'),
            ('analytics', 'run_energy_consumption_15min_job',  INTERVAL '5 minutes'),
            ('analytics', 'run_energy_consumption_hourly_job', INTERVAL '10 minutes'),
            ('analytics', 'run_energy_consumption_daily_job',  INTERVAL '10 minutes'),
            ('analytics', 'run_demand_calculation_job',        INTERVAL '10 minutes'),
            ('telemetry', 'run_environment_daily_job',         INTERVAL '10 minutes')
        ) AS t(sch, prc, mrt)
    LOOP
        FOR v_job_id IN
            SELECT job_id
            FROM timescaledb_information.jobs
            WHERE proc_schema = r.sch AND proc_name = r.prc
        LOOP
            PERFORM alter_job(
                v_job_id,
                max_runtime  => r.mrt,
                max_retries  => 3,
                retry_period => INTERVAL '5 minutes',
                scheduled    => TRUE,
                check_config => 'config.assert_analytical_lookback_job_config'::regproc
            );
            RAISE NOTICE
                'Migration 208: hardened job % (%.%): max_runtime=%, max_retries=3, retry_period=5m, check_config=config.assert_analytical_lookback_job_config',
                v_job_id, r.sch, r.prc, r.mrt;
        END LOOP;
    END LOOP;
END
$harden$;

COMMIT;
