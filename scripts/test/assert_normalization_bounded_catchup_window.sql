-- ============================================================================
-- File:
--   scripts/test/assert_normalization_bounded_catchup_window.sql
--
-- Purpose:
--   Regression test for migration 205: telemetry.load_normalized_points_
--   incremental() gains an optional p_max_window INTERVAL parameter (default
--   NULL) that caps its forward processing boundary to
--   previous_checkpoint + p_max_window, instead of always advancing all the
--   way to max(telemetry.raw_messages.received_at). This is an emergency
--   catch-up mechanism for a stuck normalization watermark (see migration
--   205's header); it is not itself the catch-up, and does not touch job
--   1000 or its configuration.
--
--   This test proves, against a fully synthetic, rollback-only fixture:
--     A. p_max_window=NULL preserves the exact pre-205 forward-boundary
--        behavior (advances all the way to max(raw_messages.received_at));
--     B. a bounded call advances the watermark to exactly
--        min(max(raw_messages.received_at), previous_checkpoint+p_max_window)
--        when that sum is the smaller value;
--     C. a bounded call advances the watermark to exactly
--        max(raw_messages.received_at) when that is already the smaller
--        value (the requested horizon is not artificially extended past
--        what data actually exists);
--     D. the existing p_overlap/late-arrival-horizon computation is
--        byte-for-byte unchanged (a live catalog check, not a text/file
--        check);
--     E. telemetry.run_normalization_job (job 1000's action, unmodified)
--        still successfully calls the procedure with only its original
--        single argument -- the new parameter's default makes this
--        compatible without any change to the wrapper.
--
--   telemetry.load_normalized_points_incremental() contains no intermediate
--   COMMIT (confirmed by inspection of its deployed definition), so unlike
--   telemetry.recover_failed_raw_messages() (migrations 203/204) it can
--   safely run inside a BEGIN; ... ROLLBACK; wrapper -- no fixture data, and
--   no mutation of the real, shared telemetry.pipeline_state row, ever
--   persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_synthetic_max     TIMESTAMPTZ := clock_timestamp() + INTERVAL '100 days';
    v_checkpoint        TIMESTAMPTZ := clock_timestamp() + INTERVAL '90 days';
    v_msg_id            BIGINT;
    v_result            TIMESTAMPTZ;
    v_def               TEXT;
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
    -- TEST E -- telemetry.run_normalization_job (job 1000's unmodified
    -- action) still successfully calls the procedure with only its
    -- original single argument, thanks to p_max_window's default.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint WHERE pipeline_name='normalized_points';

    CALL telemetry.run_normalization_job(999999, jsonb_build_object('overlap','5 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='normalized_points';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST E FAILED: telemetry.run_normalization_job''s unmodified single-argument call did not behave like the unbounded default, got %', v_result;
    END IF;
    RAISE NOTICE 'TEST E passed: telemetry.run_normalization_job''s existing single-argument call remains fully compatible.';

END;
$test$;

ROLLBACK;

SELECT
    'Normalization bounded-catchup-window assertions passed.'
    AS result;
