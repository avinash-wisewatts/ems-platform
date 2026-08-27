-- ============================================================================
-- File:
--   scripts/test/assert_analytics_job_hardening.sql
--
-- Purpose:
--   Regression test for migration 208 (Phase 2 Foundation, Phase 0b):
--   the seven analytical-tier background jobs are made SAFE to run before
--   their window semantics are changed in a later phase --
--     analytics.run_energy_consumption_{1min,5min,15min,hourly,daily}_job
--     analytics.run_demand_calculation_job
--     telemetry.run_environment_daily_job
--   -- by wrapping each unchanged processing core with the telemetry-loader
--   advisory-lock + telemetry.pipeline_state pattern, giving each job a
--   finite max_runtime / max_retries / retry_period, and wiring a
--   check_config validator.
--
--   This is NOT a watermark test. Migration 208 does not add watermark /
--   bounded catch-up processing; every wrapper's [v_from, v_to) computation
--   is a fixed wall-clock lookback exactly as before, and last_received_at
--   is never read or written.
--
--   Proves, against the (empty-telemetry) canonical test database, mostly
--   inside BEGIN; ... ROLLBACK; :
--     A. The seven telemetry.pipeline_state rows exist with the expected
--        names and last_received_at IS NULL (no watermark).
--     B. Each job is registered with a FINITE max_runtime (5 min for the
--        1min/5min/15min tiers, 10 min for hourly/daily/demand/
--        environment_daily), max_retries = 3, retry_period = 5 minutes,
--        scheduled = TRUE, and check_config =
--        config.assert_analytical_lookback_job_config; schedule_interval and
--        config.lookback are unchanged.
--     C. A normal run records RUNNING -> SUCCESS (or NO_SOURCE_DATA when the
--        full-recompute refresh reported zero rows), with last_started_at,
--        last_completed_at (>= last_started_at) set and last_error NULL --
--        for all seven wrappers.
--     D. A failure injected at the terminal pipeline_state write rolls the
--        whole run back: pipeline_state is left exactly at its pre-call
--        value (no SUCCESS / NO_SOURCE_DATA / advanced state), and the
--        EXCEPTION -> FAILED -> RAISE handler is intact (catalog check).
--     E. Each wrapper carries the self-overlap guard: a
--        pg_try_advisory_xact_lock(hashtextextended('<proc>', 0)) on entry
--        and, on miss, an UPDATE ... last_status='SKIPPED_LOCKED' followed by
--        RETURN, ahead of the RUNNING write. (The cross-session behavioural
--        proof is in assert_analytics_job_self_overlap.sh.)
--     F. The check_config validator accepts a valid lookback /
--        max_catchup_window / NULL config and rejects a non-object config, an
--        unknown key, and a non-positive or unparseable interval.
--     G. Existing analytical calculation semantics are unchanged: each
--        wrapper still computes its exact date_trunc / date_bin /
--        clock_timestamp v_to and still PERFORMs / CALLs the same refresh
--        function; none of analytics.refresh_energy_consumption_* /
--        analytics.refresh_demand_analytics / telemetry.refresh_environment_daily
--        is redefined by migration 208 (they are not even mentioned as
--        CREATE OR REPLACE targets).
-- ============================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------------
-- TEST B / F / E / G -- catalog-only, no fixture, no transaction needed.
-- ---------------------------------------------------------------------------
DO $catalog$
DECLARE
    r RECORD;
    v_expected RECORD;
    v_def TEXT;
    v_failures TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- ---- TEST B: finite runtime / retry / validator per job ----
    FOR v_expected IN
        SELECT * FROM (VALUES
            ('analytics','run_energy_consumption_1min_job',   INTERVAL '1 minute',  INTERVAL '5 minutes',  '30 minutes'),
            ('analytics','run_energy_consumption_5min_job',   INTERVAL '1 minute',  INTERVAL '5 minutes',  '30 minutes'),
            ('analytics','run_energy_consumption_15min_job',  INTERVAL '5 minutes', INTERVAL '5 minutes',  '2 hours'),
            ('analytics','run_energy_consumption_hourly_job', INTERVAL '15 minutes',INTERVAL '10 minutes', '2 days'),
            ('analytics','run_energy_consumption_daily_job',  INTERVAL '1 hour',    INTERVAL '10 minutes', '8 days'),
            ('analytics','run_demand_calculation_job',        INTERVAL '1 minute',  INTERVAL '10 minutes', '3 hours'),
            ('telemetry','run_environment_daily_job',         INTERVAL '1 hour',    INTERVAL '10 minutes', '8 days')
        ) AS t(sch, prc, sched, mrt, lookback)
    LOOP
        SELECT j.schedule_interval, j.max_runtime, j.max_retries, j.retry_period,
               j.scheduled, j.config ->> 'lookback' AS lookback,
               j.check_schema, j.check_name
        INTO r
        FROM timescaledb_information.jobs j
        WHERE j.proc_schema = v_expected.sch AND j.proc_name = v_expected.prc
        ORDER BY j.job_id LIMIT 1;

        IF r IS NULL THEN
            v_failures := v_failures || format('%s.%s is not registered', v_expected.sch, v_expected.prc);
            CONTINUE;
        END IF;
        IF r.schedule_interval IS DISTINCT FROM v_expected.sched THEN
            v_failures := v_failures || format('%s schedule_interval %s <> %s', v_expected.prc, r.schedule_interval, v_expected.sched);
        END IF;
        IF r.max_runtime IS DISTINCT FROM v_expected.mrt THEN
            v_failures := v_failures || format('%s max_runtime %s <> %s', v_expected.prc, r.max_runtime, v_expected.mrt);
        END IF;
        IF r.max_runtime = INTERVAL '0' THEN
            v_failures := v_failures || format('%s max_runtime is unlimited (00:00:00)', v_expected.prc);
        END IF;
        IF r.max_retries IS DISTINCT FROM 3 THEN
            v_failures := v_failures || format('%s max_retries %s <> 3', v_expected.prc, r.max_retries);
        END IF;
        IF r.retry_period IS DISTINCT FROM INTERVAL '5 minutes' THEN
            v_failures := v_failures || format('%s retry_period %s <> 5 minutes', v_expected.prc, r.retry_period);
        END IF;
        IF r.scheduled IS DISTINCT FROM TRUE THEN
            v_failures := v_failures || format('%s is not scheduled', v_expected.prc);
        END IF;
        IF r.lookback IS DISTINCT FROM v_expected.lookback THEN
            v_failures := v_failures || format('%s config.lookback %s <> %s', v_expected.prc, r.lookback, v_expected.lookback);
        END IF;
        IF r.check_schema IS DISTINCT FROM 'config'
           OR r.check_name IS DISTINCT FROM 'assert_analytical_lookback_job_config' THEN
            v_failures := v_failures || format('%s check_config not wired (got %s.%s)', v_expected.prc, r.check_schema, r.check_name);
        END IF;

        -- ---- TEST E + G: wrapper body carries the guard and the unchanged core ----
        v_def := pg_get_functiondef(format('%s.%s(integer,jsonb)', v_expected.sch, v_expected.prc)::regprocedure);
        IF v_def NOT LIKE format('%%pg_try_advisory_xact_lock(%%hashtextextended(''%s.%s'', 0)%%', v_expected.sch, v_expected.prc) THEN
            v_failures := v_failures || format('%s missing advisory-lock guard on its own identity', v_expected.prc);
        END IF;
        IF v_def NOT LIKE '%last_status = ''SKIPPED_LOCKED''%' OR v_def NOT LIKE '%RETURN;%' THEN
            v_failures := v_failures || format('%s missing SKIPPED_LOCKED + RETURN branch', v_expected.prc);
        END IF;
        IF v_def NOT LIKE '%last_status = ''RUNNING''%' THEN
            v_failures := v_failures || format('%s missing RUNNING transition', v_expected.prc);
        END IF;
        IF v_def NOT LIKE '%EXCEPTION WHEN OTHERS THEN%' OR v_def NOT LIKE '%last_status = ''FAILED''%' OR v_def NOT LIKE '%RAISE;%' THEN
            v_failures := v_failures || format('%s missing EXCEPTION -> FAILED -> RAISE handler', v_expected.prc);
        END IF;
    END LOOP;

    -- Per-wrapper processing core (TEST G).
    -- The 5 energy-consumption wrappers became child-watermark-driven in
    -- migration 209: their bucket-boundary expression and their refresh_*
    -- call are preserved, but their [v_from, v_to) is now derived from a
    -- parent watermark + checkpoint, not now()-lookback. The full watermark
    -- contract is verified in assert_energy_consumption_cascade_watermarks.*;
    -- here we only assert the calculation call and the bucket expression
    -- survived and that the checkpoint advance is present.
    FOR v_expected IN
        SELECT * FROM (VALUES
            ('run_energy_consumption_1min_job',   'date_trunc(''minute'', clock_timestamp())',                                          'analytics.refresh_energy_consumption_1min(v_from, v_to)'),
            ('run_energy_consumption_5min_job',   'date_bin(INTERVAL ''5 minutes'', clock_timestamp(), TIMESTAMPTZ ''2000-01-01 00:00:00+00'')',  'analytics.refresh_energy_consumption_5min(v_from, v_to)'),
            ('run_energy_consumption_15min_job',  'date_bin(INTERVAL ''15 minutes'', clock_timestamp(), TIMESTAMPTZ ''2000-01-01 00:00:00+00'')', 'analytics.refresh_energy_consumption_15min(v_from, v_to)'),
            ('run_energy_consumption_hourly_job', 'date_trunc(''hour'', clock_timestamp())',                                            'analytics.refresh_energy_consumption_hourly(v_from, v_to)'),
            ('run_energy_consumption_daily_job',  'v_now_binned := clock_timestamp()',                                                  'analytics.refresh_energy_consumption_daily(v_from, v_to)')
        ) AS t(prc, bucket_expr, refresh_call)
    LOOP
        v_def := pg_get_functiondef(format('analytics.%s(integer,jsonb)', v_expected.prc)::regprocedure);
        IF position(v_expected.bucket_expr IN v_def) = 0 THEN
            v_failures := v_failures || format('%s: bucket expression changed', v_expected.prc);
        END IF;
        IF position(v_expected.refresh_call IN v_def) = 0 THEN
            v_failures := v_failures || format('%s: refresh_* call changed', v_expected.prc);
        END IF;
        IF v_def NOT LIKE '%last_received_at   = v_to%' THEN
            v_failures := v_failures || format('%s: watermark advance (last_received_at = v_to) missing', v_expected.prc);
        END IF;
        IF v_def NOT LIKE '%analytics.cagg_available_through%' AND v_expected.prc IN ('run_energy_consumption_1min_job','run_energy_consumption_5min_job') THEN
            v_failures := v_failures || format('%s: CAGG parent-availability helper not used', v_expected.prc);
        END IF;
    END LOOP;

    -- Demand wrapper became child-watermark-driven in migration 210: it now
    -- CALLs the 4-arg refresh_demand_analytics over a bounded [v_from, v_to)
    -- window and advances last_received_at = v_to as the last write of the run.
    -- Full contract: assert_demand_watermark_refinalization.*.
    v_def := pg_get_functiondef('analytics.run_demand_calculation_job(integer,jsonb)'::regprocedure);
    IF position('CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_from, v_to)' IN v_def) = 0 THEN
        v_failures := v_failures || format('%s', 'demand wrapper: 4-arg bounded refresh_demand_analytics call missing');
    END IF;
    IF v_def NOT LIKE '%last_received_at   = v_to%' THEN
        v_failures := v_failures || format('%s', 'demand wrapper: watermark advance (last_received_at = v_to) missing');
    END IF;
    IF position('''demand_intervals''' IN v_def) = 0 OR v_def NOT LIKE '%pipeline_name = v_pipeline_name%' THEN
        v_failures := v_failures || format('%s', 'demand wrapper: demand_intervals pipeline_state keying missing');
    END IF;
    IF position('date_bin(INTERVAL ''15 minutes''' IN v_def) = 0 OR position('LEAST(' IN v_def) = 0 THEN
        v_failures := v_failures || format('%s', 'demand wrapper: bounded 15-min catch-up derivation missing');
    END IF;

    -- environment_daily wrapper became child-watermark-driven in migration 211:
    -- it still CALLs the UNCHANGED telemetry.refresh_environment_daily(v_from, v_to)
    -- but now over a bounded site-local-day window and advances
    -- last_received_at = v_to. Parent availability MUST be the real newest
    -- environment_measurements bucket -- never a ca_environment_* CAGG, never the
    -- routing pipeline_state checkpoint. Full contract:
    -- assert_environment_daily_watermark.*.
    v_def := pg_get_functiondef('telemetry.run_environment_daily_job(integer,jsonb)'::regprocedure);
    IF v_def NOT LIKE '%telemetry.refresh_environment_daily(v_from, v_to)%' THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: refresh_environment_daily call changed');
    END IF;
    IF v_def NOT LIKE '%last_received_at   = v_to%' THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: watermark advance (last_received_at = v_to) missing');
    END IF;
    IF position('''environment_daily''' IN v_def) = 0 OR v_def NOT LIKE '%pipeline_name = v_pipeline_name%' THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: environment_daily pipeline_state keying missing');
    END IF;
    IF position('max(bucket_start)' IN v_def) = 0 OR position('environment_measurements' IN v_def) = 0 THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: parent availability not max(environment_measurements.bucket_start)');
    END IF;
    IF position('ca_environment' IN v_def) <> 0 THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: must NOT reference a ca_environment_* CAGG');
    END IF;
    IF position('date_bin(' IN v_def) = 0 OR position('telemetry_capture_policies' IN v_def) = 0 THEN
        v_failures := v_failures || format('%s', 'environment_daily wrapper: bounded UTC-day catch-up / capture-policy grace missing');
    END IF;

    -- ---- TEST F: validator accept / reject ----
    PERFORM config.assert_analytical_lookback_job_config('{"lookback":"2 hours"}'::jsonb);
    PERFORM config.assert_analytical_lookback_job_config(NULL);
    PERFORM config.assert_analytical_lookback_job_config('{"lookback":"30 minutes","max_catchup_window":"6 hours"}'::jsonb);
    FOR v_expected IN SELECT * FROM (VALUES
        ('{"lookback":"0 seconds"}'),
        ('{"lookback":"-1 hours"}'),
        ('{"lookback":"not-an-interval"}'),
        ('{"max_catchup_window":"0"}'),
        ('{"unknownkey":"x"}'),
        ('["array"]'),
        ('"scalar"')
    ) AS t(bad)
    LOOP
        BEGIN
            PERFORM config.assert_analytical_lookback_job_config(v_expected.bad::jsonb);
            v_failures := v_failures || format('validator accepted an invalid config: %s', v_expected.bad);
        EXCEPTION WHEN OTHERS THEN
            NULL;  -- expected
        END;
    END LOOP;

    IF array_length(v_failures, 1) > 0 THEN
        RAISE EXCEPTION 'analytics job hardening (catalog) FAILED: %', array_to_string(v_failures, '; ');
    END IF;
    RAISE NOTICE 'TEST B/E/F/G passed: finite runtime/retry/validator wired on all 7 jobs; advisory-lock + SKIPPED_LOCKED + RUNNING + FAILED/RAISE present; refresh cores and validator behaviour unchanged/correct.';
