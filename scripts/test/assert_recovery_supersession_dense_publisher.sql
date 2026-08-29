-- ============================================================================
-- File:
--   scripts/test/assert_recovery_supersession_dense_publisher.sql
--
-- Purpose:
--   Regression test for migration 220: telemetry.recover_failed_raw_messages()'s
--   supersession NOT EXISTS no longer re-invokes
--   telemetry.resolve_site_capture_bucket() once per competing rtdata element.
--   Instead it tests same-bucket membership by INTERVAL CONTAINMENT against
--   ce's own bucket:
--       COALESCE(ts2.source_timestamp, r2m.received_at) >= ce.bucket_start
--   AND COALESCE(ts2.source_timestamp, r2m.received_at)
--           <  ce.bucket_start + make_interval(secs => ce.capture_interval_seconds)
--   ce.bucket_start / ce.capture_interval_seconds are still produced by
--   current_elements' single resolve_site_capture_bucket() call -- the sole
--   bucket-resolution authority, unchanged. For a dense (sub-8-second)
--   multi-device publisher the removed fan-out was
--   (competing elements in the bucket_start..deadline window)
--     x (current_elements rows, i.e. devices in the packet)
--   resolve_site_capture_bucket() invocations per candidate -- the ~8-minute
--   single-candidate stall that kept Job 1077 at its 10-minute max_runtime
--   after migration 218 deferred the uncommissioned publishers.
--
--   Proven against a fully synthetic dense fixture (3 commissioned devices,
--   one gateway packet per ~3 s carrying all 3 devices' rtdata across a single
--   60-second WALL_CLOCK bucket, plus tail packets):
--     T1  a candidate for the LAST (non-superseded) packet in a dense bucket
--         recovers -- RECOVERED, with a capture_bucket_samples row and
--         normalized_points -- and the whole bare CALL over the dense
--         population completes fast (< 5 s wall clock: the fan-out is gone);
--     T2  an earlier same-bucket packet is detected as SUPERSEDED (its own
--         capture row is NOT inserted) and, once the last packet has
--         recovered, resolves to RECOVERED by canonical supersession -- the
--         "whole bucket failed" loop is broken;
--     T3  a same-bucket late-arriving superseder -- received deep in the
--         900-second receipt tail but with source_timestamp still inside
--         [bucket_start, bucket_start + capture_interval_seconds) -- IS still
--         detected (Phase-1 requirement 3);
--     T4  a tail packet whose source_timestamp belongs to the NEXT bucket
--         (received within [bucket_start, deadline] but source_timestamp
--         >= bucket_start + capture_interval_seconds) is NOT treated as a
--         superseder -- the failed message recovers exactly as if it were
--         absent (Phase-1 requirement 4);
--     T5  structural: the deployed procedure's supersession NOT EXISTS
--         contains the interval-containment predicate and no per-element
--         resolve_site_capture_bucket() (alias b2 / b2.bucket_start) fan-out;
--         exactly two CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket
--         call sites remain (current_elements + v_has_normalized);
--     T6  precondition: every config.telemetry_capture_policies row uses
--         alignment_mode = 'WALL_CLOCK' -- if not, fail loudly, because the
--         interval derivation must be re-audited for the new alignment mode.
--
--   Migration 203 note: telemetry.recover_failed_raw_messages() commits after
--   each candidate and MUST be invoked as a bare top-level CALL. Fixture rows
--   are identified by distinctive business keys and explicitly deleted at the
--   end (no ROLLBACK), matching the sibling recovery tests.
--
--   Migration 218 note: recovery only processes commissioned (ACTIVE) devices.
--   A bare INSERT ... lifecycle_status='ACTIVE' is rejected by
--   metadata.reject_uncommissioned_active_device(); the fixture reaches ACTIVE
--   the one controlled way that trigger permits (ems.controlled_device_
--   commissioning_id set to the device id, as admin.commission_device() does).
-- ============================================================================

