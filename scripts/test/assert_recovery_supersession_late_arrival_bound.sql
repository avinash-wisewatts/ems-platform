-- ============================================================================
-- File:
--   scripts/test/assert_recovery_supersession_late_arrival_bound.sql
--
-- Purpose:
--   Regression test for migration 201: telemetry.recover_failed_raw_messages()'s
--   per-candidate supersession check against telemetry.v_rtdata had no lower
--   time bound on r2.received_at, so it scanned essentially the entire
--   historical raw_messages hypertable on every loop iteration -- a single
--   real probe of that shape measured 4m33s+ on staging, explaining job
--   1077's consistent 10-minute timeout. The approved fix adds
--   `r2.received_at >= ce.bucket_start`, bounding the search to the
--   candidate bucket's own configured late-arrival tolerance window
--   [bucket_start, bucket_start + capture_interval_seconds +
--   late_arrival_tolerance_seconds] -- the same window the canonical batch
--   pipeline already uses to decide bucket eligibility, using only
--   already-resolved values (no new parameter, no hardcoded duration, no
--   dependence on now() or the candidate's own age).
--
--   This test proves, against a fully synthetic, rollback-only fixture:
--     A. a failed message with no replacement still recovers normally;
--     B. a later sample WITHIN the tolerance window is recognized as a
--        legitimate superseder (the failed message's own row is correctly
--        NOT inserted as a duplicate/stale capture sample);
--     C. a later sample OUTSIDE the tolerance window is NOT treated as a
--        superseder (the failed message recovers exactly as if the
--        out-of-window sample did not exist);
--     D. an old failed message (bucket from 60 days ago) remains fully
--        recoverable -- age never disqualifies recovery;
--     E. the bounded predicate is actually present in the deployed
--        procedure (a live catalog check, not a text/file check), so the
--        historical unbounded scan cannot silently return.
--
--   Everything here runs inside one transaction that is rolled back at the
--   very end -- no fixture data ever persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_protocol          UUID;
    v_profile           UUID;
    v_org               UUID;
    v_site              UUID;
    v_gateway           UUID;
    v_device            UUID;
    v_logical_point     UUID;

    v_interval_secs      CONSTANT INT := 60;
    v_tolerance_secs      CONSTANT INT := 300;

    v_bucket_start       TIMESTAMPTZ;
    v_msg_id             BIGINT;
    v_status             TEXT;
    v_capture_count      INT;
    v_recovered_msg_id   BIGINT;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol to exist on the canonical database';
    END IF;

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_RECOVERY_SUPERSESSION_PROFILE', 'WiseWatts Test', 'RecoverySupersessionTest', 'Recovery Supersession Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Recovery Supersession Test Org', 'RECOVERY_SUPERSESSION_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Recovery Supersession Test Site', 'RECOVERY_SUPERSESSION_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, v_interval_secs, 'WALL_CLOCK', v_tolerance_secs, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Recovery Supersession Test Gateway', 'RECOVERY-SUPERSESSION-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_profile, 'Recovery Supersession Test Device', 'RECOVERY-SUPERSESSION-DEV')
    RETURNING id INTO v_device;

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', 'TEST:RECOVERY:SUPERSESSION:001');

    -- Field mapping so telemetry.v_normalized_points actually produces a
    -- point for the synthetic 'P' payload field -- required for
    -- recover_failed_raw_messages' RECOVERED-vs-RETRY_PENDING classification
    -- to depend on real normalization output rather than always failing to
    -- normalize. Inserting this row auto-enables it for v_device via
    -- config.sync_device_points_after_profile_mapping_change().
    SELECT id INTO v_logical_point FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_logical_point IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point to exist on the canonical database';
    END IF;

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_logical_point, TRUE);

    -- ==================================================================
    -- TEST A -- failed message with no replacement still recovers.
    -- Bucket well in the past (deadline already passed), no competing
    -- raw message for this device/bucket at all.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '2 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:SUPERSESSION:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST A FAILED: expected a failed message with no replacement to recover, got status %', v_status;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND bucket_start = v_bucket_start AND raw_message_id = v_msg_id;

    IF v_capture_count <> 1 THEN
        RAISE EXCEPTION 'TEST A FAILED: expected exactly one capture_bucket_samples row for the recovered message, got %', v_capture_count;
    END IF;

    RAISE NOTICE 'TEST A passed: a failed message with no replacement recovers normally.';

    -- ==================================================================
    -- TEST B -- a later sample WITHIN the tolerance window is recognized
    -- as a legitimate superseder. Bucket membership is decided by event
    -- time (source_timestamp / 'ts'), so both the candidate and the
    -- superseder share the same 60-second bucket; the superseder is
    -- distinguished by a LATER event_time (winning the ROW(...) > ROW(...)
    -- ordering) whose raw message was platform-received late -- 200s after
    -- bucket_start, still inside the 60+300=360s tolerance window.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '3 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '5 seconds', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '5 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '5 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:SUPERSESSION:001')))
    );

    -- Superseding sample: same bucket (event_time = bucket_start+45s, still
    -- < bucket_start+60s), but its raw_messages.received_at (platform
    -- receipt) is 200s after bucket_start -- a late arrival still inside
    -- the tolerance window, and therefore a legitimate superseder.
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '200 seconds', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '45 seconds')::text,
            'P', 1.5
        )))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND bucket_start = v_bucket_start AND raw_message_id = v_msg_id;

    IF v_capture_count <> 0 THEN
        RAISE EXCEPTION 'TEST B FAILED: the failed message''s own row was inserted despite an in-window superseding sample existing (count=%)', v_capture_count;
    END IF;

    RAISE NOTICE 'TEST B passed: an in-window (late-arrived but within tolerance) later sample is recognized as a legitimate superseder (the failed candidate was correctly not inserted as a duplicate).';

    -- ==================================================================
    -- TEST C -- a sample OUTSIDE the tolerance window is NOT treated as a
    -- superseder. This is the exact shape of the historical bug: same
    -- bucket (event_time = bucket_start+45s, wins the ROW(...) ordering
    -- purely on event_time), but its raw_messages.received_at is BEFORE
    -- bucket_start -- a receipt timestamp the old, lower-bound-free query
    -- would have wrongly accepted. The new `r2.received_at>=ce.bucket_start`
    -- bound must exclude it, so the failed candidate recovers normally.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '4 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:SUPERSESSION:001')))
    );

    -- Out-of-window sample: same bucket by event_time, and wins the
    -- ROW(...) ordering, but its own raw_messages.received_at is an hour
    -- BEFORE bucket_start -- outside [bucket_start, deadline]. Under the
    -- pre-migration-201 query (no lower bound) this row would have
    -- incorrectly counted as a superseder; the fix must exclude it.
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start - INTERVAL '1 hour', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '45 seconds')::text,
            'P', 1.5
        )))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status, count(*) OVER () INTO v_status, v_capture_count
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST C FAILED: expected the candidate to recover despite an out-of-window later sample existing, got status %', v_status;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND bucket_start = v_bucket_start AND raw_message_id = v_msg_id;

    IF v_capture_count <> 1 THEN
        RAISE EXCEPTION 'TEST C FAILED: expected the candidate''s own row to be inserted (out-of-window sample must not count as a superseder), got count %', v_capture_count;
    END IF;

    RAISE NOTICE 'TEST C passed: a later sample outside the tolerance window is correctly NOT treated as a superseder.';

    -- ==================================================================
    -- TEST D -- an old failed message (60 days old) remains fully
    -- recoverable. Age must never disqualify recovery; only
    -- replay_attempt_count does.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '60 days');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/supersession',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:SUPERSESSION:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:SUPERSESSION:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST D FAILED: a 60-day-old failed message did not recover, got status %', v_status;
    END IF;

    RAISE NOTICE 'TEST D passed: an old (60-day) failed message remains fully recoverable -- age does not disqualify recovery.';

    -- ==================================================================
    -- TEST E -- the bounded predicate is actually present in the
    -- deployed procedure (live catalog check).
    -- ==================================================================

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        NOT ILIKE '%r2.received_at>=ce.bucket_start%'
    THEN
        RAISE EXCEPTION 'TEST E FAILED: the deployed telemetry.recover_failed_raw_messages() does not contain the lower-bound predicate r2.received_at>=ce.bucket_start -- the historical unbounded scan may have returned';
    END IF;

    RAISE NOTICE 'TEST E passed: the bounded supersession predicate is present in the deployed procedure.';

END;
$test$;

ROLLBACK;

SELECT
    'Recovery supersession late-arrival bound assertions passed.'
    AS result;
