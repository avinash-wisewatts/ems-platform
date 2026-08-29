-- ============================================================================
-- File:
--   scripts/test/assert_recovery_per_candidate_commit.sql
--
-- Purpose:
--   Regression test for migration 203: telemetry.recover_failed_raw_
--   messages() now commits after each candidate's complete recovery unit of
--   work, instead of once after the whole LIMIT p_limit batch, so that a
--   run killed by the job's max_runtime leaves durable partial progress.
--
--   This test proves, against fully synthetic fixtures:
--     A. multiple candidates are durably committed independently (proved
--        via each candidate's final row version carrying a DISTINCT xmin --
--        i.e. a distinct committed transaction id -- which is only
--        possible if each candidate was its own transaction; under the
--        pre-203 shape all candidates in one CALL would share one xmin);
--     D. p_limit behavior is unchanged: the bounds check (1..1000) still
--        raises, and LIMIT p_limit still caps how many candidates one CALL
--        touches -- an untouched, still-OPEN candidate beyond the limit is
--        proof the loop did not silently drain the whole backlog;
--     G. the procedure still calls migration 202's targeted normalization
--        function, not telemetry.v_normalized_points, at its one call site;
--     H. the procedure retains oldest-first ORDER BY raw_received_at and
--        FOR UPDATE SKIP LOCKED;
--     structural: the deployed procedure body contains the per-candidate
--        COMMIT, and COMMENT ON PROCEDURE documents the new contract.
--
--   Tests B and C (a mid-candidate cancellation rolls back only the
--   in-flight candidate, leaving prior candidates committed and the
--   cancelled one free of partial state) require real backend cancellation
--   (pg_cancel_backend) against a process that is actually mid-statement --
--   not expressible as a single declarative SQL script. Those are proved in
--   scripts/test/assert_recovery_per_candidate_commit.sh, against a
--   throwaway scratch table (not telemetry.*) running the exact same loop
--   shape (FOR ... FOR UPDATE SKIP LOCKED LOOP ... COMMIT; END LOOP;) this
--   migration relies on -- the mechanism being tested, not the business
--   logic inside it, which tests A/G/H here confirm the real procedure
--   still applies that exact mechanism to.
--
--   Because telemetry.recover_failed_raw_messages() now commits internally,
--   it must be invoked as a bare top-level CALL (see migration 203's
--   COMMENT ON PROCEDURE) -- this script contains no enclosing BEGIN/COMMIT,
--   and each DO block below is its own independent top-level statement/
--   transaction so that the nested BEGIN...EXCEPTION...END used in the
--   p_limit-bounds check (which is incompatible with a later COMMIT in the
--   SAME transaction -- see migration 203's header) cannot affect any other
--   block's CALL. Fixture rows are identified by distinctive business keys
--   and explicitly deleted at the end -- no ROLLBACK is used or possible
--   here.
-- ============================================================================

-- ==================================================================
-- Fixture setup -- own top-level transaction, no CALL, no exception.
-- ==================================================================

DO $setup$
DECLARE
    v_protocol UUID;
    v_profile  UUID;
    v_org      UUID;
    v_site     UUID;
    v_gateway  UUID;
    v_device   UUID;
    v_point    UUID;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol to exist on the canonical database';
    END IF;

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_RECOVERY_COMMIT_PROFILE', 'WiseWatts Test', 'RecoveryCommitTest', 'Recovery Per-Candidate Commit Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Recovery Commit Test Org', 'RECOVERY_COMMIT_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Recovery Commit Test Site', 'RECOVERY_COMMIT_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, 60, 'WALL_CLOCK', 300, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Recovery Commit Test Gateway', 'RECOVERY-COMMIT-GW')
    RETURNING id INTO v_gateway;

    -- Migration 218: recovery now requires a commissioned (ACTIVE) device.
    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id, lifecycle_status)
    VALUES (v_org, v_gateway, v_profile, 'Recovery Commit Test Device', 'RECOVERY-COMMIT-DEV', 'ACTIVE')
    RETURNING id INTO v_device;

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', 'TEST:RECOVERY:COMMIT:001');

    SELECT id INTO v_point FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_point IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point to exist on the canonical database';
    END IF;

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_point, TRUE);
END;
$setup$;

-- ==================================================================
-- TEST A -- multiple candidates durably committed independently.
-- Three candidates, oldest-first, none superseded. One CALL(10) should
-- resolve all three, each as its OWN committed transaction.
-- ==================================================================

DO $test_a$
DECLARE
    v_device       UUID;
    v_bucket       TIMESTAMPTZ;
    v_msg1         BIGINT;
    v_msg2         BIGINT;
    v_msg3         BIGINT;
    v_status1      TEXT;
    v_status2      TEXT;
    v_status3      TEXT;
    v_xmin1        BIGINT;
    v_xmin2        BIGINT;
    v_xmin3        BIGINT;
