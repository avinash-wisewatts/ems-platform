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
--   This test proves, against a fully synthetic fixture:
--     A. a failed message with no replacement still recovers normally;
--     B. a later sample WITHIN the tolerance window is recognized as a
--        legitimate superseder (the failed message's own row is correctly
--        NOT inserted as a duplicate/stale capture sample);
--     C. a later sample OUTSIDE the tolerance window is NOT treated as a
--        superseder (the failed message recovers exactly as if the
--        out-of-window sample did not exist);
--     D. (updated 2026-08-26 for migration 206) an old failed message
--        (bucket from 60 days ago, older than any plausible retention
--        policy) is immediately marked PERMANENT_FAILURE by migration
--        206's age-based population selection, without running the
--        supersession/normalization logic -- this test originally asserted
--        the opposite ("age never disqualifies recovery"), which migration
--        206 deliberately overturned; see that migration's header;
--     E. the bounded predicate is actually present in the deployed
--        procedure (a live catalog check, not a text/file check), so the
--        historical unbounded scan cannot silently return;
--     F. (migration 220) the supersession NOT EXISTS tests same-bucket
--        membership by interval containment against ce's own bucket, not by
--        re-invoking telemetry.resolve_site_capture_bucket() per competing
--        rtdata element (the dense-publisher fan-out that kept Job 1077
--        hitting its 10-minute cap); exactly two resolve_site_capture_bucket
--        call sites remain (current_elements + v_has_normalized); and every
--        config.telemetry_capture_policies row is WALL_CLOCK, the precondition
--        for that interval derivation.
--
--   Migration 203 note: telemetry.recover_failed_raw_messages() now commits
--   after each candidate (see migration 203) and therefore MUST be invoked
--   as a bare top-level CALL -- wrapping it in an explicit transaction fails
--   with "invalid transaction termination". This test can no longer run
--   inside a BEGIN; ... ROLLBACK; wrapper the way it used to: the CALL below
--   really commits. Fixture rows are identified by distinctive business
--   keys (org/site/gateway/device/profile codes, the fixed source_topic,
--   and the fixed synthetic MQTT UID) and explicitly deleted at the end
--   instead, so the test remains idempotent and leaves no residue.
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

    -- Migration 218: recovery now requires a commissioned (ACTIVE) device.
    INSERT INTO metadata.devices(organization_id, gateway_id, profile_id, name, external_id, lifecycle_status)
    VALUES (v_org, v_gateway, v_profile, 'Recovery Supersession Test Device', 'RECOVERY-SUPERSESSION-DEV', 'ACTIVE')
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
    -- TEST D -- superseded by migration 206 (2026-08-26): population
    -- selection is now deliberately age-based against the live
    -- telemetry.raw_messages retention policy, not existence-based. A
    -- candidate whose raw_received_at is older than the current dynamic
    -- retention cutoff is immediately marked PERMANENT_FAILURE without
    -- running the supersession/normalization logic below -- this is the
    -- intended new behavior (see migration 206's header), not a
    -- regression. This test still uses a fixed 60-day-old bucket, which is
    -- older than every plausible deployed retention policy, so it now
    -- proves the opposite of what it originally asserted: age alone
    -- disqualifies recovery, and does so without touching
    -- capture_bucket_samples/normalized_points at all. Dynamic-cutoff
    -- correctness itself (reading the live policy, not a hard-coded
    -- duration) is covered by
    -- scripts/test/assert_recovery_retention_age_population.sql.
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

    IF v_status <> 'PERMANENT_FAILURE' THEN
        RAISE EXCEPTION 'TEST D FAILED: a 60-day-old failed message (older than any plausible retention policy) should be immediately marked PERMANENT_FAILURE by migration 206''s age-based population selection, got status %', v_status;
    END IF;

    SELECT count(*) INTO v_capture_count
    FROM telemetry.capture_bucket_samples
    WHERE device_id = v_device AND bucket_start = v_bucket_start AND raw_message_id = v_msg_id;

    IF v_capture_count <> 0 THEN
        RAISE EXCEPTION 'TEST D FAILED: a retention-expired candidate must not run the supersession/normalization logic at all, but found % capture_bucket_samples row(s)', v_capture_count;
    END IF;

    RAISE NOTICE 'TEST D passed: an old (60-day) failed message -- older than any plausible retention policy -- is now immediately marked PERMANENT_FAILURE by migration 206, without running the supersession logic.';

    -- ==================================================================
    -- TEST E -- the bounded, targeted-window predicate is actually present
    -- in the deployed procedure (live catalog check).
    --
    -- Migration 204 restructured the supersession subquery to read
    -- directly from telemetry.raw_messages (alias r2m) and apply the
    -- bucket_start/deadline window plus the rtdata-is-array guard BEFORE
    -- expanding JSON, instead of going through telemetry.v_rtdata (whose
    -- alias was r2, carrying received_at itself). r2 is now only the
    -- jsonb_array_elements() output alias and no longer has a received_at
    -- column at all -- so this check validates the actual semantic
    -- property (targeted source table, both window bounds, guard-then-
    -- expand ordering) rather than a literal string tied to the
    -- pre-migration-204 alias, which no longer exists.
    -- ==================================================================

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        NOT ILIKE '%FROM telemetry.raw_messages r2m%WHERE r2m.received_at>=ce.bucket_start%AND r2m.received_at<=ce.deadline%AND jsonb_typeof(r2m.payload->%rtdata%)=%array%%jsonb_array_elements(r2m.payload->%rtdata%) r2(value)%'
    THEN
        RAISE EXCEPTION 'TEST E FAILED: the deployed telemetry.recover_failed_raw_messages() does not read competing rows from telemetry.raw_messages with both the bucket_start/deadline window and the rtdata-is-array guard applied before jsonb_array_elements -- the historical unbounded scan may have returned';
    END IF;

    RAISE NOTICE 'TEST E passed: the deployed procedure sources competing rows from telemetry.raw_messages, bounded by both ce.bucket_start and ce.deadline, with the rtdata-is-array guard applied before JSON expansion.';

    -- ==================================================================
    -- TEST F (migration 220) -- the supersession NOT EXISTS tests
    -- same-bucket membership by INTERVAL CONTAINMENT against ce's own
    -- bucket, not by re-invoking telemetry.resolve_site_capture_bucket()
    -- per competing rtdata element. Live catalog check: the interval
    -- predicate is present and the per-competing-element bucket
    -- re-resolution (alias b2 / "b2.bucket_start=ce.bucket_start") is gone.
    -- current_elements still calls resolve_site_capture_bucket() once (the
    -- sole bucket authority) and the v_has_normalized check still calls it
    -- once per candidate; only the per-element fan-out was removed, so the
    -- deployed body must contain resolve_site_capture_bucket exactly twice.
    -- ==================================================================

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        NOT ILIKE '%COALESCE(ts2.source_timestamp,r2m.received_at) >= ce.bucket_start%COALESCE(ts2.source_timestamp,r2m.received_at) <%ce.bucket_start + make_interval(secs => ce.capture_interval_seconds)%'
    THEN
        RAISE EXCEPTION 'TEST F FAILED (migration 220): the supersession NOT EXISTS does not test same-bucket membership by interval containment against ce.bucket_start / ce.capture_interval_seconds';
    END IF;

    IF pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure)
        ILIKE '%) b2%WHERE lower(r2.value->>%uid%) IN%b2.bucket_start=ce.bucket_start%'
    THEN
        RAISE EXCEPTION 'TEST F FAILED (migration 220): the per-competing-element resolve_site_capture_bucket() fan-out (alias b2, b2.bucket_start=ce.bucket_start) is still present in the supersession subquery';
    END IF;

    IF ( length(pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure))
         - length(replace(pg_get_functiondef('telemetry.recover_failed_raw_messages(integer)'::regprocedure),
                          'CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket', ''))
       ) / length('CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket') <> 2
    THEN
        RAISE EXCEPTION 'TEST F FAILED (migration 220): expected exactly 2 CROSS JOIN LATERAL telemetry.resolve_site_capture_bucket call sites (current_elements + v_has_normalized); the per-element supersession call must be removed and no other added';
    END IF;

    -- Precondition for migration 220's interval derivation: every deployed
    -- capture policy uses WALL_CLOCK alignment. If a non-WALL_CLOCK mode is
    -- ever introduced, the interval-containment test is no longer provably
    -- equivalent to resolve_site_capture_bucket() and migration 220 must be
    -- re-audited for that mode.
    IF EXISTS (SELECT 1 FROM config.telemetry_capture_policies WHERE alignment_mode <> 'WALL_CLOCK') THEN
        RAISE EXCEPTION 'TEST F FAILED (migration 220 precondition): a config.telemetry_capture_policies row uses alignment_mode <> ''WALL_CLOCK''. Migration 220''s supersession interval-containment derivation must be re-audited for the new alignment mode before this is safe.';
    END IF;

    RAISE NOTICE 'TEST F passed (migration 220): supersession same-bucket test is interval-containment against ce''s own bucket; per-element resolve_site_capture_bucket() fan-out removed (exactly 2 call sites remain); all capture policies are WALL_CLOCK.';

