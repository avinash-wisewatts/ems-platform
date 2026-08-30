-- ============================================================================
-- File:
--   scripts/test/assert_recovery_onboarding_aware_deferral.sql
--
-- Purpose:
--   Regression test for migration 218: telemetry.recover_failed_raw_messages()
--   is now onboarding-aware. Before the expensive current_elements CTE /
--   migration-204 supersession NOT EXISTS / resolve_site_capture_bucket() /
--   normalized_points_for_recovery_candidate() work -- and AFTER the
--   migration-206 retention branch -- it resolves the candidate's source MQTT
--   UID via metadata.device_identifiers -> metadata.devices. A candidate whose
--   UID does not resolve to a commissioned (lifecycle_status='ACTIVE'),
--   profiled device is set to DEFERRED_UNCOMMISSIONED (retryable), not
--   PERMANENT_FAILURE, and re-joins the normal recovery path automatically
--   once the device is commissioned.
--
--   Proven against a fully synthetic fixture:
--     T1  a candidate for a REGISTERED (not commissioned) device is set to
--         DEFERRED_UNCOMMISSIONED with replay_attempt_count NOT advanced,
--         next_replay_at in the future, an explicit DEVICE_NOT_COMMISSIONED
--         reason, and ZERO capture_bucket_samples rows (the expensive path
--         was skipped, not merely that the final status matches);
--     T2  commissioning the device (lifecycle_status -> 'ACTIVE') makes the
--         same deferred candidate eligible again: the next bare CALL runs the
--         full, unchanged recovery path and the candidate reaches RECOVERED --
--         no operator step, no data loss;
--     T3  a candidate whose source UID resolves to no device at all is also
--         DEFERRED_UNCOMMISSIONED (not PERMANENT_FAILURE), ZERO capture rows;
--     T4  a retention-expired candidate on a not-commissioned device is still
--         PERMANENT_FAILURE (migration 206 precedence -- the retention branch
--         runs before the deferral branch), NOT DEFERRED_UNCOMMISSIONED;
--     T5  structural: the deployed procedure's loop also selects
--         DEFERRED_UNCOMMISSIONED rows; the onboarding branch
--         (v_device_eligible / d.lifecycle_status='ACTIVE' /
--         DEVICE_NOT_COMMISSIONED) appears BEFORE "WITH current_elements AS
--         MATERIALIZED"; the migration-206 retention branch and migration-204
--         supersession subquery are still present;
--     T6  raw_message_failures_resolution_status_ck admits
--         DEFERRED_UNCOMMISSIONED and raw_message_failures_recovery_due_idx's
--         partial predicate includes it.
--
--   Migration 203 note: telemetry.recover_failed_raw_messages() commits after
--   each candidate and MUST be invoked as a bare top-level CALL. Fixture rows
--   are identified by distinctive business keys and explicitly deleted at the
--   end (no ROLLBACK), matching the sibling recovery tests.
-- ============================================================================