BEGIN
    SELECT id INTO v_device FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV';

    v_bucket := date_trunc('minute', now() - INTERVAL '6 hours');
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', 'MQTT', 'test/recovery/commit',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:COMMIT:001', 'ts', extract(epoch FROM v_bucket + INTERVAL '10 seconds')::text, 'P', 1.0))))
    RETURNING id INTO v_msg1;
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', v_msg1, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:COMMIT:001'))));

    v_bucket := date_trunc('minute', now() - INTERVAL '5 hours');
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', 'MQTT', 'test/recovery/commit',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:COMMIT:001', 'ts', extract(epoch FROM v_bucket + INTERVAL '10 seconds')::text, 'P', 2.0))))
    RETURNING id INTO v_msg2;
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', v_msg2, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:COMMIT:001'))));

    v_bucket := date_trunc('minute', now() - INTERVAL '4 hours');
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', 'MQTT', 'test/recovery/commit',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:COMMIT:001', 'ts', extract(epoch FROM v_bucket + INTERVAL '10 seconds')::text, 'P', 3.0))))
    RETURNING id INTO v_msg3;
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', v_msg3, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:COMMIT:001'))));

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT resolution_status, xmin::text::bigint INTO v_status1, v_xmin1 FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg1;
    SELECT resolution_status, xmin::text::bigint INTO v_status2, v_xmin2 FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg2;
    SELECT resolution_status, xmin::text::bigint INTO v_status3, v_xmin3 FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg3;

    IF v_status1 <> 'RECOVERED' OR v_status2 <> 'RECOVERED' OR v_status3 <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST A FAILED: expected all three candidates RECOVERED, got %/%/%', v_status1, v_status2, v_status3;
    END IF;

    IF v_xmin1 = v_xmin2 OR v_xmin2 = v_xmin3 OR v_xmin1 = v_xmin3 THEN
        RAISE EXCEPTION 'TEST A FAILED: expected three DISTINCT committing transaction ids (xmin), got %/%/% -- candidates were committed together, not independently',
            v_xmin1, v_xmin2, v_xmin3;
    END IF;

    RAISE NOTICE 'TEST A passed: three candidates recovered under three distinct committed transactions (xmin %, %, %).', v_xmin1, v_xmin2, v_xmin3;
END;
$test_a$;

-- ==================================================================
-- TEST D -- p_limit behavior unchanged: LIMIT p_limit still caps how
-- many candidates one CALL touches. Two fresh candidates, oldest-first;
-- CALL(1) must resolve only the older one and leave the newer completely
-- untouched.
-- ==================================================================

DO $test_d_limit$
DECLARE
    v_device   UUID;
    v_bucket   TIMESTAMPTZ;
    v_msg_old  BIGINT;
    v_msg_new  BIGINT;
    v_status_old TEXT;
    v_status_new TEXT;
    v_attempts_new INT;
BEGIN
    SELECT id INTO v_device FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV';

    v_bucket := date_trunc('minute', now() - INTERVAL '3 hours');
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', 'MQTT', 'test/recovery/commit',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:COMMIT:001', 'ts', extract(epoch FROM v_bucket + INTERVAL '10 seconds')::text, 'P', 4.0))))
    RETURNING id INTO v_msg_old;
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', v_msg_old, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:COMMIT:001'))));

    v_bucket := date_trunc('minute', now() - INTERVAL '2 hours');
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', 'MQTT', 'test/recovery/commit',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:RECOVERY:COMMIT:001', 'ts', extract(epoch FROM v_bucket + INTERVAL '10 seconds')::text, 'P', 5.0))))
    RETURNING id INTO v_msg_new;
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, payload)
    VALUES (v_bucket + INTERVAL '10 seconds', v_msg_new, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:RECOVERY:COMMIT:001'))));

    CALL telemetry.recover_failed_raw_messages(1);

    SELECT resolution_status INTO v_status_old FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg_old;
    SELECT resolution_status, replay_attempt_count INTO v_status_new, v_attempts_new FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg_new;

    IF v_status_old <> 'RECOVERED' THEN
        RAISE EXCEPTION 'TEST D FAILED: expected the older candidate to be processed under p_limit=1, got status %', v_status_old;
    END IF;

    IF v_status_new <> 'OPEN' OR v_attempts_new <> 0 THEN
        RAISE EXCEPTION 'TEST D FAILED: expected the newer candidate to be completely untouched under p_limit=1 (status=OPEN, attempts=0), got status=%, attempts=%',
            v_status_new, v_attempts_new;
    END IF;

    RAISE NOTICE 'TEST D (limit) passed: p_limit=1 processed exactly the oldest candidate and left the newer one untouched.';
END;
$test_d_limit$;

-- ==================================================================
-- TEST D -- p_limit bounds check unchanged. Isolated in its own
-- transaction: catching these exceptions here must not affect any other
-- block's CALL (see migration 203's header on exception/commit
-- incompatibility).
-- ==================================================================

DO $test_d_bounds$
DECLARE
    v_caught BOOLEAN;
