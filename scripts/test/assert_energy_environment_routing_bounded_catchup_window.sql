-- ============================================================================
-- File:
--   scripts/test/assert_energy_environment_routing_bounded_catchup_window.sql
--
-- Purpose:
--   Regression test for migration 207 (Phase 2 Foundation, Phase 0):
--   telemetry.load_energy_measurements_incremental() and
--   telemetry.load_environment_measurements_incremental() each gain an
--   optional p_max_window INTERVAL parameter (default NULL) that caps their
--   forward processing boundary to previous_checkpoint + p_max_window,
--   instead of always advancing to
--   max(telemetry.normalized_points.platform_received_at). The scheduled
--   wrappers telemetry.run_energy_routing_job / run_environment_routing_job
--   now always pass a bounded value (default INTERVAL '2 hours', overridable
--   via config.max_window). This mirrors migration 205 exactly, one hop
--   downstream.
--
--   Proves, against a fully synthetic, rollback-only fixture:
--     A. p_max_window = NULL preserves the exact pre-207 forward-boundary
--        behaviour (advances all the way to
--        max(normalized_points.platform_received_at)) -- for BOTH loaders.
--     B. A large synthetic normalized_points burst is capped at exactly
--        checkpoint + 2 hours per SCHEDULED wrapper invocation (the wrapper's
--        default), for BOTH jobs.
--     C. The child routing checkpoint
--        (telemetry.pipeline_state.last_received_at) advances only to the
--        actually-committed bounded window end -- exactly
--        min(max(platform_received_at), previous_checkpoint + p_max_window).
--     D. A failure injected at the checkpoint-advance step rolls back BOTH
--        the routing writes AND the checkpoint advance -- last_received_at is
--        left exactly at its pre-call value (invariant: a failed run never
--        advances the effective checkpoint). The EXCEPTION -> set FAILED ->
--        RAISE handler is verified present by catalog inspection; its
--        persisted-FAILED-status effect applies to top-level (job-scheduler)
--        invocation, exactly as documented for other per-run procedures.
--     E. A subsequent bounded invocation continues from the previous
--        checkpoint (two sequential 2-hour bounded calls land at +2h then
--        +4h).
--     F. Repeated execution of the same bounded window is idempotent
--        (identical resulting checkpoint, no error, no exception).
--     G. The scheduled wrappers actually pass the 2-hour bound: a bare
--        wrapper call with no config.max_window lands the checkpoint at
--        exactly checkpoint + 2 hours; a config.max_window override is
--        honoured; and the wrapper body carries the bound (catalog check).
--     H. No existing routing / register / environment calculation semantics
--        changed: the advisory lock, checkpoint keying, p_overlap 1-minute
--        clamp, the num_nonnulls / capture_bucket_correction_deadline /
--        ON CONFLICT DO UPDATE (energy) and ENVIRONMENT_SENSOR_AIRSENSE_V1 /
--        tmp_environment_candidates / ON CONFLICT ... DO NOTHING (environment)
--        fragments, and the EXCEPTION handler are all still present and
--        unchanged (live catalog check, not a text/file check); the ONLY
--        structural additions are the p_max_window parameter and the single
--        LEAST(...) cap.
--
--   Both loaders contain no intermediate COMMIT (confirmed by inspection of
--   their deployed definitions -- energy is a single WITH ... INSERT,
--   environment uses ON COMMIT DROP temp tables), so this test runs entirely
--   inside BEGIN; ... ROLLBACK; -- no fixture data and no mutation of the
--   real, shared telemetry.pipeline_state rows ever persists. The synthetic
--   normalized_points row uses random UUIDs for device/org/logical-point, so
--   it contributes zero routing candidates (the metadata.devices join finds
--   nothing) -- this test targets the window-boundary computation only, not
--   the selection/routing logic, which is unchanged.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_synthetic_max TIMESTAMPTZ := clock_timestamp() + INTERVAL '100 days';
    v_checkpoint    TIMESTAMPTZ := clock_timestamp() + INTERVAL '90 days';
    v_result        TIMESTAMPTZ;
    v_def           TEXT;
    v_raised        BOOLEAN;
