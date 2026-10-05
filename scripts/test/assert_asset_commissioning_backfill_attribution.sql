-- ============================================================================
-- File:
--   scripts/test/assert_asset_commissioning_backfill_attribution.sql
--
-- Purpose:
--   Regression test for migration 257's per-point attribution computation,
--   telemetry.backfill_asset_commissioning_points(). This function has no
--   internal transaction control, so (unlike the claiming procedure,
--   tested separately in assert_asset_commissioning_backfill_job.sql) it
--   can run inside the standard rollback-safe BEGIN/ROLLBACK pattern.
--
--   Covers:
--     2. The 90-day boundary -- telemetry older than requested_at - 90d
--        is never used.
--     3. The effective_from boundary -- telemetry at/after the point's
--        current effective_from is never used (strict "<").
--     4. The effective_to boundary -- a prior, closed binding for the
--        SAME (device, point) blocks backfill from reaching into its
--        period, even when older telemetry technically exists there.
--     5. Multiple confirmed points from one device -- each point in the
--        triggering Save's "added" set is backfilled independently.
--     6. Source replacement / history preservation -- an asset_points row
--        NOT named in the triggering Save's "added" set (e.g. a later,
--        separate assignment) is never touched, even if telemetry exists
--        for it.
--     7. No telemetry available -- the function completes successfully,
--        makes no mutation, and reports it plainly.
--
--   Each scenario is an independent asset/device/point fixture. All
--   changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id            UUID;
    v_active_power_total_id UUID;
    v_reactive_power_l1_id  UUID;

    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_device_model UUID;

    v_user_a BIGINT;

    v_device UUID;
    v_device2 UUID;
    v_asset UUID;
    v_asset_point_id UUID;
    v_asset_point_id2 UUID;
    v_stray_point_id UUID;
    v_audit_id UUID;
    v_backfill_id UUID;
    v_requested_at TIMESTAMPTZ;
    v_result JSONB;
    v_effective_from TIMESTAMPTZ;
    v_stray_effective_from_before TIMESTAMPTZ;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_active_power_total_id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_reactive_power_l1_id  FROM metadata.logical_points WHERE name = 'REACTIVE_POWER_L1';

    IF v_energy_meter_category IS NULL OR v_profile_id IS NULL
       OR v_active_power_total_id IS NULL OR v_reactive_power_l1_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter category, ENERGY_METER_ENISCOPE_V1 profile, and ACTIVE_POWER_TOTAL/REACTIVE_POWER_L1 logical points';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Backfill Attribution Test Org', 'BACKFILL_ATTRIBUTION_TEST_ORG', 'UTC') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Backfill Attribution Test Site', 'BACKFILL_ATTRIBUTION_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Backfill Attribution Test Gateway', 'BACKFILL-ATTRIBUTION-TEST-GW')
    RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Backfill Attribution Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'backfill-attribution-test-user', 'Backfill Attribution Test User',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    -- ==================================================================
    -- SCENARIO 2+3: 90-day boundary AND effective_from (strict "<")
    -- boundary, in one fixture.
    -- ==================================================================
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 2', 'BACKFILL-ATTRIBUTION-METER-2', 'MQTT')
    RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Attribution Test Asset 2', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');

    v_requested_at := now();

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Main Active Power', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id;

    -- Outside the 90-day window -- must be ignored.
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '95 days', v_org, v_device, v_active_power_total_id, 100);
    -- Inside the 90-day window, strictly before effective_from -- the
    -- true expected earliest.
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '50 days', v_org, v_device, v_active_power_total_id, 101);
    -- AT effective_from exactly -- must NOT count as "earlier" (strict <).
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at, v_org, v_device, v_active_power_total_id, 102);
    -- After effective_from -- must never be considered at all.
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at + INTERVAL '1 hour', v_org, v_device, v_active_power_total_id, 103);

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        gen_random_uuid(), 'backfill-attribution-test-user',
        jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS'),
        jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_asset_point_id)))
    ) RETURNING id INTO v_audit_id;

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user_a, v_audit_id, v_requested_at, now())
    RETURNING id INTO v_backfill_id;

    v_result := telemetry.backfill_asset_commissioning_points(v_backfill_id);

    IF (v_result->>'points_processed')::int <> 1 OR (v_result->>'points_extended')::int <> 1 THEN
        RAISE EXCEPTION 'Expected points_processed=1/points_extended=1, got %', v_result;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id;
    IF v_effective_from <> v_requested_at - INTERVAL '50 days' THEN
        RAISE EXCEPTION 'Expected effective_from backdated to the 50-day-old reading (within the 90-day window, strictly before the original effective_from), got %', v_effective_from;
    END IF;

    -- ==================================================================
    -- SCENARIO 4: effective_to boundary -- a prior, closed binding for
    -- the SAME (device, point) blocks reaching into its period.
    -- ==================================================================
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 4', 'BACKFILL-ATTRIBUTION-METER-4', 'MQTT')
    RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Attribution Test Asset 4', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');

    v_requested_at := now();

    -- A PRIOR binding for the same (device, point) that closed 30 days
    -- ago (e.g. this point briefly belonged to a different asset once).
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Old Binding', v_requested_at - INTERVAL '60 days', v_requested_at - INTERVAL '30 days');

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Current Binding', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id;

    -- Inside the OLD (now-closed) binding's period -- must be excluded.
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '45 days', v_org, v_device, v_active_power_total_id, 200);
    -- After the old binding closed, before the current one starts --
    -- the true expected earliest.
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '20 days', v_org, v_device, v_active_power_total_id, 201);

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        gen_random_uuid(), 'backfill-attribution-test-user',
        jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS'),
        jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_asset_point_id)))
    ) RETURNING id INTO v_audit_id;

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user_a, v_audit_id, v_requested_at, now())
    RETURNING id INTO v_backfill_id;

    v_result := telemetry.backfill_asset_commissioning_points(v_backfill_id);

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id;
    IF v_effective_from <> v_requested_at - INTERVAL '20 days' THEN
        RAISE EXCEPTION 'Expected effective_from backdated only to the 20-day-old reading (blocked from reaching the prior binding''s period by effective_to), got %', v_effective_from;
    END IF;

    -- The OLD, closed binding must remain completely untouched (decision
    -- 8 immutability).
    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_points
        WHERE asset_id = v_asset AND device_id = v_device AND logical_point_id = v_active_power_total_id
          AND effective_from = v_requested_at - INTERVAL '60 days'
          AND effective_to = v_requested_at - INTERVAL '30 days'
    ) THEN
        RAISE EXCEPTION 'Expected the prior, closed binding to remain exactly unchanged';
    END IF;

    -- ==================================================================
    -- SCENARIO 5: multiple confirmed points from one device.
    -- ==================================================================
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 5', 'BACKFILL-ATTRIBUTION-METER-5', 'MQTT')
    RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Attribution Test Asset 5', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');

    v_requested_at := now();

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Active Power', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id;
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_reactive_power_l1_id, v_org, 'Reactive Power L1', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id2;

    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '10 days', v_org, v_device, v_active_power_total_id, 300);
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '25 days', v_org, v_device, v_reactive_power_l1_id, 301);

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        gen_random_uuid(), 'backfill-attribution-test-user',
        jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS'),
        jsonb_build_object('added', jsonb_build_array(
            jsonb_build_object('asset_point_id', v_asset_point_id),
            jsonb_build_object('asset_point_id', v_asset_point_id2)
        ))
    ) RETURNING id INTO v_audit_id;

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user_a, v_audit_id, v_requested_at, now())
    RETURNING id INTO v_backfill_id;

    v_result := telemetry.backfill_asset_commissioning_points(v_backfill_id);

    IF (v_result->>'points_processed')::int <> 2 OR (v_result->>'points_extended')::int <> 2 THEN
        RAISE EXCEPTION 'Expected points_processed=2/points_extended=2 for two points on one device, got %', v_result;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id;
    IF v_effective_from <> v_requested_at - INTERVAL '10 days' THEN
        RAISE EXCEPTION 'Expected ACTIVE_POWER_TOTAL backdated to its own 10-day-old reading, got %', v_effective_from;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id2;
    IF v_effective_from <> v_requested_at - INTERVAL '25 days' THEN
        RAISE EXCEPTION 'Expected REACTIVE_POWER_L1 backdated independently to its own 25-day-old reading, got %', v_effective_from;
    END IF;

    -- ==================================================================
    -- SCENARIO 6: source replacement / history preservation -- an
    -- asset_points row NOT in the triggering Save's "added" set must
    -- never be touched, even with telemetry available for it.
    -- ==================================================================
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 6', 'BACKFILL-ATTRIBUTION-METER-6', 'MQTT')
    RETURNING id INTO v_device;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 6b', 'BACKFILL-ATTRIBUTION-METER-6B', 'MQTT')
    RETURNING id INTO v_device2;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Attribution Test Asset 6', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device2, 'SECONDARY_METER');

    v_requested_at := now();

    -- The point that IS part of this commissioning trigger.
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Active Power', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id;

    -- A "stray" point -- confirmed on a DIFFERENT device, simulating a
    -- SEPARATE, later Save (e.g. a source replacement) that is NOT part
    -- of this backfill record's trigger. Telemetry exists for it too, but
    -- it must never be examined or modified by this job.
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device2, v_reactive_power_l1_id, v_org, 'Later Replacement', v_requested_at, NULL)
    RETURNING id INTO v_stray_point_id;

    SELECT effective_from INTO v_stray_effective_from_before FROM metadata.asset_points WHERE id = v_stray_point_id;

    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '15 days', v_org, v_device, v_active_power_total_id, 400);
    INSERT INTO telemetry.normalized_points(event_time, organization_id, device_id, logical_point_id, numeric_value)
    VALUES (v_requested_at - INTERVAL '15 days', v_org, v_device2, v_reactive_power_l1_id, 401);

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        gen_random_uuid(), 'backfill-attribution-test-user',
        jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS'),
        -- Only the FIRST point is in this trigger's added set.
        jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_asset_point_id)))
    ) RETURNING id INTO v_audit_id;

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user_a, v_audit_id, v_requested_at, now())
    RETURNING id INTO v_backfill_id;

    v_result := telemetry.backfill_asset_commissioning_points(v_backfill_id);

    IF (v_result->>'points_processed')::int <> 1 THEN
        RAISE EXCEPTION 'Expected exactly 1 point processed (only the triggering Save''s added set), got %', v_result;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id;
    IF v_effective_from <> v_requested_at - INTERVAL '15 days' THEN
        RAISE EXCEPTION 'Expected the in-scope point to be backdated, got %', v_effective_from;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_stray_point_id;
    IF v_effective_from <> v_stray_effective_from_before THEN
        RAISE EXCEPTION 'Expected the stray (out-of-scope) point''s effective_from to remain completely untouched, was % now %', v_stray_effective_from_before, v_effective_from;
    END IF;

    -- ==================================================================
    -- SCENARIO 7: no telemetry available -- succeeds, makes no mutation.
    -- ==================================================================
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Backfill Attribution Meter 7', 'BACKFILL-ATTRIBUTION-METER-7', 'MQTT')
    RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org, v_site, 'Backfill Attribution Test Asset 7', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');

    v_requested_at := now();

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device, v_active_power_total_id, v_org, 'Brand New Device', v_requested_at, NULL)
    RETURNING id INTO v_asset_point_id;
    -- Deliberately NO telemetry.normalized_points rows for this device.

    INSERT INTO admin.onboarding_audit(id, requested_by, request_payload, result_payload)
    VALUES (
        gen_random_uuid(), 'backfill-attribution-test-user',
        jsonb_build_object('operation', 'SAVE_ASSET_POINT_ASSIGNMENTS'),
        jsonb_build_object('added', jsonb_build_array(jsonb_build_object('asset_point_id', v_asset_point_id)))
    ) RETURNING id INTO v_audit_id;

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, trigger_audit_transaction_id, requested_at, started_at)
    VALUES (v_asset, 'RUNNING', v_user_a, v_audit_id, v_requested_at, now())
    RETURNING id INTO v_backfill_id;

    v_result := telemetry.backfill_asset_commissioning_points(v_backfill_id);

    IF (v_result->>'points_processed')::int <> 1 OR (v_result->>'points_extended')::int <> 0 THEN
        RAISE EXCEPTION 'Expected points_processed=1/points_extended=0 when no telemetry exists, got %', v_result;
    END IF;
    IF (v_result->'points'->0->>'earliest_telemetry_found') IS NOT NULL THEN
        RAISE EXCEPTION 'Expected earliest_telemetry_found=null when no telemetry exists, got %', v_result;
    END IF;

    SELECT effective_from INTO v_effective_from FROM metadata.asset_points WHERE id = v_asset_point_id;
    IF v_effective_from <> v_requested_at THEN
        RAISE EXCEPTION 'Expected effective_from to remain unchanged when no telemetry exists, was % now %', v_requested_at, v_effective_from;
    END IF;
END;
$test$;

\echo 'PASS: telemetry older than 90 days before commissioning is never used'
\echo 'PASS: telemetry at/after the point''s effective_from is never used (strict boundary)'
\echo 'PASS: a prior, closed binding for the same device+point blocks backfill from reaching into its period'
\echo 'PASS: multiple confirmed points from one device are each backfilled independently to their own earliest reading'
\echo 'PASS: an asset_points row outside the triggering Save''s added set is never touched (source replacement / history preservation)'
\echo 'PASS: no telemetry available completes successfully with no mutation'

ROLLBACK;

SELECT 'Asset commissioning backfill attribution assertions (migration 257) passed.' AS result;