BEGIN
    v_caught := FALSE;
    BEGIN
        CALL telemetry.recover_failed_raw_messages(0);
    EXCEPTION WHEN OTHERS THEN
        v_caught := TRUE;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'TEST D (bounds) FAILED: p_limit=0 did not raise';
    END IF;

    v_caught := FALSE;
    BEGIN
        CALL telemetry.recover_failed_raw_messages(1001);
    EXCEPTION WHEN OTHERS THEN
        v_caught := TRUE;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'TEST D (bounds) FAILED: p_limit=1001 did not raise';
    END IF;

    v_caught := FALSE;
    BEGIN
        CALL telemetry.recover_failed_raw_messages(NULL);
    EXCEPTION WHEN OTHERS THEN
        v_caught := TRUE;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'TEST D (bounds) FAILED: p_limit=NULL did not raise';
    END IF;

    RAISE NOTICE 'TEST D (bounds) passed: p_limit outside [1,1000], and NULL, still raise.';
END;
$test_d_bounds$;

-- ==================================================================
-- TEST G, H, and structural assertions -- pure catalog checks, no CALL.
-- ==================================================================

DO $structural$
DECLARE
    v_def  TEXT;
    v_doc  TEXT;
BEGIN
    v_def := pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure);

    -- G: PR #11's targeted normalization function is still the one used.
    IF v_def NOT ILIKE '%normalized_points_for_recovery_candidate%' THEN
        RAISE EXCEPTION 'TEST G FAILED: telemetry.recover_failed_raw_messages() no longer calls telemetry.normalized_points_for_recovery_candidate()';
    END IF;
    IF v_def ILIKE '%FROM telemetry.v_normalized_points%' THEN
        RAISE EXCEPTION 'TEST G FAILED: telemetry.recover_failed_raw_messages() references telemetry.v_normalized_points directly again';
    END IF;
    RAISE NOTICE 'TEST G passed: the procedure still uses migration 202''s targeted normalization function.';

    -- H: oldest-first ordering and FOR UPDATE SKIP LOCKED retained.
    IF v_def NOT ILIKE '%ORDER BY raw_received_at%' THEN
        RAISE EXCEPTION 'TEST H FAILED: ORDER BY raw_received_at is missing -- oldest-first ordering may have been lost';
    END IF;
    IF v_def NOT ILIKE '%FOR UPDATE SKIP LOCKED%' THEN
        RAISE EXCEPTION 'TEST H FAILED: FOR UPDATE SKIP LOCKED is missing from the candidate-selection query';
    END IF;
    RAISE NOTICE 'TEST H passed: oldest-first ORDER BY raw_received_at and FOR UPDATE SKIP LOCKED are both retained.';

    -- Structural: the per-candidate COMMIT this migration adds is present.
    IF v_def NOT ILIKE '%COMMIT%' THEN
        RAISE EXCEPTION 'STRUCTURAL FAILED: no COMMIT found in telemetry.recover_failed_raw_messages() -- migration 203 may not be deployed';
    END IF;
    RAISE NOTICE 'STRUCTURAL passed: the deployed procedure body contains a COMMIT.';

    -- Structural: COMMENT ON PROCEDURE documents the new contract.
    v_doc := obj_description('telemetry.recover_failed_raw_messages(integer)'::regprocedure, 'pg_proc');
    IF v_doc IS NULL THEN
        RAISE EXCEPTION 'STRUCTURAL FAILED: telemetry.recover_failed_raw_messages() has no COMMENT ON PROCEDURE';
    END IF;
    IF v_doc NOT ILIKE '%bare top-level CALL%' THEN
        RAISE EXCEPTION 'STRUCTURAL FAILED: procedure COMMENT does not document the bare-top-level-CALL requirement';
    END IF;
    IF v_doc NOT ILIKE '%per candidate%' AND v_doc NOT ILIKE '%each candidate%' THEN
        RAISE EXCEPTION 'STRUCTURAL FAILED: procedure COMMENT does not document per-candidate commit behavior';
    END IF;
    IF v_doc NOT ILIKE '%EXCEPTION%' THEN
        RAISE EXCEPTION 'STRUCTURAL FAILED: procedure COMMENT does not document why per-candidate exception isolation was not introduced';
    END IF;
    RAISE NOTICE 'STRUCTURAL passed: COMMENT ON PROCEDURE documents the per-candidate commit contract.';
END;
$structural$;

-- ==================================================================
-- Cleanup -- the CALLs above really committed (that is the point of this
-- migration), so explicitly remove every row this fixture created, in
-- FK-safe (child-before-parent) order.
-- ==================================================================

DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV');

DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV');

DELETE FROM telemetry.raw_message_failures
WHERE payload->'rtdata'->0->>'uid' = 'TEST:RECOVERY:COMMIT:001';

DELETE FROM telemetry.raw_messages
WHERE source_topic = 'test/recovery/commit';

DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV');

DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV');

DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_COMMIT_PROFILE');

DELETE FROM metadata.devices WHERE external_id = 'RECOVERY-COMMIT-DEV';
DELETE FROM metadata.gateways WHERE external_id = 'RECOVERY-COMMIT-GW';

DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'RECOVERY_COMMIT_TEST_SITE');

DELETE FROM metadata.sites WHERE code = 'RECOVERY_COMMIT_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'RECOVERY_COMMIT_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_COMMIT_PROFILE';

SELECT
    'Recovery per-candidate commit assertions (A, D, G, H, structural) passed.'
    AS result;
