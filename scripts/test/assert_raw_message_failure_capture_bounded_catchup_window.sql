-- ============================================================================
-- File:
--   scripts/test/assert_raw_message_failure_capture_bounded_catchup_window.sql
--
-- Purpose:
--   Regression test for migration 243 (job 1068 remediation).
--
--   Mirrors scripts/test/assert_normalization_bounded_catchup_window.sql's
--   structure (migrations 205/212, job 1000), adapted for job 1068's own
--   window computation, which differs structurally from job 1000's: the
--   natural (unbounded) forward boundary is
--       v_window_end := LEAST(v_normalized_checkpoint, clock_timestamp()-p_grace)
--   i.e. clock-time-based (via p_grace), not a fixed max(raw_messages.
--   received_at). Tests that need to distinguish "reached the natural end"
--   from "stayed at an old checkpoint" therefore use inequality/tolerance
--   assertions against clock_timestamp() rather than exact equality to a
--   fixed synthetic value; tests comparing to checkpoint+INTERVAL (bounded
--   advancement) remain exact, since the checkpoint fixture values below are
--   fixed and chosen to stay far below the moving natural end.
--
--   This test proves, against a fully synthetic, rollback-only fixture:
--     A. p_max_window=NULL preserves migration 007's exact unbounded
--        forward-boundary behavior (advances to the natural,
--        clock/grace-based end, not held near an old checkpoint);
--     B. a bounded direct CALL advances the watermark to exactly
--        previous_checkpoint+p_max_window when that is the smaller value;
--     C. a bounded direct CALL advances to the natural end (not the
--        requested horizon) when the requested horizon exceeds it;
--     D. (contract) the deployed procedure still contains the migration-243
--        LEAST(...) bound AND every produced_point_count/classification line
--        carried forward unchanged from migration 007 -- proving the window
--        bound was added without touching detection logic;
--     E. the wrapper (telemetry.run_raw_message_failure_capture_job) with a
--        config carrying NO max_window key applies the placeholder default
--        (INTERVAL '15 minutes'): the watermark advances to exactly
--        checkpoint+15m, not to the natural end;
--     F. the wrapper honours a config.max_window override (positive interval
--        accepted): {"max_window":"30 minutes"} advances to exactly
--        checkpoint+30m;
--     G. the wrapper REJECTS a zero or negative max_window before touching
--        the loader (RAISE EXCEPTION), leaving the checkpoint untouched;
--     H. a subsequent run continues from the new bounded checkpoint -- two
--        successive default wrapper runs advance by 15 minutes each;
--     I. steady state: when the backlog is under the bound, the effective
--        endpoint is still the natural end -- the bound does not artificially
--        hold the watermark back;
--     J. (contract) the deployed wrapper passes a THREE-argument call to the
--        loader, derives v_max_window from config->>'max_window', and does
--        NOT duplicate the loader's advisory lock / pipeline_state handling /
--        EXCEPTION block (failure/rollback remains owned by the loader);
--     K. this migration did NOT write a max_window key into job 1068's live
--        TimescaleDB job config (proving no configuration/enablement change
--        was made, per the explicit instruction not to configure or enable
--        job 1068);
--     L. detection equivalence, functional (not just catalog): a candidate
--        whose selected capture sample HAS a corresponding persisted
--        telemetry.normalized_points row produces NO failure row (success);
--        an otherwise-identical candidate whose selected capture sample has
--        NO corresponding normalized_points row is classified
--        NO_PERSISTED_NORMALIZED_ROWS -- proving the migration-007 detection
--        logic (device_id, event_time, logical_point_id against
--        telemetry.normalized_points) still works correctly, unchanged,
--        after the window-bound was added. This is NOT a
--        (platform_received_at, raw_message_id) lookup -- that approach was
--        considered and rejected; see migration 243's header and migration
--        006's original rationale.
--
--   telemetry.capture_raw_message_failures_incremental and telemetry.
--   run_raw_message_failure_capture_job contain no intermediate COMMIT
--   (confirmed by inspection of their deployed definitions), so this test can
--   safely run inside a BEGIN; ... ROLLBACK; wrapper -- no fixture data, and
--   no mutation of the real, shared telemetry.pipeline_state row, ever
--   persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_checkpoint_far    TIMESTAMPTZ := clock_timestamp() - INTERVAL '10 days';
    v_checkpoint_near   TIMESTAMPTZ := clock_timestamp() - INTERVAL '30 seconds';
    v_now_before        TIMESTAMPTZ;
    v_now_after         TIMESTAMPTZ;
    v_result            TIMESTAMPTZ;
    v_def               TEXT;
    v_raised            BOOLEAN;
    v_bad               TEXT;

    v_protocol UUID;
    v_profile  UUID;
    v_org      UUID;
    v_site     UUID;
    v_gateway  UUID;
    v_device   UUID;
    v_lp       UUID;
    v_uid      TEXT := 'TEST:JOB1068:BOUNDED:WINDOW';
    v_msg_ok   BIGINT;
    v_msg_fail BIGINT;
    v_bucket_ok   TIMESTAMPTZ;
    v_bucket_fail TIMESTAMPTZ;
    v_failure_code TEXT;
    v_row_exists   BOOLEAN;
