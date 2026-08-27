-- ============================================================================
-- File:
--   scripts/test/assert_normalization_bounded_catchup_window.sql
--
-- Purpose:
--   Regression test for migrations 205 AND 212.
--
--   Migration 205: telemetry.load_normalized_points_incremental() gains an
--   optional p_max_window INTERVAL parameter (default NULL) that caps its
--   forward processing boundary to previous_checkpoint + p_max_window, instead
--   of always advancing all the way to max(telemetry.raw_messages.received_at).
--
--   Migration 212 (N1): telemetry.run_normalization_job (job 1000's action) now
--   ALWAYS passes a bounded p_max_window (default INTERVAL '2 hours', overridable
--   via config.max_window) to the loader. It never passes NULL. The loader is
--   NOT changed by 212 -- all of its lock/state/transaction/rollback/overlap/
--   first-run behaviour stays exactly where it already lives. Job 1000's config
--   gains "max_window": "2 hours" alongside the existing "overlap": "15 minutes".
--
--   This test proves, against a fully synthetic, rollback-only fixture:
--     A. p_max_window=NULL preserves the exact pre-205 forward-boundary
--        behavior (advances all the way to max(raw_messages.received_at)) --
--        this is ALSO the migration-212 "manual unrestricted CALL remains
--        possible" contract (item J);
--     B. a bounded loader call advances the watermark to exactly
--        min(max(raw_messages.received_at), previous_checkpoint+p_max_window)
--        when that sum is the smaller value;
--     C. a bounded loader call advances the watermark to exactly
--        max(raw_messages.received_at) when that is already the smaller value;
--     D. the existing p_overlap/late-arrival-horizon computation is
--        byte-for-byte unchanged (a live catalog check);
--     E. (migration 212) telemetry.run_normalization_job with a config that
--        carries NO max_window key applies the DEFAULT bound of 2 hours: the
--        watermark advances to exactly previous_checkpoint + 2 hours, NOT to
--        the unbounded max;
--     F. (212) run_normalization_job honours a config.max_window override
--        (positive interval accepted): with {"max_window":"30 minutes"} the
--        watermark advances to exactly previous_checkpoint + 30 minutes;
--     G. (212) run_normalization_job REJECTS a zero or negative max_window
--        before touching the loader (RAISE EXCEPTION), leaving the checkpoint
--        untouched;
--     H. (212) a SUBSEQUENT run continues from the new bounded checkpoint --
--        two successive default runs advance the watermark by 2 hours each;
--     I. (212) steady state: when the backlog is < 2 hours, the effective
--        endpoint is still max(raw_messages.received_at) -- the bound does not
--        artificially hold the watermark back;
--     J. (212, contract) the deployed run_normalization_job body passes TWO
--        arguments to telemetry.load_normalized_points_incremental and derives
--        v_max_window from config->>'max_window'; and it does NOT duplicate the
--        loader's advisory lock / pipeline_state handling / EXCEPTION block --
--        failure/rollback remains owned by the loader;
--     K. (212, contract) job 1000's live config carries a positive, parseable
--        max_window alongside overlap;
--     L. (212) normalization selection/calculation is untouched: the synthetic
--        raw row's uid matches no registered device, so zero normalized_points
--        rows are produced by any call above -- this test only exercises the
--        window-boundary computation (D already catalog-checks the loader body).
--
--   telemetry.load_normalized_points_incremental() and
--   telemetry.run_normalization_job() contain no intermediate COMMIT (confirmed
--   by inspection of their deployed definitions), so this test can safely run
--   inside a BEGIN; ... ROLLBACK; wrapper -- no fixture data, and no mutation of
--   the real, shared telemetry.pipeline_state row, ever persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_synthetic_max     TIMESTAMPTZ := clock_timestamp() + INTERVAL '100 days';
    v_checkpoint        TIMESTAMPTZ := clock_timestamp() + INTERVAL '90 days';
    v_msg_id            BIGINT;
    v_result            TIMESTAMPTZ;
    v_def               TEXT;
    v_raised            BOOLEAN;
    v_bad               TEXT;
BEGIN
    -- Fixture: one raw_messages row far enough in the future to be
    -- deterministically the global max(received_at) regardless of any other
    -- data already present in this database. Its uid deliberately matches no
    -- registered device_identifiers row, so it contributes zero capture/
    -- normalization candidates -- this test targets the window-boundary
    -- computation only, not the selection/normalization logic (unchanged).
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_synthetic_max, 'MQTT', 'test/normalization-bounded-window',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid','TEST:WINDOW:BOUNDARY:NOMATCH')))
    )
    RETURNING id INTO v_msg_id;

    -- ==================================================================
    -- TEST A -- p_max_window=NULL preserves existing behavior: the
    -- watermark advances all the way to the synthetic max, unbounded.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.load_normalized_points_incremental(INTERVAL '5 minutes', NULL);

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST A FAILED: p_max_window=NULL should advance to max(raw_messages.received_at)=%, got %', v_synthetic_max, v_result;
    END IF;
    RAISE NOTICE 'TEST A passed: p_max_window=NULL preserves the unbounded forward boundary (advanced to %).', v_result;

    -- The procedure's internal working tables are CREATE TEMP TABLE ... ON
    -- COMMIT DROP (unchanged, pre-existing behavior). Since this test issues
    -- multiple CALLs inside one outer transaction with no intermediate
    -- COMMIT (by design -- see file header), they are never auto-dropped
    -- between calls and must be cleared explicitly here.
    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST B -- bounded call: previous_checkpoint + p_max_window is the
    -- smaller value (checkpoint+3d = max-87d, well short of the 100d-out
    -- synthetic max), so the watermark must stop there, not at the max.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.load_normalized_points_incremental(INTERVAL '5 minutes', INTERVAL '3 days');

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '3 days') THEN
        RAISE EXCEPTION 'TEST B FAILED: expected watermark to advance to checkpoint+3d=%, got %', v_checkpoint + INTERVAL '3 days', v_result;
    END IF;
    IF v_result >= v_synthetic_max THEN
        RAISE EXCEPTION 'TEST B FAILED: bounded watermark % must be strictly less than the unbounded max %', v_result, v_synthetic_max;
    END IF;
    RAISE NOTICE 'TEST B passed: bounded call advanced the watermark to exactly min(max, checkpoint+p_max_window) = %.', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST C -- bounded call where the requested horizon
    -- (checkpoint+50d = max+40d) is already past the actual data max: the
    -- watermark must stop at the true max, not overshoot to a point with
    -- no source data.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.load_normalized_points_incremental(INTERVAL '5 minutes', INTERVAL '50 days');

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST C FAILED: expected watermark to stop at the true max=% (requested horizon exceeds available data), got %', v_synthetic_max, v_result;
    END IF;
    RAISE NOTICE 'TEST C passed: when the requested horizon exceeds available data, the watermark stops at the true max (%).', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST D -- the existing p_overlap / late-arrival-horizon computation
    -- is byte-for-byte unchanged (live catalog check).
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.load_normalized_points_incremental(interval,interval)'::regprocedure);

    IF v_def NOT ILIKE '%make_interval(secs => GREATEST(%COALESCE(max(capture_interval_seconds+late_arrival_tolerance_seconds),0),%extract(epoch FROM p_overlap)::INTEGER%'
    THEN
        RAISE EXCEPTION 'TEST D FAILED: the existing p_overlap/late-arrival-horizon computation appears to have changed';
    END IF;
    IF v_def NOT ILIKE '%v_previous_checkpoint-v_dynamic_overlap%' THEN
        RAISE EXCEPTION 'TEST D FAILED: the existing v_window_start=checkpoint-overlap computation appears to have changed';
    END IF;
    RAISE NOTICE 'TEST D passed: the existing p_overlap/late-arrival-horizon computation is unchanged.';

    -- ==================================================================
    -- TEST E (migration 212) -- telemetry.run_normalization_job with a
    -- config carrying NO max_window key applies the DEFAULT bound of
    -- 2 hours: the watermark advances to exactly checkpoint + 2 hours,
    -- NOT to the unbounded synthetic max (which is 10 days further out).
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST E FAILED: run_normalization_job default should bound the watermark to checkpoint+2h=%, got %', v_checkpoint + INTERVAL '2 hours', v_result;
    END IF;
    IF v_result >= v_synthetic_max THEN
        RAISE EXCEPTION 'TEST E FAILED: the default-bounded watermark % must be strictly less than the unbounded max %', v_result, v_synthetic_max;
    END IF;
    RAISE NOTICE 'TEST E passed: run_normalization_job applies the default 2-hour bound (advanced to %).', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST F (212) -- config.max_window override, positive interval
    -- accepted: {"max_window":"30 minutes"} advances the watermark to
    -- exactly checkpoint + 30 minutes.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes','max_window','30 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '30 minutes') THEN
        RAISE EXCEPTION 'TEST F FAILED: config.max_window=30 minutes should bound the watermark to checkpoint+30m=%, got %', v_checkpoint + INTERVAL '30 minutes', v_result;
    END IF;
    RAISE NOTICE 'TEST F passed: run_normalization_job honours a positive config.max_window override (advanced to %).', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST G (212) -- a zero or negative max_window is REJECTED by the
    -- wrapper BEFORE it touches the loader; the checkpoint is untouched.
    -- ==================================================================
    FOREACH v_bad IN ARRAY ARRAY['0', '-1 hours'] LOOP
        UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';
        v_raised := FALSE;
        BEGIN
            CALL telemetry.run_normalization_job(999999,
                 jsonb_build_object('overlap','5 minutes','max_window',v_bad));
        EXCEPTION WHEN OTHERS THEN
            v_raised := TRUE;
        END;
        IF NOT v_raised THEN
            RAISE EXCEPTION 'TEST G FAILED: run_normalization_job accepted an invalid max_window "%"', v_bad;
        END IF;
        SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
        IF v_result IS DISTINCT FROM v_checkpoint THEN
            RAISE EXCEPTION 'TEST G FAILED: an invalid max_window "%" advanced the checkpoint (% -> %)', v_bad, v_checkpoint, v_result;
        END IF;
        DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;
    END LOOP;
    RAISE NOTICE 'TEST G passed: zero/negative max_window rejected before the loader; checkpoint untouched.';

    -- ==================================================================
    -- TEST H (212) -- a subsequent run continues from the new bounded
    -- checkpoint: two successive default runs advance by 2 hours each.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes'));
    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;
    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '4 hours') THEN
        RAISE EXCEPTION 'TEST H FAILED: two successive default runs should advance to checkpoint+4h=%, got %', v_checkpoint + INTERVAL '4 hours', v_result;
    END IF;
    RAISE NOTICE 'TEST H passed: successive bounded runs continue from the new checkpoint (advanced to %).', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST I (212) -- steady state: when the backlog is under 2 hours the
    -- effective endpoint is still max(raw_messages.received_at); the bound
    -- does not hold the watermark back.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=(v_synthetic_max - INTERVAL '30 minutes') WHERE pipeline_name='normalized_points';

    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST I FAILED: with a <2h backlog the watermark should reach the true max=%, got %', v_synthetic_max, v_result;
    END IF;
    RAISE NOTICE 'TEST I passed: steady-state endpoint is max(raw_messages.received_at) (advanced to %).', v_result;

    DROP TABLE IF EXISTS tmp_capture_candidates, tmp_selected_samples, tmp_normalized_batch;

    -- ==================================================================
    -- TEST J (212, contract) -- the deployed run_normalization_job body
    -- passes TWO arguments to the loader, derives v_max_window from
    -- config->>'max_window', and does NOT duplicate the loader's advisory
    -- lock / pipeline_state handling / EXCEPTION block (failure/rollback
    -- stays owned by the loader).
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.run_normalization_job(integer,jsonb)'::regprocedure);

    IF position('load_normalized_points_incremental(v_overlap, v_max_window)' IN v_def) = 0 THEN
        RAISE EXCEPTION 'TEST J FAILED: run_normalization_job does not pass a two-argument (v_overlap, v_max_window) call to the loader';
    END IF;
    IF position('''max_window''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'TEST J FAILED: run_normalization_job does not read config->>''max_window''';
    END IF;
    IF v_def ILIKE '%advisory_xact_lock%'
       OR v_def ILIKE '%pipeline_state%'
       OR v_def ILIKE '%EXCEPTION WHEN OTHERS%' THEN
        RAISE EXCEPTION 'TEST J FAILED: run_normalization_job now duplicates loader-owned lock/state/exception handling';
    END IF;
    -- and the loader itself still owns all of it:
    v_def := pg_get_functiondef('telemetry.load_normalized_points_incremental(interval,interval)'::regprocedure);
    IF v_def NOT ILIKE '%pg_try_advisory_xact_lock(%'
       OR v_def NOT ILIKE '%SKIPPED_LOCKED%'
       OR v_def NOT ILIKE '%last_status=''FAILED''%'
       OR v_def NOT ILIKE '%EXCEPTION WHEN OTHERS%'
       OR v_def NOT ILIKE '%LEAST(v_window_end, v_previous_checkpoint + p_max_window)%' THEN
        RAISE EXCEPTION 'TEST J FAILED: the loader''s lock/state/rollback/bounded-window logic is not intact';
    END IF;
    RAISE NOTICE 'TEST J passed: wrapper passes a bounded two-arg call; loader still owns lock/state/rollback/bounded-window.';

    -- ==================================================================
    -- TEST K (212, contract) -- job 1000's live config carries a positive,
    -- parseable max_window alongside overlap.
    -- ==================================================================
    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema='telemetry' AND proc_name='run_normalization_job'
          AND (config ->> 'max_window') IS NOT NULL
          AND (config ->> 'max_window')::INTERVAL > INTERVAL '0 seconds'
          AND (config ->> 'overlap') IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST K FAILED: job run_normalization_job config lacks a positive max_window (or lost overlap): %',
            (SELECT config FROM timescaledb_information.jobs
             WHERE proc_schema='telemetry' AND proc_name='run_normalization_job' LIMIT 1);
    END IF;
    RAISE NOTICE 'TEST K passed: job 1000 config carries overlap + a positive max_window.';

    -- TEST L (212) -- normalization selection/calculation untouched: the
    -- synthetic raw row's uid matches no registered device, so every call
    -- above produced zero normalized_points rows (window-boundary only).
    -- (The loader body itself is catalog-checked unchanged by TEST D / J.)
    IF EXISTS (
        SELECT 1 FROM telemetry.normalized_points
        WHERE raw_message_id = v_msg_id
    ) THEN
        RAISE EXCEPTION 'TEST L FAILED: the boundary-only fixture unexpectedly produced normalized_points rows';
    END IF;
    RAISE NOTICE 'TEST L passed: no normalized_points produced -- selection/calculation semantics untouched.';

END;
$test$;

ROLLBACK;

SELECT
    'Normalization bounded-catchup-window assertions passed.'
    AS result;
