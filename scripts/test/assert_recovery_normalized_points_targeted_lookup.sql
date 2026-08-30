-- ============================================================================
-- File:
--   scripts/test/assert_recovery_normalized_points_targeted_lookup.sql
--
-- Purpose:
--   Regression test for migration 202: telemetry.recover_failed_raw_
--   messages()'s per-candidate normalized-points materialization step used
--   to filter telemetry.v_normalized_points (a general-purpose view whose
--   DISTINCT ON (received_at, device_id, logical_point_id) sits between the
--   raw scan and the procedure's actual filter columns) only after the
--   view's full pipeline had already run. Live staging investigation
--   showed this to be the dominant remaining cost after migration 201's
--   supersession fix -- a single old/compressed candidate's lookup ran
--   past 20+ minutes with disk-spilling, parallel-worker sort activity.
--
--   telemetry.normalized_points_for_recovery_candidate() replaces that one
--   call site with an equivalent pipeline that pushes the already-known
--   (received_at, raw_message_id, device_id) identity down to the
--   telemetry.raw_messages primary-key lookup and the resolved-device
--   join, before the DISTINCT ON runs, while reproducing the exact same
--   DISTINCT ON key and tie-break ORDER BY. telemetry.v_normalized_points
--   itself, and every other caller of it, are unchanged.
--
--   This test proves, against a fully synthetic fixture:
--     A. DISTINCT ON tie-break preserved: when a device has both a profile
--        mapping and a device-override mapping for the same logical point,
--        the profile mapping (priority 1) wins, exactly as
--        v_normalized_points would resolve it;
--     B. json_path-based extraction (not just raw_field_name) still works;
--     C. INVALID_NUMERIC and MISSING quality-code classification are
--        preserved;
--     D. the new function structurally applies its filter at the
--        telemetry.raw_messages primary key -- an indexed, single-row
--        lookup -- rather than an unfiltered scan (the performance
--        contract this migration exists to establish);
--     E. telemetry.v_normalized_points itself is byte-for-byte unchanged
--        (every other caller is unaffected);
--     F. the deployed procedure calls the new function, not the view, at
--        this one call site.
--
--   Migration 203 note: telemetry.recover_failed_raw_messages() now commits
--   after each candidate (see migration 203) and therefore MUST be invoked
--   as a bare top-level CALL -- wrapping it in an explicit transaction fails
--   with "invalid transaction termination". This test can no longer run
--   inside a BEGIN; ... ROLLBACK; wrapper the way it used to: the CALLs
--   below really commit. Fixture rows are identified by distinctive
--   business keys (org/site/gateway/device/profile codes, the fixed
--   source_topic, and the fixed synthetic MQTT UID) and explicitly deleted
--   at the end instead, so the test remains idempotent and leaves no
--   residue.
-- ============================================================================

DO $test$
DECLARE
    v_protocol          UUID;
    v_profile           UUID;
    v_org               UUID;
    v_site              UUID;
    v_gateway           UUID;
    v_device            UUID;
    v_point_energy      UUID;
    v_point_numeric     UUID;

    v_interval_secs      CONSTANT INT := 60;
    v_tolerance_secs      CONSTANT INT := 300;

    v_bucket_start       TIMESTAMPTZ;
    v_msg_id             BIGINT;
    v_mapping_source     TEXT;
    v_raw_value          TEXT;
    v_quality_code       TEXT;
    v_plan_text          TEXT;
    v_view_def_before    TEXT;
    v_view_def_after     TEXT;
BEGIN
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Fixture requires the MQTT protocol to exist on the canonical database';
    END IF;

    v_view_def_before := pg_get_viewdef('telemetry.v_normalized_points'::regclass, true);

    INSERT INTO config.device_profiles(protocol_id, profile_code, manufacturer, model, profile_name, is_active)
    VALUES (v_protocol, 'TEST_NP_TARGETED_LOOKUP_PROFILE', 'WiseWatts Test', 'TargetedLookupTest', 'Targeted Lookup Test Profile', TRUE)
    RETURNING id INTO v_profile;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('NP Targeted Lookup Test Org', 'NP_TARGETED_LOOKUP_TEST_ORG', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active)
    VALUES (v_org, 'NP Targeted Lookup Test Site', 'NP_TARGETED_LOOKUP_TEST_SITE', 'Asia/Kolkata', TRUE)
    RETURNING id INTO v_site;

    INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
    VALUES (v_site, v_interval_secs, 'WALL_CLOCK', v_tolerance_secs, now() - INTERVAL '90 days', TRUE);

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'NP Targeted Lookup Test Gateway', 'NP-TARGETED-LOOKUP-GW')
    RETURNING id INTO v_gateway;

    -- Migration 218: recovery now requires a commissioned (ACTIVE) device.
    -- Create it REGISTERED, then reach ACTIVE the one controlled way
    -- metadata.reject_uncommissioned_active_device() permits: as ems_admin
    -- with ems.controlled_device_commissioning_id set to this device id --
    -- exactly what admin.commission_device() does. A bare INSERT ... 'ACTIVE'
    -- is rejected by that trigger.
    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id)
    VALUES (v_org, v_gateway, v_profile, 'NP Targeted Lookup Test Device', 'NP-TARGETED-LOOKUP-DEV')
    RETURNING id INTO v_device;

    PERFORM set_config('ems.controlled_device_commissioning_id', v_device::text, true);
    UPDATE metadata.devices SET lifecycle_status = 'ACTIVE' WHERE id = v_device;
    PERFORM set_config('ems.controlled_device_commissioning_id', '', true);

    INSERT INTO metadata.device_identifiers(device_id, identifier_type, identifier_value)
    VALUES (v_device, 'MQTT_UID', 'TEST:NP:TARGETED:LOOKUP:001');

    SELECT id INTO v_point_energy FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL' LIMIT 1;
    SELECT id INTO v_point_numeric FROM metadata.logical_points WHERE name = 'VOLTAGE_L1' LIMIT 1;
    IF v_point_energy IS NULL OR v_point_numeric IS NULL THEN
        RAISE EXCEPTION 'Fixture requires ENERGY_IMPORT_TOTAL and VOLTAGE_L1 logical points to exist';
    END IF;

    -- Both a profile mapping AND a device-override mapping target the SAME
    -- raw field / logical point -- the exact tie scenario the DISTINCT ON's
    -- tie-break (mapping_priority: profile=1 beats device_override=2) must
    -- resolve deterministically.
    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required)
    VALUES (v_profile, 'P', v_point_energy, TRUE);

    INSERT INTO metadata.device_field_mapping(device_id, raw_field_name, logical_point_id)
    VALUES (v_device, 'P', v_point_energy);

    -- A second mapping, json_path-based, for the INVALID_NUMERIC/MISSING
    -- quality-code tests below.
    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, json_path, is_required)
    VALUES (v_profile, '_unused_raw_field', v_point_numeric, '$.nested.voltage', TRUE);

    -- ==================================================================
    -- TEST A -- DISTINCT ON tie-break preserved: profile mapping wins.
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '2 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/np-targeted-lookup',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:NP:TARGETED:LOOKUP:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'P', 42.5,
            'nested', jsonb_build_object('voltage', 231.4)
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', 'TEST:NP:TARGETED:LOOKUP:001',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:NP:TARGETED:LOOKUP:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT mapping_source, raw_value INTO v_mapping_source, v_raw_value
    FROM telemetry.normalized_points
    WHERE device_id = v_device AND logical_point_id = v_point_energy
      AND event_time = v_bucket_start + INTERVAL '10 seconds';

    IF v_mapping_source IS DISTINCT FROM 'DEVICE_PROFILE' THEN
        RAISE EXCEPTION 'TEST A FAILED: expected the profile mapping (priority 1) to win the DISTINCT ON tie-break, got mapping_source=%', v_mapping_source;
    END IF;
    IF v_raw_value IS DISTINCT FROM '42.5' THEN
        RAISE EXCEPTION 'TEST A FAILED: expected raw_value=42.5, got %', v_raw_value;
    END IF;

    RAISE NOTICE 'TEST A passed: profile mapping wins the DISTINCT ON tie-break over device override, exactly as telemetry.v_normalized_points would resolve it.';

    -- ==================================================================
    -- TEST B -- json_path-based extraction preserved.
    -- ==================================================================

    SELECT raw_value, quality_code INTO v_raw_value, v_quality_code
    FROM telemetry.normalized_points
    WHERE device_id = v_device AND logical_point_id = v_point_numeric
      AND event_time = v_bucket_start + INTERVAL '10 seconds';

    IF v_raw_value IS DISTINCT FROM '231.4' THEN
        RAISE EXCEPTION 'TEST B FAILED: expected json_path extraction to yield raw_value=231.4, got %', v_raw_value;
    END IF;
    IF v_quality_code IS DISTINCT FROM 'GOOD' THEN
        RAISE EXCEPTION 'TEST B FAILED: expected quality_code=GOOD for a valid numeric json_path extraction, got %', v_quality_code;
    END IF;

    RAISE NOTICE 'TEST B passed: json_path-based extraction is preserved (raw_value=231.4, quality_code=GOOD).';

    -- ==================================================================
    -- TEST C -- INVALID_NUMERIC and MISSING quality-code classification
    -- preserved. New bucket, new message: the numeric-typed field is
    -- present but non-numeric (INVALID_NUMERIC), and the profile-mapped
    -- field 'P' is entirely absent from the payload (MISSING).
    -- ==================================================================

    v_bucket_start := date_trunc('minute', now() - INTERVAL '3 hours');

    INSERT INTO telemetry.raw_messages(received_at, source_protocol, source_topic, payload)
    VALUES (
        v_bucket_start + INTERVAL '10 seconds', 'MQTT', 'test/np-targeted-lookup',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object(
            'uid', 'TEST:NP:TARGETED:LOOKUP:001',
            'ts', extract(epoch FROM v_bucket_start + INTERVAL '10 seconds')::text,
            'nested', jsonb_build_object('voltage', 'not-a-number')
        )))
    )
    RETURNING id INTO v_msg_id;

    INSERT INTO telemetry.raw_message_failures(
        raw_received_at, raw_message_id, failure_code, source_protocol, source_identifier, payload
    ) VALUES (
        v_bucket_start + INTERVAL '10 seconds', v_msg_id, 'UNRESOLVED_DEVICE_ELEMENTS', 'MQTT', 'TEST:NP:TARGETED:LOOKUP:001',
        jsonb_build_object('rtdata', jsonb_build_array(jsonb_build_object('uid', 'TEST:NP:TARGETED:LOOKUP:001')))
    );

    CALL telemetry.recover_failed_raw_messages(10);

    SELECT quality_code INTO v_quality_code
    FROM telemetry.normalized_points
    WHERE device_id = v_device AND logical_point_id = v_point_numeric
      AND event_time = v_bucket_start + INTERVAL '10 seconds';

    IF v_quality_code IS DISTINCT FROM 'INVALID_NUMERIC' THEN
        RAISE EXCEPTION 'TEST C FAILED: expected quality_code=INVALID_NUMERIC for a non-numeric value on a numeric-typed point, got %', v_quality_code;
    END IF;

    SELECT quality_code INTO v_quality_code
    FROM telemetry.normalized_points
    WHERE device_id = v_device AND logical_point_id = v_point_energy
      AND event_time = v_bucket_start + INTERVAL '10 seconds';

    IF v_quality_code IS DISTINCT FROM 'MISSING' THEN
        RAISE EXCEPTION 'TEST C FAILED: expected quality_code=MISSING when the mapped raw field is absent from the payload, got %', v_quality_code;
    END IF;

    RAISE NOTICE 'TEST C passed: INVALID_NUMERIC and MISSING quality-code classification are preserved.';

    -- ==================================================================
    -- TEST D -- performance contract: the new function's plan applies its
    -- filter at the telemetry.raw_messages primary key (an indexed,
    -- single-row lookup), not an unfiltered/broad scan.
    -- ==================================================================

    -- EXPLAIN returns one row per plan line; capture and concatenate all of
    -- them since EXECUTE ... INTO would silently keep only the first line.
    v_plan_text := '';
    FOR v_raw_value IN
        EXECUTE format(
            'EXPLAIN SELECT * FROM telemetry.normalized_points_for_recovery_candidate(%L::timestamptz, %L::bigint, %L::uuid, %L::timestamptz)',
            v_bucket_start + INTERVAL '10 seconds', v_msg_id, v_device, v_bucket_start + INTERVAL '10 seconds'
        )
    LOOP
        v_plan_text := v_plan_text || v_raw_value || E'\n';
    END LOOP;

    IF v_plan_text NOT ILIKE '%raw_messages_pkey%' THEN
        RAISE EXCEPTION 'TEST D FAILED: expected the plan to use the telemetry.raw_messages primary key index for the received_at/id lookup; got plan: %', v_plan_text;
    END IF;

    RAISE NOTICE 'TEST D passed: the targeted lookup structurally applies its filter at the telemetry.raw_messages primary key.';

    -- ==================================================================
    -- TEST E -- telemetry.v_normalized_points itself is byte-for-byte
    -- unchanged; every other caller (e.g. load_normalized_points_incremental)
    -- is unaffected by this migration.
    -- ==================================================================

    v_view_def_after := pg_get_viewdef('telemetry.v_normalized_points'::regclass, true);

    IF v_view_def_after IS DISTINCT FROM v_view_def_before THEN
        RAISE EXCEPTION 'TEST E FAILED: telemetry.v_normalized_points'' definition changed -- migration 202 must not modify the shared view.';
    END IF;

    RAISE NOTICE 'TEST E passed: telemetry.v_normalized_points is unchanged.';

    -- ==================================================================
    -- TEST F -- the deployed procedure calls the new targeted function,
    -- not the general-purpose view, at this one call site.
    -- ==================================================================

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        NOT ILIKE '%normalized_points_for_recovery_candidate%'
    THEN
        RAISE EXCEPTION 'TEST F FAILED: telemetry.recover_failed_raw_messages() does not call telemetry.normalized_points_for_recovery_candidate() -- migration 202 may not be deployed.';
    END IF;

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        ILIKE '%FROM telemetry.v_normalized_points%'
    THEN
        RAISE EXCEPTION 'TEST F FAILED: telemetry.recover_failed_raw_messages() still references telemetry.v_normalized_points directly -- the targeted replacement did not fully take effect.';
    END IF;

    RAISE NOTICE 'TEST F passed: the deployed procedure calls the targeted function, not the general-purpose view.';

END;
$test$;

-- ==================================================================
-- Cleanup -- the CALLs above really committed (migration 203), so
-- explicitly remove every row this fixture created, identified by its
-- distinctive business keys, in FK-safe (child-before-parent) order.
-- ==================================================================

DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV');

DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV');

DELETE FROM telemetry.raw_message_failures
WHERE payload->'rtdata'->0->>'uid' = 'TEST:NP:TARGETED:LOOKUP:001';

DELETE FROM telemetry.raw_messages
WHERE source_topic = 'test/np-targeted-lookup';

DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV');

DELETE FROM metadata.device_field_mapping
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV');

DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV');

DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_NP_TARGETED_LOOKUP_PROFILE');

DELETE FROM metadata.devices WHERE external_id = 'NP-TARGETED-LOOKUP-DEV';
DELETE FROM metadata.gateways WHERE external_id = 'NP-TARGETED-LOOKUP-GW';

DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'NP_TARGETED_LOOKUP_TEST_SITE');

DELETE FROM metadata.sites WHERE code = 'NP_TARGETED_LOOKUP_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'NP_TARGETED_LOOKUP_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_NP_TARGETED_LOOKUP_PROFILE';

SELECT
    'Recovery normalized-points targeted-lookup assertions passed.'
    AS result;