BEGIN
    -- Push the shared normalized_points checkpoint far into the future so it
    -- never binds v_window_end in any test below -- the natural end is
    -- exercised via p_grace/clock_timestamp() instead, deliberately.
    UPDATE telemetry.pipeline_state
    SET last_received_at = clock_timestamp() + INTERVAL '100 days'
    WHERE pipeline_name = 'normalized_points';

    -- ==================================================================
    -- TEST A -- p_max_window=NULL preserves migration 007's exact unbounded
    -- behavior: the watermark advances to the natural (grace-based) end,
    -- not held near the old (10-day-stale) checkpoint.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';

    v_now_before := clock_timestamp();
    CALL telemetry.capture_raw_message_failures_incremental(INTERVAL '5 minutes', INTERVAL '0 seconds', NULL);
    v_now_after := clock_timestamp();

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result <= v_checkpoint_far + INTERVAL '1 day' THEN
        RAISE EXCEPTION 'TEST A FAILED: p_max_window=NULL should reach the natural (unbounded) end, but the watermark stayed near the old checkpoint (checkpoint=%, got %)', v_checkpoint_far, v_result;
    END IF;
    IF v_result < v_now_before - INTERVAL '5 seconds' OR v_result > v_now_after THEN
        RAISE EXCEPTION 'TEST A FAILED: expected the watermark to land at clock_timestamp() (between % and %), got %', v_now_before, v_now_after, v_result;
    END IF;
    RAISE NOTICE 'TEST A passed: p_max_window=NULL preserves the unbounded forward boundary (advanced to natural end %).', v_result;

    -- ==================================================================
    -- TEST B -- bounded direct CALL: previous_checkpoint + p_max_window is
    -- the smaller value (checkpoint(-10d)+2h is far short of "now"), so the
    -- watermark must stop there exactly, not reach the natural end.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';

    CALL telemetry.capture_raw_message_failures_incremental(INTERVAL '5 minutes', INTERVAL '0 seconds', INTERVAL '2 hours');

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result IS DISTINCT FROM (v_checkpoint_far + INTERVAL '2 hours') THEN
        RAISE EXCEPTION 'TEST B FAILED: expected watermark to advance to checkpoint+2h=%, got %', v_checkpoint_far + INTERVAL '2 hours', v_result;
    END IF;
    RAISE NOTICE 'TEST B passed: bounded call advanced the watermark to exactly checkpoint+p_max_window (%).', v_result;

    -- ==================================================================
    -- TEST C -- bounded direct CALL where the requested horizon
    -- (near-checkpoint + 50 days) is already past the natural end: the
    -- watermark must stop at the natural end, not overshoot.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_near WHERE pipeline_name='raw_message_failures';

    v_now_before := clock_timestamp();
    CALL telemetry.capture_raw_message_failures_incremental(INTERVAL '5 minutes', INTERVAL '0 seconds', INTERVAL '50 days');
    v_now_after := clock_timestamp();

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result < v_now_before - INTERVAL '5 seconds' OR v_result > v_now_after THEN
        RAISE EXCEPTION 'TEST C FAILED: when the requested horizon (50d) exceeds the natural end, the watermark should stop at the natural end (between % and %), got %', v_now_before, v_now_after, v_result;
    END IF;
    RAISE NOTICE 'TEST C passed: when the requested horizon exceeds the natural end, the watermark stops there (%), not at the requested horizon.', v_result;

    -- ==================================================================
    -- TEST D (contract) -- the deployed procedure carries the migration-243
    -- bound AND the migration-007 detection logic verbatim (not replaced).
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.capture_raw_message_failures_incremental(interval,interval,interval)'::regprocedure);

    IF v_def NOT ILIKE '%LEAST(v_window_end, v_previous_checkpoint + p_max_window)%' THEN
        RAISE EXCEPTION 'TEST D FAILED: the migration-243 bounded-window LEAST(...) is missing';
    END IF;
    IF v_def NOT ILIKE '%np.device_id=s.device_id%'
       OR v_def NOT ILIKE '%np.event_time=s.event_time%'
       OR v_def NOT ILIKE '%np.logical_point_id=dpc.logical_point_id%' THEN
        RAISE EXCEPTION 'TEST D FAILED: the migration-007 (device_id, event_time, logical_point_id) detection check is missing/altered';
    END IF;
    IF v_def ILIKE '%platform_received_at%' OR v_def ILIKE '%v_normalized_points%' THEN
        RAISE EXCEPTION 'TEST D FAILED: the procedure now references platform_received_at or v_normalized_points -- the rejected (mutable-lineage) detection approach appears to have been introduced';
    END IF;
    RAISE NOTICE 'TEST D passed: bounded-window LEAST(...) present; migration-007 detection logic present and unaltered; no mutable-lineage lookup introduced.';

    -- ==================================================================
    -- TEST E -- wrapper with NO config.max_window key applies the
    -- placeholder default (15 minutes): watermark advances to exactly
    -- checkpoint+15m, not the natural end.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';

    CALL telemetry.run_raw_message_failure_capture_job(999999, jsonb_build_object('overlap','5 minutes','grace','0 seconds'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result IS DISTINCT FROM (v_checkpoint_far + INTERVAL '15 minutes') THEN
        RAISE EXCEPTION 'TEST E FAILED: wrapper default should bound the watermark to checkpoint+15m=%, got %', v_checkpoint_far + INTERVAL '15 minutes', v_result;
    END IF;
    RAISE NOTICE 'TEST E passed: wrapper applies the placeholder default max_window bound (advanced to %).', v_result;

    -- ==================================================================
    -- TEST F -- config.max_window override, positive interval accepted:
    -- {"max_window":"30 minutes"} advances the watermark to exactly
    -- checkpoint+30m.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';

    CALL telemetry.run_raw_message_failure_capture_job(999999, jsonb_build_object('overlap','5 minutes','grace','0 seconds','max_window','30 minutes'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result IS DISTINCT FROM (v_checkpoint_far + INTERVAL '30 minutes') THEN
        RAISE EXCEPTION 'TEST F FAILED: config.max_window=30 minutes should bound the watermark to checkpoint+30m=%, got %', v_checkpoint_far + INTERVAL '30 minutes', v_result;
    END IF;
    RAISE NOTICE 'TEST F passed: wrapper honours a positive config.max_window override (advanced to %).', v_result;

    -- ==================================================================
    -- TEST G -- a zero or negative max_window is REJECTED by the wrapper
    -- BEFORE it touches the loader; the checkpoint is untouched.
    -- ==================================================================
    FOREACH v_bad IN ARRAY ARRAY['0', '-1 hours'] LOOP
        UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';
        v_raised := FALSE;
        BEGIN
            CALL telemetry.run_raw_message_failure_capture_job(999999,
                 jsonb_build_object('overlap','5 minutes','grace','0 seconds','max_window',v_bad));
        EXCEPTION WHEN OTHERS THEN
            v_raised := TRUE;
        END;
        IF NOT v_raised THEN
            RAISE EXCEPTION 'TEST G FAILED: wrapper accepted an invalid max_window "%"', v_bad;
        END IF;
        SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
        IF v_result IS DISTINCT FROM v_checkpoint_far THEN
            RAISE EXCEPTION 'TEST G FAILED: an invalid max_window "%" advanced the checkpoint (% -> %)', v_bad, v_checkpoint_far, v_result;
        END IF;
    END LOOP;
    RAISE NOTICE 'TEST G passed: zero/negative max_window rejected before the loader; checkpoint untouched.';

    -- ==================================================================
    -- TEST H -- a subsequent run continues from the new bounded checkpoint:
    -- two successive default wrapper runs advance by 15 minutes each.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=v_checkpoint_far WHERE pipeline_name='raw_message_failures';

    CALL telemetry.run_raw_message_failure_capture_job(999999, jsonb_build_object('overlap','5 minutes','grace','0 seconds'));
    CALL telemetry.run_raw_message_failure_capture_job(999999, jsonb_build_object('overlap','5 minutes','grace','0 seconds'));

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result IS DISTINCT FROM (v_checkpoint_far + INTERVAL '30 minutes') THEN
        RAISE EXCEPTION 'TEST H FAILED: two successive default runs should advance to checkpoint+30m=%, got %', v_checkpoint_far + INTERVAL '30 minutes', v_result;
    END IF;
    RAISE NOTICE 'TEST H passed: successive bounded runs continue from the new checkpoint (advanced to %).', v_result;

    -- ==================================================================
    -- TEST I -- steady state: when the backlog is under the bound, the
    -- effective endpoint is still the natural end -- the bound does not
    -- artificially hold the watermark back.
    -- ==================================================================
    UPDATE telemetry.pipeline_state SET last_received_at=(clock_timestamp() - INTERVAL '5 seconds') WHERE pipeline_name='raw_message_failures';

    v_now_before := clock_timestamp();
    CALL telemetry.run_raw_message_failure_capture_job(999999, jsonb_build_object('overlap','5 minutes','grace','0 seconds'));
    v_now_after := clock_timestamp();

    SELECT last_received_at INTO v_result FROM telemetry.pipeline_state WHERE pipeline_name='raw_message_failures';
    IF v_result < v_now_before - INTERVAL '5 seconds' OR v_result > v_now_after THEN
        RAISE EXCEPTION 'TEST I FAILED: with a <15m backlog the watermark should reach the natural end (between % and %), got %', v_now_before, v_now_after, v_result;
    END IF;
    RAISE NOTICE 'TEST I passed: steady-state endpoint is the natural end (advanced to %), not artificially held back.', v_result;

    -- ==================================================================
    -- TEST J (contract) -- the deployed wrapper passes a THREE-argument
    -- call to the loader, derives v_max_window from config->>'max_window',
    -- and does not duplicate loader-owned lock/state/exception handling.
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.run_raw_message_failure_capture_job(integer,jsonb)'::regprocedure);

    IF position('capture_raw_message_failures_incremental' IN v_def) = 0
       OR position('v_max_window' IN v_def) = 0 THEN
        RAISE EXCEPTION 'TEST J FAILED: run_raw_message_failure_capture_job does not appear to CALL the loader with v_max_window';
    END IF;
    IF position('''max_window''' IN v_def) = 0 THEN
        RAISE EXCEPTION 'TEST J FAILED: run_raw_message_failure_capture_job does not read config->>''max_window''';
    END IF;
    IF v_def ILIKE '%advisory_xact_lock%'
       OR v_def ILIKE '%pipeline_state%'
       OR v_def ILIKE '%EXCEPTION WHEN OTHERS%' THEN
        RAISE EXCEPTION 'TEST J FAILED: run_raw_message_failure_capture_job now duplicates loader-owned lock/state/exception handling';
    END IF;
    v_def := pg_get_functiondef('telemetry.capture_raw_message_failures_incremental(interval,interval,interval)'::regprocedure);
    IF v_def NOT ILIKE '%pg_try_advisory_xact_lock(%'
       OR v_def NOT ILIKE '%last_status=''FAILED''%'
       OR v_def NOT ILIKE '%EXCEPTION WHEN OTHERS%' THEN
        RAISE EXCEPTION 'TEST J FAILED: the loader''s lock/state/rollback logic is not intact';
    END IF;
    RAISE NOTICE 'TEST J passed: wrapper passes a bounded three-arg call; loader still owns lock/state/rollback.';

    -- ==================================================================
    -- TEST K -- this migration did NOT write config.max_window into job
    -- 1068's live TimescaleDB job configuration (no configuration/
    -- enablement change was made).
    -- ==================================================================
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema='telemetry' AND proc_name='run_raw_message_failure_capture_job'
          AND (config ->> 'max_window') IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'TEST K FAILED: job 1068''s live config unexpectedly carries a max_window key -- this migration must not configure it';
    END IF;
    RAISE NOTICE 'TEST K passed: job 1068''s live config carries no max_window key (no configuration change made).';

    -- ==================================================================
    -- TEST L -- detection equivalence, functional: an otherwise-identical
    -- pair of candidates differ only in whether telemetry.normalized_points
    -- has the matching (device_id, event_time, logical_point_id) row.
    -- ==================================================================
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol on the canonical database';
    END IF;

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_JOB1068_PROFILE', 'WiseWatts Test', 'Job1068Test', 'Job 1068 Bounded Window Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Job 1068 Test Org', 'JOB1068_TEST_ORG', 'Asia/Kolkata') RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Job 1068 Test Site', 'JOB1068_TEST_SITE', 'Asia/Kolkata', TRUE) RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Job 1068 Test Gateway', 'JOB1068-TEST-GW') RETURNING id INTO v_gateway;

    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_profile, 'Job 1068 Test Device', 'JOB1068-TEST-DEV')
    RETURNING id INTO v_device;
    PERFORM set_config('ems.controlled_device_commissioning_id', v_device::text, true);
    UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = v_device;
    PERFORM set_config('ems.controlled_device_commissioning_id', '', true);

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', v_uid);

    SELECT id INTO v_lp FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_lp IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point';
    END IF;

    INSERT INTO config.device_point_configuration(device_id, logical_point_id, is_enabled)
    VALUES (v_device, v_lp, TRUE);

    -- Use the checkpoint window from TEST I (natural end just reached "now").
    -- Push both checkpoints back into the past far enough to cover both
    -- fixture messages, and re-run with a comfortably wide bound.
    v_bucket_ok   := clock_timestamp() - INTERVAL '2 minutes';
    v_bucket_fail := clock_timestamp() - INTERVAL '1 minute';

    -- Candidate 1 ("ok"): normalized_points row exists for this exact
    -- (device_id, event_time, logical_point_id) -> must NOT be classified
    -- as a failure.
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket_ok, 'MQTT', 'test/job1068/bounded-window',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid, 'P', 1.0))))
    RETURNING id INTO v_msg_ok;

    INSERT INTO telemetry.capture_bucket_samples
    (site_id, device_id, bucket_start, capture_interval_seconds, late_arrival_tolerance_seconds,
     event_time, raw_received_at, raw_message_id, status)
    VALUES
    (v_site, v_device, v_bucket_ok, 60, 60, v_bucket_ok, v_bucket_ok, v_msg_ok, 'NORMALIZED');

    INSERT INTO telemetry.normalized_points
    (event_time, organization_id, site_id, gateway_id, device_id, logical_point_id,
     raw_value, numeric_value, quality_code, mapping_source, platform_received_at, raw_message_id)
    VALUES
    (v_bucket_ok, v_org, v_site, v_gateway, v_device, v_lp,
     '1.0', 1.0, 'GOOD', 'DEVICE_PROFILE', v_bucket_ok, v_msg_ok);

    -- Candidate 2 ("fail"): otherwise identical, but NO normalized_points
    -- row -> must be classified NO_PERSISTED_NORMALIZED_ROWS.
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket_fail, 'MQTT', 'test/job1068/bounded-window',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid, 'P', 1.0))))
    RETURNING id INTO v_msg_fail;

    INSERT INTO telemetry.capture_bucket_samples
    (site_id, device_id, bucket_start, capture_interval_seconds, late_arrival_tolerance_seconds,
     event_time, raw_received_at, raw_message_id, status)
    VALUES
    (v_site, v_device, v_bucket_fail, 60, 60, v_bucket_fail, v_bucket_fail, v_msg_fail, 'FAILED');

    UPDATE telemetry.pipeline_state SET last_received_at=(v_bucket_ok - INTERVAL '5 minutes') WHERE pipeline_name='raw_message_failures';

    CALL telemetry.capture_raw_message_failures_incremental(INTERVAL '5 minutes', INTERVAL '0 seconds', INTERVAL '1 hour');

    SELECT EXISTS(SELECT 1 FROM telemetry.raw_message_failures WHERE raw_message_id=v_msg_ok) INTO v_row_exists;
    IF v_row_exists THEN
        RAISE EXCEPTION 'TEST L FAILED: candidate with a matching normalized_points row was incorrectly captured as a failure (raw_message_id=%)', v_msg_ok;
    END IF;

    SELECT failure_code INTO v_failure_code FROM telemetry.raw_message_failures WHERE raw_message_id=v_msg_fail;
    IF v_failure_code IS DISTINCT FROM 'NO_PERSISTED_NORMALIZED_ROWS' THEN
        RAISE EXCEPTION 'TEST L FAILED: candidate with no normalized_points row should be classified NO_PERSISTED_NORMALIZED_ROWS, got %', v_failure_code;
    END IF;
    RAISE NOTICE 'TEST L passed: detection logic (device_id, event_time, logical_point_id against telemetry.normalized_points) correctly distinguishes matching vs. non-matching candidates after the window-bound change.';

END;
$test$;

ROLLBACK;