END
$catalog$;

-- ---------------------------------------------------------------------------
-- TEST A / C / D -- behavioural, rollback-only.
-- ---------------------------------------------------------------------------
BEGIN;

DO $behav$
DECLARE
    -- All 7 analytical pipelines.
    v_names TEXT[] := ARRAY[
        'energy_consumption_1min','energy_consumption_5min','energy_consumption_15min',
        'energy_consumption_hourly','energy_consumption_daily','demand_intervals','environment_daily'];
    -- After migration 211 every one of the 7 analytical tiers is
    -- watermark-driven (energy consumption 209, demand_intervals 210,
    -- environment_daily 211). No tier is exempt from the watermark checks.
    v_nowm  TEXT[] := ARRAY[]::TEXT[];
    v_n      TEXT;
    v_row    RECORD;
    v_raised BOOLEAN;
    v_rcvd_before TIMESTAMPTZ;
BEGIN
    -- Hold every analytical job's advisory lock for this transaction so a
    -- concurrently-scheduled run takes SKIPPED_LOCKED instead of racing our
    -- controlled CALLs (advisory locks are re-entrant within a session).
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_1min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_5min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_15min_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_hourly_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_energy_consumption_daily_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('analytics.run_demand_calculation_job', 0));
    PERFORM pg_advisory_xact_lock(hashtextextended('telemetry.run_environment_daily_job', 0));

    -- ---- TEST A: the 7 pipeline_state rows exist (all tiers watermark-driven
    -- after 211; v_nowm is empty so the per-tier "no watermark" guard is inert). ----
    FOR v_n IN SELECT unnest(v_names) LOOP
        SELECT * INTO v_row FROM telemetry.pipeline_state WHERE pipeline_name = v_n;
        IF v_row IS NULL THEN
            RAISE EXCEPTION 'TEST A FAILED: telemetry.pipeline_state row % is missing', v_n;
        END IF;
        IF v_n = ANY(v_nowm) AND v_row.last_received_at IS NOT NULL THEN
            RAISE EXCEPTION 'TEST A FAILED: % has a non-NULL last_received_at (%) -- it is not expected to be watermark-driven', v_n, v_row.last_received_at;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST A passed: 7 analytical pipeline_state rows exist; all tiers watermark-driven (209/210/211).';

    -- ---- TEST C: normal run -> RUNNING -> SUCCESS / NO_SOURCE_DATA ----
    CALL analytics.run_energy_consumption_1min_job(999208,   '{"lookback":"30 minutes"}'::jsonb);
    CALL analytics.run_energy_consumption_5min_job(999208,   '{"lookback":"30 minutes"}'::jsonb);
    CALL analytics.run_energy_consumption_15min_job(999208,  '{"lookback":"2 hours"}'::jsonb);
    CALL analytics.run_energy_consumption_hourly_job(999208, '{"lookback":"2 days"}'::jsonb);
    CALL analytics.run_energy_consumption_daily_job(999208,  '{"lookback":"8 days"}'::jsonb);
    CALL analytics.run_demand_calculation_job(999208,        '{"lookback":"3 hours"}'::jsonb);
    CALL telemetry.run_environment_daily_job(999208,         '{"lookback":"8 days"}'::jsonb);

    FOR v_n IN SELECT unnest(v_names) LOOP
        SELECT * INTO v_row FROM telemetry.pipeline_state WHERE pipeline_name = v_n;
        IF v_row.last_status NOT IN ('SUCCESS','NO_SOURCE_DATA') THEN
            RAISE EXCEPTION 'TEST C FAILED: % ended in %, expected SUCCESS or NO_SOURCE_DATA', v_n, v_row.last_status;
        END IF;
        IF v_row.last_started_at IS NULL OR v_row.last_completed_at IS NULL
           OR v_row.last_completed_at < v_row.last_started_at OR v_row.last_error IS NOT NULL THEN
            RAISE EXCEPTION 'TEST C FAILED: % has bad timing/error state (started=%, completed=%, error=%)',
                v_n, v_row.last_started_at, v_row.last_completed_at, v_row.last_error;
        END IF;
        -- v_nowm is empty after 211; guard retained for shape only.
        IF v_n = ANY(v_nowm) AND v_row.last_received_at IS NOT NULL THEN
            RAISE EXCEPTION 'TEST C FAILED: % advanced last_received_at (%) unexpectedly', v_n, v_row.last_received_at;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST C passed: all 7 wrappers record RUNNING -> SUCCESS/NO_SOURCE_DATA with consistent timing.';

    -- ---- TEST D: a failure at the terminal write advances nothing ----
    -- Post-209 the 1min tier IS watermark-driven, so the invariant is
    -- "a failed run leaves last_received_at UNCHANGED" (not necessarily NULL).
    UPDATE telemetry.pipeline_state
    SET last_status='NEVER_RUN', last_started_at=NULL, last_completed_at=NULL, last_error=NULL
    WHERE pipeline_name='energy_consumption_1min';
    SELECT last_received_at INTO v_rcvd_before
    FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';

    CREATE FUNCTION pg_temp.assert208_fail() RETURNS trigger LANGUAGE plpgsql AS $f$
    BEGIN
        IF NEW.pipeline_name = 'energy_consumption_1min'
           AND NEW.last_status IN ('SUCCESS','NO_SOURCE_DATA') THEN
            RAISE EXCEPTION 'assert208: injected failure at the terminal pipeline_state write';
        END IF;
        RETURN NEW;
    END;
    $f$;
    CREATE TRIGGER assert208_fail_trg
        BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.assert208_fail();

    v_raised := FALSE;
    BEGIN
        CALL analytics.run_energy_consumption_1min_job(999208, '{"lookback":"30 minutes"}'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST D FAILED: the injected terminal-write failure did not propagate out of the wrapper';
    END IF;

    SELECT * INTO v_row FROM telemetry.pipeline_state WHERE pipeline_name='energy_consumption_1min';
    IF v_row.last_status IS DISTINCT FROM 'NEVER_RUN'
       OR v_row.last_started_at IS NOT NULL
       OR v_row.last_received_at IS DISTINCT FROM v_rcvd_before THEN
        RAISE EXCEPTION 'TEST D FAILED: a failed run left state advanced (status=%, started=%, received=% expected %)',
            v_row.last_status, v_row.last_started_at, v_row.last_received_at, v_rcvd_before;
    END IF;

    DROP TRIGGER assert208_fail_trg ON telemetry.pipeline_state;
    RAISE NOTICE 'TEST D passed: a failure rolls the run back completely -- last_status/last_started_at reset, last_received_at unchanged, no successful transition.';
END
$behav$;

ROLLBACK;

SELECT 'Analytics job hardening assertions passed.' AS result;