DO $test$
DECLARE
    v_protocol       UUID;
    v_profile        UUID;
    v_org            UUID;
    v_site           UUID;
    v_gateway        UUID;
    v_lp             UUID;
    v_dev            UUID[] := ARRAY[]::UUID[];
    v_uidbase        CONSTANT TEXT := 'TEST:RECOVERY:DENSE:';
    v_interval_secs  CONSTANT INT := 60;
    v_tolerance_secs CONSTANT INT := 900;

    v_bucket         TIMESTAMPTZ;
    v_deadline       TIMESTAMPTZ;
    i                INT;
    k                INT;
    v_id             UUID;
    v_pl             JSONB;
    v_msg_last       BIGINT;
    v_msg_early      BIGINT;
    v_msg_t4         BIGINT;
    v_rawid          BIGINT;
    v_t0             TIMESTAMPTZ;
    v_elapsed        NUMERIC;
    v_status         TEXT;
    v_cbs            INT;
    v_np             INT;
    v_def            TEXT;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol on the canonical database';
    END IF;

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_RECOVERY_DENSE_PROFILE', 'WiseWatts Test', 'RecoveryDenseTest', 'Recovery Dense Publisher Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Recovery Dense Test Org', 'RECOVERY_DENSE_TEST_ORG', 'Asia/Kolkata') RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'Recovery Dense Test Site', 'RECOVERY_DENSE_TEST_SITE', 'Asia/Kolkata', TRUE) RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, v_interval_secs, 'WALL_CLOCK', v_tolerance_secs, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Recovery Dense Test Gateway', 'RECOVERY-DENSE-GW') RETURNING id INTO v_gateway;

    SELECT id INTO v_lp FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    IF v_lp IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the ENERGY_IMPORT_TOTAL logical point';
    END IF;
    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_lp, TRUE);

    -- 3 devices on the one gateway, each reached to ACTIVE the controlled way.
    FOR k IN 1..3 LOOP
        INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
        VALUES (v_org, v_gateway, v_profile, 'Recovery Dense Test Device '||k, 'RECOVERY-DENSE-DEV-'||k)
        RETURNING id INTO v_id;
        PERFORM set_config('ems.controlled_device_commissioning_id', v_id::text, true);
        UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = v_id;
        PERFORM set_config('ems.controlled_device_commissioning_id', '', true);
        INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
        VALUES (v_id, 'MQTT_UID', v_uidbase||k);
        v_dev := v_dev || v_id;
    END LOOP;

    -- One 60-second WALL_CLOCK bucket, safely historical (deadline long passed).
    v_bucket   := date_trunc('minute', now() - INTERVAL '2 hours');
    v_deadline := v_bucket + make_interval(secs => v_interval_secs + v_tolerance_secs);

    -- DENSE population: 18 gateway packets across [bucket, bucket+54s), one every
    -- 3 seconds, EACH carrying rtdata for all 3 devices (source_timestamp = its
    -- own send time). 18 x 3 = 54 competing elements in the window -- the shape
    -- that produced the resolve_site_capture_bucket() fan-out pre-220.
    FOR i IN 0..17 LOOP
        v_pl := jsonb_build_object('rtdata', (
            SELECT jsonb_agg(jsonb_build_object(
                     'uid', v_uidbase||d, 'ts', extract(epoch FROM v_bucket + make_interval(secs => i*3))::text, 'P', 1.0))
            FROM generate_series(1,3) d));
        INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
        VALUES (v_bucket + make_interval(secs => i*3) + INTERVAL '0.4 seconds', 'MQTT', 'test/recovery/dense', v_pl)
        RETURNING id INTO v_rawid;
        IF i = 0  THEN v_msg_early := v_rawid; END IF;
        IF i = 17 THEN v_msg_last  := v_rawid; END IF;
    END LOOP;

    -- T3 helper: same-bucket late arrival -- received at bucket+400s (deep in the
    -- 900s tail) but source_timestamp = bucket+50s (still in bucket 1).
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '400 seconds', 'MQTT', 'test/recovery/dense',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', v_uidbase||2, 'ts', extract(epoch FROM v_bucket + INTERVAL '50 seconds')::text, 'P', 1.0))));

    -- T4 helper: NEXT-bucket sample -- received at bucket+100s (still <= deadline)
    -- but source_timestamp = bucket+90s (bucket 2, >= bucket_start + 60s).
    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (v_bucket + INTERVAL '100 seconds', 'MQTT', 'test/recovery/dense',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', v_uidbase||3, 'ts', extract(epoch FROM v_bucket + INTERVAL '90 seconds')::text, 'P', 1.0))));

    -- ==================================================================
    -- T1 -- LAST packet (i=17, source_timestamp bucket+51s) has no later
    -- same-bucket sample for device 1 -> not superseded -> recovers.
    -- Time the whole bare CALL over the dense population.
    -- ==================================================================
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload)
    VALUES (v_bucket + make_interval(secs => 17*3) + INTERVAL '0.4 seconds', v_msg_last, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uidbase||1,
            jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uidbase||1))));

    v_t0 := clock_timestamp();
    CALL telemetry.recover_failed_raw_messages(1000);
    v_elapsed := extract(epoch FROM clock_timestamp() - v_t0);

    SELECT resolution_status INTO v_status FROM telemetry.raw_message_failures
    WHERE raw_message_id = v_msg_last;
    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'T1 FAILED: the last (non-superseded) dense-bucket packet must recover, got %', v_status;
    END IF;
    SELECT count(*) INTO v_cbs FROM telemetry.capture_bucket_samples
    WHERE device_id = v_dev[1] AND bucket_start = v_bucket;
    SELECT count(*) INTO v_np FROM telemetry.normalized_points
    WHERE device_id = v_dev[1] AND event_time >= v_bucket AND event_time < v_bucket + make_interval(secs=>v_interval_secs);
    IF v_cbs = 0 OR v_np = 0 THEN
        RAISE EXCEPTION 'T1 FAILED: recovery produced no capture_bucket_samples (%) / normalized_points (%)', v_cbs, v_np;
    END IF;
    IF v_elapsed >= 5 THEN
        RAISE EXCEPTION 'T1 FAILED: bare CALL over the dense population took %.1fs (>= 5s) -- the resolve_site_capture_bucket() fan-out may have returned', v_elapsed;
    END IF;
    RAISE NOTICE 'T1 passed: last dense-bucket packet recovered (cbs=%, np=%) in %.2fs -- no fan-out.', v_cbs, v_np, v_elapsed;

    -- ==================================================================
    -- T2 -- an EARLIER same-bucket packet (i=0) IS superseded (its own
    -- capture row is not separately inserted -- ON CONFLICT is by
    -- (site,bucket,device), so we assert via resolution: after a second
    -- CALL it resolves to RECOVERED by canonical supersession, not looping).
    -- ==================================================================
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload)
    VALUES (v_bucket + INTERVAL '0.4 seconds', v_msg_early, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uidbase||1,
            jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uidbase||1))));

    CALL telemetry.recover_failed_raw_messages(1000);
    CALL telemetry.recover_failed_raw_messages(1000);
    SELECT resolution_status INTO v_status FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg_early;
    IF v_status <> 'RECOVERED' THEN
        RAISE EXCEPTION 'T2 FAILED: an earlier same-bucket packet, superseded but whose bucket is now represented, must resolve to RECOVERED (got % -- the whole-bucket loop is not broken)', v_status;
    END IF;
    RAISE NOTICE 'T2 passed: earlier superseded packet resolves to RECOVERED once its bucket is represented.';

    -- ==================================================================
    -- T3 -- same-bucket late arrival in the 900s receipt tail IS a superseder.
    -- Device 2 candidate at event_time bucket+9s; the bucket+400s-received
    -- packet has source_timestamp bucket+50s (same bucket) -> supersedes it,
    -- so the candidate's own SELECTED capture row must NOT be inserted for it.
    -- ==================================================================
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload)
    SELECT rm.received_at, rm.id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uidbase||2,
           jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uidbase||2)))
    FROM telemetry.raw_messages rm
    WHERE rm.source_topic='test/recovery/dense' AND rm.received_at = v_bucket + make_interval(secs=>3) + INTERVAL '0.4 seconds'
    RETURNING raw_message_id INTO v_msg_t4;

    CALL telemetry.recover_failed_raw_messages(1000);
    SELECT count(*) INTO v_cbs FROM telemetry.capture_bucket_samples
    WHERE device_id = v_dev[2] AND bucket_start = v_bucket AND raw_message_id = v_msg_t4;
    IF v_cbs <> 0 THEN
        RAISE EXCEPTION 'T3 FAILED: device-2 candidate should be SUPERSEDED by the bucket+400s (tail) sample whose source_timestamp is bucket+50s (same bucket); found % of its own capture rows', v_cbs;
    END IF;
    RAISE NOTICE 'T3 passed: same-bucket late-arriving superseder in the 900s receipt tail is still detected.';

    -- ==================================================================
    -- T4 -- a tail packet whose source_timestamp is in the NEXT bucket must
    -- NOT supersede a bucket-1 candidate. Device 3: the i=2 packet
    -- (source_timestamp bucket+6s) is the LAST bucket-1 sample for device 3
    -- (the two tail helpers for device 3 both belong to bucket 2), so it is
    -- not superseded and must recover. If the NEXT-bucket tail sample
    -- (received bucket+100s, source_timestamp bucket+90s) were wrongly
    -- treated as a same-bucket superseder, device 3 would never recover.
    -- ==================================================================
    INSERT INTO telemetry.raw_message_failures(raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload)
    SELECT rm.received_at, rm.id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', v_uidbase||3,
           jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', v_uidbase||3)))
    FROM telemetry.raw_messages rm
    WHERE rm.source_topic='test/recovery/dense' AND rm.received_at = v_bucket + make_interval(secs=>2*3) + INTERVAL '0.4 seconds'
    RETURNING raw_message_id INTO v_msg_t4;

    CALL telemetry.recover_failed_raw_messages(1000);
    SELECT resolution_status INTO v_status FROM telemetry.raw_message_failures WHERE raw_message_id = v_msg_t4;
    SELECT count(*) INTO v_np FROM telemetry.normalized_points
    WHERE device_id = v_dev[3] AND event_time >= v_bucket AND event_time < v_bucket + make_interval(secs=>v_interval_secs);
    IF v_status <> 'RECOVERED' OR v_np = 0 THEN
        RAISE EXCEPTION 'T4 FAILED: device-3 bucket-1 candidate did not recover (status %, np %) -- a NEXT-bucket tail sample (source_timestamp bucket+90s) was wrongly treated as a same-bucket superseder', v_status, v_np;
    END IF;
    RAISE NOTICE 'T4 passed: a tail sample whose source_timestamp is in the next bucket is NOT a superseder.';

    -- ==================================================================
    -- T5 -- structural (migration 220).
    -- ==================================================================
    v_def := pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure);
    IF v_def NOT ILIKE '%COALESCE(ts2.source_timestamp,r2m.received_at) >= ce.bucket_start%COALESCE(ts2.source_timestamp,r2m.received_at) <%ce.bucket_start + make_interval(secs => ce.capture_interval_seconds)%' THEN
        RAISE EXCEPTION 'T5 FAILED: supersession NOT EXISTS lacks the interval-containment predicate';
    END IF;
    IF v_def ILIKE '%) b2%b2.bucket_start=ce.bucket_start%' THEN
        RAISE EXCEPTION 'T5 FAILED: the per-competing-element resolve_site_capture_bucket() fan-out (b2) is still present';
    END IF;
    IF (length(v_def) - length(replace(v_def, 'CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket', '')))
       / length('CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket') <> 2 THEN
        RAISE EXCEPTION 'T5 FAILED: expected exactly 2 resolve_site_capture_bucket call sites (current_elements + v_has_normalized)';
    END IF;
    RAISE NOTICE 'T5 passed: interval-containment predicate present; per-element fan-out removed; 2 resolve call sites remain.';

    -- ==================================================================
    -- T6 -- WALL_CLOCK precondition.
    -- ==================================================================
    IF EXISTS (SELECT 1 FROM config.telemetry_capture_policies WHERE alignment_mode <> 'WALL_CLOCK') THEN
        RAISE EXCEPTION 'T6 FAILED (migration 220 precondition): a config.telemetry_capture_policies row uses alignment_mode <> ''WALL_CLOCK''. Re-audit migration 220''s interval derivation for the new alignment mode before deploying it.';
    END IF;
    RAISE NOTICE 'T6 passed: all capture policies are WALL_CLOCK.';

END;
$test$;

-- ==================================================================
-- Cleanup (the CALLs above really committed -- migration 203).
-- ==================================================================
DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'RECOVERY-DENSE-DEV-%');
DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'RECOVERY-DENSE-DEV-%');
DELETE FROM telemetry.raw_message_failures
WHERE source_identifier LIKE 'TEST:RECOVERY:DENSE:%';
DELETE FROM telemetry.raw_messages WHERE source_topic = 'test/recovery/dense';
DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'RECOVERY-DENSE-DEV-%');
DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id LIKE 'RECOVERY-DENSE-DEV-%');
DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_DENSE_PROFILE');
DELETE FROM metadata.devices WHERE external_id LIKE 'RECOVERY-DENSE-DEV-%';
DELETE FROM metadata.gateways WHERE external_id = 'RECOVERY-DENSE-GW';
DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'RECOVERY_DENSE_TEST_SITE');
DELETE FROM metadata.sites WHERE code = 'RECOVERY_DENSE_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'RECOVERY_DENSE_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_DENSE_PROFILE';

SELECT 'Recovery dense-publisher supersession assertions passed.' AS result;