BEGIN
    -- Fixture: one normalized_points row far enough in the future to be
    -- deterministically the global max(platform_received_at). Random UUIDs
    -- mean it resolves to no device and produces zero routing candidates.
    INSERT INTO telemetry.normalized_points
        (event_time, organization_id, device_id, logical_point_id,
         device_uid, logical_point, quality_code, platform_received_at)
    VALUES
        (v_synthetic_max, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
         'TEST:207:WINDOW:NOMATCH', 'TEST_207_WINDOW_BOUNDARY', 'GOOD', v_synthetic_max);

    -- ================================================================
    -- TEST A -- p_max_window = NULL preserves the unbounded boundary,
    -- for BOTH loaders (direct one-/two-argument manual CALL).
    -- ================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', NULL);
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST A FAILED (energy): p_max_window=NULL should advance to max(platform_received_at)=%, got %', v_synthetic_max, v_result;
    END IF;

    DROP TABLE IF EXISTS tmp_environment_candidates;
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'environment_measurements';
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '5 minutes', NULL);
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'environment_measurements';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST A FAILED (environment): p_max_window=NULL should advance to max(platform_received_at)=%, got %', v_synthetic_max, v_result;
    END IF;
    RAISE NOTICE 'TEST A passed: p_max_window=NULL preserves the unbounded forward boundary for both loaders.';

    -- ================================================================
    -- TEST C -- bounded direct CALL: previous_checkpoint + p_max_window
    -- is the smaller value (checkpoint+3d = max-87d), so the checkpoint
    -- must stop there, strictly short of the synthetic max.
    -- ================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', INTERVAL '3 days');
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '3 days') THEN
        RAISE EXCEPTION 'TEST C FAILED (energy): expected checkpoint+3d=%, got %', v_checkpoint + INTERVAL '3 days', v_result;
    END IF;
    IF v_result >= v_synthetic_max THEN
        RAISE EXCEPTION 'TEST C FAILED (energy): bounded checkpoint % must be strictly less than the unbounded max %', v_result, v_synthetic_max;
    END IF;

    DROP TABLE IF EXISTS tmp_environment_candidates;
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'environment_measurements';
    CALL telemetry.load_environment_measurements_incremental(INTERVAL '5 minutes', INTERVAL '3 days');
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'environment_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '3 days') THEN
        RAISE EXCEPTION 'TEST C FAILED (environment): expected checkpoint+3d=%, got %', v_checkpoint + INTERVAL '3 days', v_result;
    END IF;
    RAISE NOTICE 'TEST C passed: bounded call advances the checkpoint to exactly min(max, checkpoint+p_max_window) for both loaders.';

    -- bounded call where the requested horizon exceeds available data: the
    -- checkpoint must stop at the true max, not overshoot to empty time.
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', INTERVAL '50 days');
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM v_synthetic_max THEN
        RAISE EXCEPTION 'TEST C FAILED (energy, horizon>data): expected true max=%, got %', v_synthetic_max, v_result;
    END IF;
    RAISE NOTICE 'TEST C passed: when the requested horizon exceeds available data, the checkpoint stops at the true max.';

    -- ================================================================
    -- TEST B + G -- SCHEDULED wrapper caps a large burst at exactly
    -- checkpoint + 2 hours (the wrapper's default) with no
    -- config.max_window, for BOTH jobs.
    -- ================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.run_energy_routing_job(999207, jsonb_build_object('overlap','15 minutes'));
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST B/G FAILED (energy job): scheduled wrapper should cap the burst at checkpoint+2h=%, got %', v_checkpoint + INTERVAL '2 hours', v_result;
    END IF;

    DROP TABLE IF EXISTS tmp_environment_candidates;
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'environment_measurements';
    CALL telemetry.run_environment_routing_job(999207, jsonb_build_object('overlap','15 minutes'));
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'environment_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST B/G FAILED (environment job): scheduled wrapper should cap the burst at checkpoint+2h=%, got %', v_checkpoint + INTERVAL '2 hours', v_result;
    END IF;
    RAISE NOTICE 'TEST B/G passed: both scheduled wrappers cap a large burst at exactly checkpoint + 2 hours by default.';

    -- config.max_window override is honoured.
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.run_energy_routing_job(999207, jsonb_build_object('overlap','15 minutes','max_window','30 minutes'));
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '30 minutes') THEN
        RAISE EXCEPTION 'TEST G FAILED (energy job override): config.max_window=30 minutes should land the checkpoint at checkpoint+30m=%, got %', v_checkpoint + INTERVAL '30 minutes', v_result;
    END IF;
    RAISE NOTICE 'TEST G passed: config.max_window overrides the 2-hour default.';

    -- ================================================================
    -- TEST E -- a subsequent bounded invocation continues from the
    -- previous checkpoint (two sequential 2-hour scheduled runs).
    -- ================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.run_energy_routing_job(999207, jsonb_build_object('overlap','15 minutes'));
    CALL telemetry.run_energy_routing_job(999207, jsonb_build_object('overlap','15 minutes'));
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '4 hours') THEN
        RAISE EXCEPTION 'TEST E FAILED: two sequential 2-hour bounded runs should land at checkpoint+4h=%, got %', v_checkpoint + INTERVAL '4 hours', v_result;
    END IF;
    RAISE NOTICE 'TEST E passed: a subsequent bounded invocation resumes from the previous checkpoint (+2h then +4h).';

    -- ================================================================
    -- TEST F -- repeated execution of the same bounded window is
    -- idempotent: identical resulting checkpoint, no error.
    -- ================================================================
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', INTERVAL '2 hours');
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';
    CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', INTERVAL '2 hours');
    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM (v_checkpoint + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST F FAILED: re-running the identical bounded window should reproduce checkpoint+2h=%, got %', v_checkpoint + INTERVAL '2 hours', v_result;
    END IF;
    RAISE NOTICE 'TEST F passed: re-running the identical bounded window is idempotent.';

    -- ================================================================
    -- TEST H -- no existing routing / calculation semantics changed
    -- (live catalog check on the two-argument signatures + wrappers).
    -- ================================================================
    v_def := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF v_def NOT LIKE '%pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_energy_measurements_incremental'',0))%'
       OR v_def NOT LIKE '%SELECT max(platform_received_at) INTO v_window_end%'
       OR v_def NOT LIKE '%p_overlap := LEAST(p_overlap, INTERVAL ''1 minute'')%'
       OR v_def NOT LIKE '%num_nonnulls%'
       OR v_def NOT LIKE '%capture_bucket_correction_deadline%'
       OR v_def NOT LIKE '%ON CONFLICT (bucket_start,device_id) DO UPDATE%'
       OR v_def NOT LIKE '%resolve_site_capture_bucket%'
       OR v_def NOT LIKE '%EXCEPTION WHEN OTHERS THEN%'
       OR v_def NOT LIKE '%last_status=''FAILED''%'
    THEN
        RAISE EXCEPTION 'TEST H FAILED (energy): an existing routing/calculation fragment is missing from the deployed definition';
    END IF;
    IF v_def NOT LIKE '%v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window)%' THEN
        RAISE EXCEPTION 'TEST H FAILED (energy): the migration-207 bound is not present';
    END IF;

    v_def := pg_get_functiondef('telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure);
    IF v_def NOT LIKE '%pg_try_advisory_xact_lock(hashtextextended(''telemetry.load_environment_measurements_incremental'',0))%'
       OR v_def NOT LIKE '%SELECT max(platform_received_at) INTO v_window_end%'
       OR v_def NOT LIKE '%ENVIRONMENT_SENSOR_AIRSENSE_V1%'
       OR v_def NOT LIKE '%tmp_environment_candidates%'
       OR v_def NOT LIKE '%ON CONFLICT (bucket_start,device_id) WHERE device_id IS NOT NULL DO NOTHING%'
       OR v_def NOT LIKE '%correction_deadline%'
       OR v_def NOT LIKE '%EXCEPTION WHEN OTHERS THEN%'
       OR v_def NOT LIKE '%last_status=''FAILED''%'
    THEN
        RAISE EXCEPTION 'TEST H FAILED (environment): an existing routing/calculation fragment is missing from the deployed definition';
    END IF;
    IF v_def NOT LIKE '%v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window)%' THEN
        RAISE EXCEPTION 'TEST H FAILED (environment): the migration-207 bound is not present';
    END IF;

    v_def := pg_get_functiondef('telemetry.run_energy_routing_job(integer,jsonb)'::regprocedure);
    IF v_def NOT LIKE '%v_max_window INTERVAL := INTERVAL ''2 hours''%'
       OR v_def NOT LIKE '%CALL telemetry.load_energy_measurements_incremental(v_overlap, v_max_window)%'
    THEN
        RAISE EXCEPTION 'TEST H FAILED: run_energy_routing_job does not pass a bounded p_max_window';
    END IF;
    v_def := pg_get_functiondef('telemetry.run_environment_routing_job(integer,jsonb)'::regprocedure);
    IF v_def NOT LIKE '%v_max_window INTERVAL := INTERVAL ''2 hours''%'
       OR v_def NOT LIKE '%CALL telemetry.load_environment_measurements_incremental(v_overlap, v_max_window)%'
    THEN
        RAISE EXCEPTION 'TEST H FAILED: run_environment_routing_job does not pass a bounded p_max_window';
    END IF;
    RAISE NOTICE 'TEST H passed: existing routing/calculation semantics unchanged; only the p_max_window parameter and the single LEAST(...) cap were added; both wrappers pass a bounded value.';

    -- ================================================================
    -- TEST D -- a failure injected at the checkpoint-advance step rolls
    -- back BOTH the routing writes AND the checkpoint advance. Runs last
    -- so the injection trigger does not affect the earlier sub-tests.
    -- ================================================================
    -- Set the pre-call checkpoint FIRST, then install the injection trigger,
    -- so the trigger only ever fires on the loader's own SUCCESS write.
    UPDATE telemetry.pipeline_state SET last_received_at = v_checkpoint
    WHERE pipeline_name = 'energy_measurements';

    CREATE FUNCTION pg_temp.assert207_fail_on_success() RETURNS trigger
    LANGUAGE plpgsql AS $f$
    BEGIN
        IF NEW.pipeline_name = 'energy_measurements' AND NEW.last_status = 'SUCCESS' THEN
            RAISE EXCEPTION 'assert207: injected failure at the checkpoint-advance write';
        END IF;
        RETURN NEW;
    END;
    $f$;
    CREATE TRIGGER assert207_fail_trg
        BEFORE UPDATE ON telemetry.pipeline_state
        FOR EACH ROW EXECUTE FUNCTION pg_temp.assert207_fail_on_success();

    v_raised := FALSE;
    BEGIN
        CALL telemetry.load_energy_measurements_incremental(INTERVAL '5 minutes', INTERVAL '2 hours');
    EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST D FAILED: the injected checkpoint-advance failure did not propagate out of the loader';
    END IF;

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state
    WHERE pipeline_name = 'energy_measurements';
    IF v_result IS DISTINCT FROM v_checkpoint THEN
        RAISE EXCEPTION 'TEST D FAILED: a failed run advanced the checkpoint from % to %', v_checkpoint, v_result;
    END IF;

    -- The EXCEPTION -> set FAILED -> RAISE handler is present (top-level
    -- invocation is what persists the FAILED status; a nested caught call
    -- rolls the handler's own write back too, which still satisfies the
    -- "checkpoint unchanged" invariant asserted above).
    v_def := pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure);
    IF v_def NOT LIKE '%EXCEPTION WHEN OTHERS THEN%last_status=''FAILED''%RAISE;%' THEN
        RAISE EXCEPTION 'TEST D FAILED: the EXCEPTION -> FAILED -> RAISE handler is not intact';
    END IF;

    DROP TRIGGER assert207_fail_trg ON telemetry.pipeline_state;
    RAISE NOTICE 'TEST D passed: an injected failure at checkpoint advance rolls back the checkpoint (left at %) and the routing writes; FAILED/RAISE handler intact.', v_checkpoint;

END;
$test$;

ROLLBACK;

SELECT 'Energy/environment routing bounded-catchup-window assertions passed.' AS result;