DO $test$
DECLARE
    v_protocol       UUID;
    v_profile        UUID;
    v_org            UUID;
    v_site           UUID;
    v_gateway        UUID;
    v_device         UUID;
    v_logical_point  UUID;

    v_interval_secs  CONSTANT INT := 60;
    v_tolerance_secs CONSTANT INT := 300;

    v_uid            CONSTANT TEXT := 'TEST:RECOVERY:ONBOARDING:001';
    v_uid_nodevice   CONSTANT TEXT := 'TEST:RECOVERY:ONBOARDING:NODEVICE';

    v_retention_interval INTERVAL;
    v_bucket_start   TIMESTAMPTZ;
    v_msg_id         BIGINT;
    v_status         TEXT;
    v_attempts       INT;
    v_next_replay    TIMESTAMPTZ;
    v_err            TEXT;
    v_capture_count  INT;
    v_def            TEXT;
    v_pos_branch     INT;
    v_pos_expensive  INT;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol to exist on the canonical database';
    END IF;

    SELECT (config->>'drop_after')::interval
      INTO v_retention_interval
    FROM timescaledb_information.jobs
    WHERE proc_schema='_timescaledb_functions'
      AND proc_name='policy_retention'
      AND hypertable_schema='telemetry'
      AND hypertable_name='raw_messages';
    IF v_retention_interval IS NULL THEN
        RAISE EXCEPTION 'Test setup requires a deployed policy_retention job for telemetry.raw_messages';
    END IF;

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_RECOVERY_ONBOARDING_PROFILE', 'WiseWatts Test', 'RecoveryOnboardingTest', 'Recovery Onboarding Aware Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Recovery Onboarding Test Org', 'RECOVERY_ONBOARDING_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Recovery Onboarding Test Site', 'RECOVERY_ONBOARDING_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, v_interval_secs, 'WALL_CLOCK', v_tolerance_secs, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Recovery Onboarding Test Gateway', 'RECOVERY-ONBOARDING-GW')
    RETURNING id INTO v_gateway;

    -- Deliberately NOT commissioned: default lifecycle_status is 'REGISTERED'.
    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_profile, 'Recovery Onboarding Test Device', 'RECOVERY-ONBOARDING-DEV')
    RETURNING id INTO v_device;

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', v_uid);

    SELECT id INTO v_logical_point FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_logical_point IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point to exist on the canonical database';
    END IF;

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_logical_point, TRUE);

    -- A single recoverable raw packet, 2 hours old (well inside retention).
    v_bucket_start := date_trunc('minute', now() - INTERVAL '2 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/onboarding-aware',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', v_uid,
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    -- NOTE: source_identifier is set (the migration-218 branch reads it).
    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uid,
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid)))
    );

    -- ==================================================================
    -- T1 -- REGISTERED device -> DEFERRED_UNCOMMISSIONED, cheaply.
    -- ==================================================================
    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status, replay_attempt_count, next_replay_at, last_replay_error
      INTO v_status, v_attempts, v_next_replay, v_err
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'DEFERRED_UNCOMMISSIONED' THEN
        RAISE EXCEPTION 'T1 FAILED: a candidate for a REGISTERED device must be DEFERRED_UNCOMMISSIONED, got %', v_status;
    END IF;
    IF v_attempts <> 0 THEN
        RAISE EXCEPTION 'T1 FAILED: a deferral must not consume a replay attempt (replay_attempt_count = %, expected 0)', v_attempts;
    END IF;
    IF v_next_replay IS NULL OR v_next_replay <= clock_timestamp() THEN
        RAISE EXCEPTION 'T1 FAILED: next_replay_at must be set in the future for a deferred candidate, got %', v_next_replay;
    END IF;
    IF v_err IS NULL OR v_err NOT LIKE 'DEVICE_NOT_COMMISSIONED:%' THEN
        RAISE EXCEPTION 'T1 FAILED: last_replay_error must carry the DEVICE_NOT_COMMISSIONED reason, got %', v_err;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND raw_message_id = v_msg_id;
    IF v_capture_count <> 0 THEN
        RAISE EXCEPTION 'T1 FAILED: the expensive recovery path must be skipped for an uncommissioned device, found % capture_bucket_samples row(s)', v_capture_count;
    END IF;

    RAISE NOTICE 'T1 passed: REGISTERED-device candidate deferred cheaply (no capture rows, no attempt consumed, DEVICE_NOT_COMMISSIONED reason).';

    -- ==================================================================
    -- T2 -- commission the device; the deferred candidate becomes eligible
    -- again on the next bare CALL and recovers through the full path.
    -- ==================================================================
    -- Reach ACTIVE the one controlled way metadata.reject_uncommissioned_
    -- active_device() permits: as ems_admin with ems.controlled_device_
    -- commissioning_id set to this device id -- exactly what
    -- admin.commission_device() does.
    PERFORM set_config('ems.controlled_device_commissioning_id', v_device::text, true);
    UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = v_device;
    PERFORM set_config('ems.controlled_device_commissioning_id', '', true);

    -- T1 deferred the candidate with next_replay_at = clock_timestamp() + 1h
    -- (asserted above). The recovery loop only re-scans a
    -- DEFERRED_UNCOMMISSIONED row once coalesce(next_replay_at,...) <=
    -- clock_timestamp(), i.e. on the FIRST scheduled Job 1077 run at or after
    -- that hour elapses. Wind next_replay_at back to simulate that run
    -- arriving after the device was commissioned -- exactly the automatic,
    -- no-operator-step re-join the migration documents.
    UPDATE telemetry.raw_message_failures
    SET next_replay_at = clock_timestamp() - INTERVAL '1 minute'
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'T2 FAILED: after commissioning, the previously deferred candidate must run the normal path and recover, got %', v_status;
    END IF;
    RAISE NOTICE 'T2 passed: commissioning (lifecycle_status=ACTIVE) made the deferred candidate eligible again and it recovered automatically.';

    -- ==================================================================
    -- T3 -- source UID resolves to no device -> DEFERRED_UNCOMMISSIONED.
    -- ==================================================================
    v_bucket_start := date_trunc('minute', now() - INTERVAL '90 minutes');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '5 seconds', 'MQTT', 'test/recovery/onboarding-aware',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid_nodevice, 'P', 1.0)))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload
    ) VALUES (
        v_bucket_start + INTERVAL '5 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uid_nodevice,
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid_nodevice)))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '5 seconds' AND raw_message_id = v_msg_id;
    IF v_status <> 'DEFERRED_UNCOMMISSIONED' THEN
        RAISE EXCEPTION 'T3 FAILED: a candidate whose UID resolves to no device must be DEFERRED_UNCOMMISSIONED, got %', v_status;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples WHERE raw_message_id = v_msg_id;
    IF v_capture_count <> 0 THEN
        RAISE EXCEPTION 'T3 FAILED: no-device candidate must skip the expensive path, found % capture row(s)', v_capture_count;
    END IF;
    RAISE NOTICE 'T3 passed: no-device candidate deferred cheaply.';

    -- ==================================================================
    -- T4 -- retention precedence: aged-out candidate on a not-commissioned
    -- device is PERMANENT_FAILURE (migration 206), NOT deferred.
    -- ==================================================================
    UPDATE metadata.devices SET lifecycle_status = 'REGISTERED' WHERE id = v_device;
    v_bucket_start := date_trunc('minute', now() - (v_retention_interval + INTERVAL '1 day'));

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/onboarding-aware',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid, 'P', 1.0)))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uid,
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uid)))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;
    IF v_status <> 'PERMANENT_FAILURE' THEN
        RAISE EXCEPTION 'T4 FAILED: a retention-expired candidate must be PERMANENT_FAILURE even for an uncommissioned device (retention branch precedes the deferral branch), got %', v_status;
    END IF;
    RAISE NOTICE 'T4 passed: retention precedence preserved -- aged-out candidate is PERMANENT_FAILURE, not DEFERRED_UNCOMMISSIONED.';

    -- ==================================================================
    -- T5 -- structural: loop selects DEFERRED_UNCOMMISSIONED; the onboarding
    -- branch precedes the expensive CTE; 206 retention + 204 supersession
    -- still present.
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure);

    IF v_def NOT ILIKE '%resolution_status IN (%OPEN%RETRY_PENDING%DEFERRED_UNCOMMISSIONED%)%' THEN
        RAISE EXCEPTION 'T5 FAILED: the recovery loop no longer selects DEFERRED_UNCOMMISSIONED rows';
    END IF;

    v_pos_branch    := position('d.lifecycle_status = ''ACTIVE''' IN v_def);
    v_pos_expensive := position('WITH current_elements AS MATERIALIZED' IN v_def);
    IF v_pos_branch = 0 OR v_pos_expensive = 0 OR v_pos_branch >= v_pos_expensive THEN
        RAISE EXCEPTION 'T5 FAILED: the onboarding eligibility branch (d.lifecycle_status = ''ACTIVE'') must appear before "WITH current_elements AS MATERIALIZED" (branch pos %, expensive pos %)', v_pos_branch, v_pos_expensive;
    END IF;

    IF v_def NOT ILIKE '%DEVICE_NOT_COMMISSIONED:%' OR v_def NOT ILIKE '%GREATEST(replay_attempt_count-1,0)%' THEN
        RAISE EXCEPTION 'T5 FAILED: the deferral branch is missing its DEVICE_NOT_COMMISSIONED reason or its attempt-count rollback';
    END IF;

    IF v_def NOT ILIKE '%f.raw_received_at<v_retention_cutoff%'
        OR v_def NOT ILIKE '%FROM telemetry.raw_messages r2m%WHERE r2m.received_at>=ce.bucket_start%AND r2m.received_at<=ce.deadline%' THEN
        RAISE EXCEPTION 'T5 FAILED: the migration-206 retention branch or the migration-204 supersession subquery is no longer present';
    END IF;
    RAISE NOTICE 'T5 passed: structure correct -- deferral branch is cheap and precedes the expensive path; 206/204 intact.';

    -- ==================================================================
    -- T6 -- schema: constraint admits the value; index predicate includes it.
    -- ==================================================================
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'raw_message_failures_resolution_status_ck'
          AND pg_get_constraintdef(oid) ILIKE '%DEFERRED_UNCOMMISSIONED%'
    ) THEN
        RAISE EXCEPTION 'T6 FAILED: raw_message_failures_resolution_status_ck does not admit DEFERRED_UNCOMMISSIONED';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'raw_message_failures_recovery_due_idx'
          AND indexdef ILIKE '%DEFERRED_UNCOMMISSIONED%'
    ) THEN
        RAISE EXCEPTION 'T6 FAILED: raw_message_failures_recovery_due_idx partial predicate does not include DEFERRED_UNCOMMISSIONED';
    END IF;
    RAISE NOTICE 'T6 passed: CHECK constraint and partial index both cover DEFERRED_UNCOMMISSIONED.';

END;
$test$;

-- ==================================================================
-- Cleanup -- the CALLs above really committed (migration 203).
-- ==================================================================
DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-ONBOARDING-DEV');

DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-ONBOARDING-DEV');

DELETE FROM telemetry.raw_message_failures
WHERE source_identifier IN ('TEST:RECOVERY:ONBOARDING:001','TEST:RECOVERY:ONBOARDING:NODEVICE');

DELETE FROM telemetry.raw_messages
WHERE source_topic = 'test/recovery/onboarding-aware';

DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-ONBOARDING-DEV');

DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-ONBOARDING-DEV');

DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_ONBOARDING_PROFILE');

DELETE FROM metadata.devices WHERE external_id = 'RECOVERY-ONBOARDING-DEV';
DELETE FROM metadata.gateways WHERE external_id = 'RECOVERY-ONBOARDING-GW';

DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'RECOVERY_ONBOARDING_TEST_SITE');

DELETE FROM metadata.sites WHERE code = 'RECOVERY_ONBOARDING_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'RECOVERY_ONBOARDING_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_ONBOARDING_PROFILE';

SELECT 'Recovery onboarding-aware deferral assertions passed.' AS result;