END;
$test$;

-- ==================================================================
-- Cleanup -- the CALLs above really committed (migration 203), so
-- explicitly remove every row this fixture created, identified by its
-- distinctive business keys, in FK-safe (child-before-parent) order.
-- ==================================================================

DELETE FROM telemetry.normalized_points
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-SUPERSESSION-DEV');

DELETE FROM telemetry.capture_bucket_samples
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-SUPERSESSION-DEV');

DELETE FROM telemetry.raw_message_failures
WHERE payload->'rtdata'->0->>'uid' = 'TEST:RECOVERY:SUPERSESSION:001';

DELETE FROM telemetry.raw_messages
WHERE source_topic = 'test/recovery/supersession';

DELETE FROM config.device_point_configuration
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-SUPERSESSION-DEV');

DELETE FROM metadata.device_identifiers
WHERE device_id IN (SELECT id FROM metadata.devices WHERE external_id = 'RECOVERY-SUPERSESSION-DEV');

DELETE FROM config.profile_field_mapping
WHERE profile_id IN (SELECT id FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_SUPERSESSION_PROFILE');

DELETE FROM metadata.devices WHERE external_id = 'RECOVERY-SUPERSESSION-DEV';
DELETE FROM metadata.gateways WHERE external_id = 'RECOVERY-SUPERSESSION-GW';

DELETE FROM config.telemetry_capture_policies
WHERE site_id IN (SELECT id FROM metadata.sites WHERE code = 'RECOVERY_SUPERSESSION_TEST_SITE');

DELETE FROM metadata.sites WHERE code = 'RECOVERY_SUPERSESSION_TEST_SITE';
DELETE FROM metadata.organizations WHERE code = 'RECOVERY_SUPERSESSION_TEST_ORG';
DELETE FROM config.device_profiles WHERE profile_code = 'TEST_RECOVERY_SUPERSESSION_PROFILE';

SELECT
    'Recovery supersession late-arrival bound assertions passed.'
    AS result;
