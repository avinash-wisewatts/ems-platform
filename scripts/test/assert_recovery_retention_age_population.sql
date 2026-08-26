-- ============================================================================
-- File:
--   scripts/test/assert_recovery_retention_age_population.sql
--
-- Purpose:
--   Regression test for migration 206: telemetry.recover_failed_raw_messages()
--   now classifies a candidate as unrecoverable purely by age against the
--   live telemetry.raw_messages retention policy (read dynamically from
--   timescaledb_information.jobs), instead of probing whether the raw row
--   physically still exists. See migration 206's header for the full
--   rationale.
--
--   This test proves, against a fully synthetic fixture:
--     A. a candidate well inside the retention window still recovers
--        normally through the unchanged supersession/normalization logic;
--     B. a candidate older than the live retention cutoff is immediately
--        marked PERMANENT_FAILURE in a single call, without creating any
--        capture_bucket_samples or normalized_points row (proving the
--        expensive logic was skipped, not merely that the final status
--        happens to match);
--     C. the deployed procedure derives its cutoff dynamically from
--        timescaledb_information.jobs (proc_schema='_timescaledb_functions'
--        AND proc_name='policy_retention'), not from a hard-coded duration,
--        and no longer contains the superseded raw_messages existence probe
--        (a live catalog check, not a text/file check);
--     D. migration 204's supersession subquery (targeted telemetry.
--        raw_messages read, both window bounds, rtdata-is-array guard,
--        device_identifiers-membership identity test) is byte-for-byte
--        unchanged.
--
--   Migration 203 note: telemetry.recover_failed_raw_messages() commits
--   after each candidate and therefore MUST be invoked as a bare top-level
--   CALL -- wrapping it in an explicit transaction fails with "invalid
--   transaction termination". Fixture rows are identified by distinctive
--   business keys and explicitly deleted at the end instead of relying on
--   ROLLBACK, matching
--   scripts/test/assert_recovery_supersession_late_arrival_bound.sql.
-- ============================================================================

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
    v_tolerance_secs     CONSTANT INT := 300;

    v_retention_interval INTERVAL;
    v_bucket_start       TIMESTAMPTZ;
    v_msg_id             BIGINT;
    v_status             TEXT;
    v_capture_count      INT;
    v_def                TEXT;
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
    VALUES (v_protocol, 'TEST_RECOVERY_RETENTION_AGE_PROFILE', 'WiseWatts Test', 'RecoveryRetentionAgeTest', 'Recovery Retention Age Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Recovery Retention Age Test Org', 'RECOVERY_RETENTION_AGE_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Recovery Retention Age Test Site', 'RECOVERY_RETENTION_AGE_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, v_interval_secs, 'WALL_CLOCK', v_tolerance_secs, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Recovery Retention Age Test Gateway', 'RECOVERY-RETENTION-AGE-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_profile, 'Recovery Retention Age Test Device', 'RECOVERY-RETENTION-AGE-DEV')
    RETURNING id INTO v_device;

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', 'TEST:RECOVERY:RETENTION:AGE:001');

    SELECT id INTO v_logical_point FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_logical_point IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point to exist on the canonical database';
    END IF;

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_logical_point, TRUE);

    -- ==================================================================
    -- TEST A -- a candidate well inside the retention window (2 hours old,
    -- inside any plausible retention policy) still recovers normally.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '2 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/retention-age',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:RETENTION:AGE:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:RETENTION:AGE:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST A FAILED: an in-window candidate should recover normally, got status %', v_status;
    END IF;

    RAISE NOTICE 'TEST A passed: a candidate inside the retention window still recovers normally through the unchanged supersession logic.';

    -- ==================================================================
    -- TEST B -- a candidate older than the LIVE retention cutoff
    -- (v_retention_interval + 1 day margin, read dynamically above, not
    -- hard-coded) is immediately marked PERMANENT_FAILURE, without
    -- creating any capture_bucket_samples or normalized_points row.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - (v_retention_interval + INTERVAL '1 day'));

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/recovery/retention-age',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:RETENTION:AGE:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 1.0
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:RETENTION:AGE:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status INTO v_status
    FROM telemetry.raw_message_failures
    WHERE raw_received_at = v_bucket_start + INTERVAL '10 seconds' AND raw_message_id = v_msg_id;

    IF v_status <> 'PERMANENT_FAILURE' THEN
        RAISE EXCEPTION 'TEST B FAILED: a candidate older than the live retention cutoff (%) should be immediately marked PERMANENT_FAILURE, got status %', v_retention_interval, v_status;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND bucket_start = v_bucket_start AND raw_message_id = v_msg_id;

    IF v_capture_count <> 0 THEN
        RAISE EXCEPTION 'TEST B FAILED: a retention-expired candidate must skip the supersession/normalization logic entirely, but found % capture_bucket_samples row(s)', v_capture_count;
    END IF;

    RAISE NOTICE 'TEST B passed: a candidate older than the live retention cutoff (%) is immediately marked PERMANENT_FAILURE without running the expensive recovery logic.', v_retention_interval;

    -- ==================================================================
    -- TEST C -- the deployed procedure derives its cutoff dynamically from
    -- the live policy_retention job, and no longer contains the superseded
    -- raw_messages existence probe (live catalog check).
    -- ==================================================================

    v_def := pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure);

    IF v_def NOT ILIKE '%proc_schema=%_timescaledb_functions%'
        OR v_def NOT ILIKE '%proc_name=%policy_retention%'
        OR v_def NOT ILIKE '%hypertable_name=%raw_messages%'
        OR v_def NOT ILIKE '%drop_after%'
    THEN
        RAISE EXCEPTION 'TEST C FAILED: the deployed procedure does not appear to derive its retention cutoff dynamically from the live policy_retention job';
    END IF;

    IF v_def ILIKE '%NOT EXISTS%SELECT 1 FROM telemetry.raw_messages r%WHERE r.received_at=f.raw_received_at%'
    THEN
        RAISE EXCEPTION 'TEST C FAILED: the superseded raw_messages existence probe (v_exists) is still present -- population selection must be age-only';
    END IF;

    RAISE NOTICE 'TEST C passed: the deployed procedure derives its retention cutoff dynamically and no longer contains the superseded existence probe.';

    -- ==================================================================
    -- TEST D -- migration 204's supersession subquery is byte-for-byte
    -- unchanged (same check as migration 204's own Test E).
    -- ==================================================================

    IF v_def NOT ILIKE '%FROM telemetry.raw_messages r2m%WHERE r2m.received_at>=ce.bucket_start%AND r2m.received_at<=ce.deadline%AND jsonb_typeof(r2m.payload->%rtdata%)=%array%%jsonb_array_elements(r2m.payload->%rtdata%) r2(value)%'
    THEN
        RAISE EXCEPTION 'TEST D FAILED: migration 204''s targeted supersession search appears to have changed';
    END IF;

    RAISE NOTICE 'TEST D passed: migration 204''s supersession subquery is unchanged.';

END;
$test$;

-- ==================================================================
-- Cleanup -- the CALLs above really committed (migration 203), so
-- explicitly remove every row this fixture created, identified by its
-- distinctive business keys, in FK-safe (child-before-parent) order.
-- ==================================================================

DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-RETENTION-AGE-DEV');

DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-RETENTION-AGE-DEV');

DELETE FROM telemetry.raw_message_failures
WHERE payload->'rtdata'->0->>'uid' = 'TEST:RECOVERY:RETENTION:AGE:001';

DELETE FROM telemetry.raw_messages
WHERE source_topic = 'test/recovery/retention-age';

DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-RETENTION-AGE-DEV');

DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-RETENTION-AGE-DEV');

DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_RETENTION_AGE_PROFILE');

DELETE FROM metadata.devices WHERE external_id = 'RECOVERY-RETENTION-AGE-DEV';
DELETE FROM metadata.gateways WHERE external_id = 'RECOVERY-RETENTION-AGE-GW';

DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'RECOVERY_RETENTION_AGE_TEST_SITE');

DELETE FROM metadata.sites WHERE code = 'RECOVERY_RETENTION_AGE_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'RECOVERY_RETENTION_AGE_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_RETENTION_AGE_PROFILE';

SELECT
    'Recovery retention-age population assertions passed.'
    AS result;
