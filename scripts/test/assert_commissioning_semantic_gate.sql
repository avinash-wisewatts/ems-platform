-- ============================================================================
-- File:
--   scripts/test/assert_commissioning_semantic_gate.sql
--
-- Purpose:
--   Regression test for the 2026-08-25 commissioning-semantic-gate hardening
--   (migration 199): admin.commission_device() must refuse to transition a
--   device to ACTIVE when its device profile's config.profile_field_mapping
--   is missing a row flagged is_required = TRUE, using
--   config.assert_profile_field_mapping_complete() (migration 198) to
--   produce the diagnostic.
--
--   Uses synthetic, rollback-only organizations/profiles throughout (the
--   established convention in this test suite -- see
--   assert_asset_demand_automatic_decoupling.sql) rather than the real
--   ENERGY_METER_ENISCOPE_V1 profile, so this test does not depend on (or
--   risk perturbing) live Meenaxy configuration, and so a passing "no
--   accidental Eniscope-specific field list" result (Test F) is meaningful
--   rather than circular.
--
-- Failure behavior:
--   Any assertion failure raises an exception and causes the test runner to
--   fail. Everything runs inside one transaction that always rolls back.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_actor BIGINT;
    v_protocol UUID;
    v_energy_category UUID;
    v_lp_power UUID;
    v_lp_voltage UUID;
    v_lp_current UUID;

    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_device_model UUID;

    v_complete_profile UUID;
    v_incomplete_profile UUID;

    v_org2 UUID;
    v_site2 UUID;
    v_gateway2 UUID;

    v_device UUID;
    v_result JSONB;
    v_error_message TEXT;
    v_raised BOOLEAN;
BEGIN
    -- ------------------------------------------------------------------
    -- Shared fixture prerequisites.
    -- ------------------------------------------------------------------

    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    SELECT id INTO v_energy_category FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_lp_power FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL' LIMIT 1;
    SELECT id INTO v_lp_voltage FROM metadata.logical_points WHERE name = 'VOLTAGE_LN_AVG' LIMIT 1;
    SELECT id INTO v_lp_current FROM metadata.logical_points WHERE name = 'CURRENT_TOTAL' LIMIT 1;

    IF v_protocol IS NULL OR v_energy_category IS NULL OR v_lp_power IS NULL
       OR v_lp_voltage IS NULL OR v_lp_current IS NULL THEN
        RAISE EXCEPTION 'Commissioning-gate fixture requires MQTT, an Energy Meter category, and ACTIVE_POWER_TOTAL/VOLTAGE_LN_AVG/CURRENT_TOTAL logical points';
    END IF;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        created_by, access_scope_mode
    ) VALUES (
        'commissioning_gate_test_actor', 'Commissioning Gate Test Actor', 'test-hash',
        'ADMIN', TRUE, 'test', 'GLOBAL'
    ) RETURNING portal_user_id INTO v_actor;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Commissioning Gate Test Org', 'COMMISSIONING_GATE_TEST', 'UTC')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Commissioning Gate Test Site', 'COMMISSIONING_GATE_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Commissioning Gate Test Gateway', 'COMMISSIONING-GATE-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Commissioning Gate Test Meter', 'Energy Meter', v_energy_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    -- A "complete" synthetic profile: two required raw fields, both mapped.
    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model, firmware_version,
        profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_COMMISSIONING_GATE_COMPLETE', 'WiseWatts Test',
        'CommissioningGateComplete', '1', 'Commissioning Gate Complete Test Profile',
        'Rollback-only commissioning-gate regression fixture', TRUE
    ) RETURNING id INTO v_complete_profile;

    INSERT INTO config.device_profile_categories(profile_id, device_category_id)
    VALUES (v_complete_profile, v_energy_category);

    INSERT INTO config.device_profile_required_fields(profile_id, raw_field_name)
    VALUES
        (v_complete_profile, 'P'),
        (v_complete_profile, 'V');

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required, display_order)
    VALUES
        (v_complete_profile, 'P', v_lp_power, TRUE, 1),
        (v_complete_profile, 'V', v_lp_voltage, TRUE, 2);

    -- ==================================================================
    -- TEST A -- valid/complete profile: commissioning succeeds.
    -- ==================================================================

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org, v_gateway, v_complete_profile, v_device_model,
        'Test A Device', 'COMMISSIONING-GATE-TEST-A', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    INSERT INTO telemetry.device_point_state(
        device_id, logical_point_id, first_seen_at, last_seen_at, last_received_at,
        first_valid_seen_at, last_valid_seen_at, last_valid_received_at
    ) VALUES
        (v_device, v_lp_power, now(), now(), now(), now(), now(), now()),
        (v_device, v_lp_voltage, now(), now(), now(), now(), now(), now());

    v_result := admin.commission_device(v_actor, v_device);

    IF (v_result->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST A FAILED: expected commissioning to succeed for a complete profile, got %', v_result;
    END IF;

    IF (SELECT lifecycle_status FROM metadata.devices WHERE id = v_device) <> 'ACTIVE' THEN
        RAISE EXCEPTION 'TEST A FAILED: device did not transition to ACTIVE';
    END IF;

    RAISE NOTICE 'TEST A passed: complete profile commissions successfully and reaches ACTIVE.';

    -- ==================================================================
    -- TEST B -- one missing required mapping: commissioning MUST fail,
    -- device MUST NOT become ACTIVE, error MUST name profile + field.
    -- ==================================================================

    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model, firmware_version,
        profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_COMMISSIONING_GATE_MISSING_ONE', 'WiseWatts Test',
        'CommissioningGateMissingOne', '1', 'Commissioning Gate Missing-One Test Profile',
        'Rollback-only commissioning-gate regression fixture', TRUE
    ) RETURNING id INTO v_incomplete_profile;

    INSERT INTO config.device_profile_categories(profile_id, device_category_id)
    VALUES (v_incomplete_profile, v_energy_category);

    -- This profile's durable contract declares BOTH 'P' and 'V' required,
    -- but only 'P' ever gets a config.profile_field_mapping row -- 'V' has
    -- no mapping row at all. This is deliberately the exact 2026-08-20
    -- failure shape (a raw field never wired to any logical point), not
    -- merely an is_required = FALSE row, and it is exactly the shape an
    -- earlier draft of migration 199 failed to catch: that draft derived
    -- its required-field list from config.profile_field_mapping.is_required
    -- itself, which is structurally incapable of naming a field whose
    -- mapping row was never created (logical_point_id is NOT NULL on that
    -- table, so a row's existence IS the mapping). The fix sources the
    -- required list from the new, independent
    -- config.device_profile_required_fields table instead.
    INSERT INTO config.device_profile_required_fields(profile_id, raw_field_name)
    VALUES
        (v_incomplete_profile, 'P'),
        (v_incomplete_profile, 'V');

    INSERT INTO config.profile_field_mapping(profile_id, raw_field_name, logical_point_id, is_required, display_order)
    VALUES (v_incomplete_profile, 'P', v_lp_power, TRUE, 1);
    -- 'V' intentionally never inserted here.

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org, v_gateway, v_incomplete_profile, v_device_model,
        'Test B Device', 'COMMISSIONING-GATE-TEST-B', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    INSERT INTO telemetry.device_point_state(
        device_id, logical_point_id, first_seen_at, last_seen_at, last_received_at,
        first_valid_seen_at, last_valid_seen_at, last_valid_received_at
    ) VALUES
        (v_device, v_lp_power, now(), now(), now(), now(), now(), now());

    v_raised := FALSE;
    BEGIN
        PERFORM admin.commission_device(v_actor, v_device);
        RAISE EXCEPTION 'TEST FAILURE MARKER: commission_device did not raise for a device with a missing required mapping';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE MARKER%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST B FAILED: expected commission_device to raise, but it returned normally';
    END IF;

    IF v_error_message !~ 'TEST_COMMISSIONING_GATE_MISSING_ONE' OR v_error_message !~ '\yV\y' THEN
        RAISE EXCEPTION 'TEST B FAILED: error did not identify the profile and missing field as expected: %', v_error_message;
    END IF;

    IF (SELECT lifecycle_status FROM metadata.devices WHERE id = v_device) = 'ACTIVE' THEN
        RAISE EXCEPTION 'TEST B FAILED: device transitioned to ACTIVE despite the missing required mapping';
    END IF;

    RAISE NOTICE 'TEST B passed: single missing required mapping blocks commissioning with a specific diagnostic: %', v_error_message;

    -- ==================================================================
    -- TEST C -- multiple missing mappings: commissioning fails, no
    -- partial transition, diagnostic identifies more than one field.
    -- ==================================================================

    -- Reuse the same incomplete profile; also drop 'P' so two required
    -- fields are missing, then try a fresh device against it.
    DELETE FROM config.profile_field_mapping
    WHERE profile_id = v_incomplete_profile
      AND raw_field_name = 'P';

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org, v_gateway, v_incomplete_profile, v_device_model,
        'Test C Device', 'COMMISSIONING-GATE-TEST-C', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.commission_device(v_actor, v_device);
        RAISE EXCEPTION 'TEST FAILURE MARKER: commission_device did not raise for a device with multiple missing required mappings';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE MARKER%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST C FAILED: expected commission_device to raise, but it returned normally';
    END IF;

    IF v_error_message !~ '\yP\y' OR v_error_message !~ '\yV\y' THEN
        RAISE EXCEPTION 'TEST C FAILED: error did not name both missing fields: %', v_error_message;
    END IF;

    IF (SELECT lifecycle_status FROM metadata.devices WHERE id = v_device) = 'ACTIVE' THEN
        RAISE EXCEPTION 'TEST C FAILED: device transitioned to ACTIVE despite multiple missing required mappings';
    END IF;

    IF EXISTS (
        SELECT 1 FROM admin.onboarding_audit
        WHERE request_payload->>'device_id' = v_device::text
    ) THEN
        RAISE EXCEPTION 'TEST C FAILED: a rejected commissioning attempt must not write an onboarding_audit row (no partial success trace)';
    END IF;

    RAISE NOTICE 'TEST C passed: multiple missing required mappings block commissioning, diagnostic names both, no partial transition or audit row.';

    -- ==================================================================
    -- TEST D -- energy-register semantics: explicitly NOT part of this
    -- gate. config.energy_register_semantics governs cumulative-counter
    -- classification (gap/reset/rollover handling for consumption/demand
    -- reporting) -- a device can correctly report instantaneous power/
    -- voltage/current (what commissioning proves) with incomplete
    -- register semantics; that only degrades energy-consumption
    -- reporting correctness, a separate concern with its own guard
    -- (config.assert_energy_register_semantics_complete, migration 198)
    -- called nowhere in this commissioning path. Prove commissioning
    -- succeeds for a profile with a complete field mapping but NO
    -- energy_register_semantics rows at all.
    -- ==================================================================

    IF EXISTS (
        SELECT 1 FROM config.energy_register_semantics
        WHERE profile_id = v_complete_profile
    ) THEN
        RAISE EXCEPTION 'TEST D FAILED: fixture assumption violated -- the complete test profile unexpectedly has energy_register_semantics rows';
    END IF;

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org, v_gateway, v_complete_profile, v_device_model,
        'Test D Device', 'COMMISSIONING-GATE-TEST-D', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    INSERT INTO telemetry.device_point_state(
        device_id, logical_point_id, first_seen_at, last_seen_at, last_received_at,
        first_valid_seen_at, last_valid_seen_at, last_valid_received_at
    ) VALUES
        (v_device, v_lp_power, now(), now(), now(), now(), now(), now()),
        (v_device, v_lp_voltage, now(), now(), now(), now(), now(), now());

    v_result := admin.commission_device(v_actor, v_device);

    IF (v_result->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST D FAILED: commissioning must succeed without energy_register_semantics rows (out of scope for this gate), got %', v_result;
    END IF;

    RAISE NOTICE 'TEST D passed: energy_register_semantics completeness is correctly NOT part of the commissioning gate.';

    -- ==================================================================
    -- TEST E -- unknown/unset profile: must fail loudly (pre-existing
    -- analytics.v_commissioning_readiness behavior), not silently skip
    -- validation just because the new gate has nothing to check.
    -- ==================================================================

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org, v_gateway, NULL, v_device_model,
        'Test E Device', 'COMMISSIONING-GATE-TEST-E', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.commission_device(v_actor, v_device);
        RAISE EXCEPTION 'TEST FAILURE MARKER: commission_device did not raise for a device with no profile assigned';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE MARKER%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
            v_error_message := SQLERRM;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST E FAILED: expected commission_device to raise for an unassigned profile, but it returned normally';
    END IF;

    IF v_error_message !~ 'DEVICE_PROFILE_REQUIRED' THEN
        RAISE EXCEPTION 'TEST E FAILED: unexpected error for a device with no profile: %', v_error_message;
    END IF;

    RAISE NOTICE 'TEST E passed: a device with no profile assigned still fails loudly via the pre-existing readiness gate.';

    -- ==================================================================
    -- TEST F -- existing non-electrical profile (AirSense): commissioning
    -- is not accidentally subjected to any Eniscope-specific (or other
    -- profile's) required-field list. Uses the real, already-seeded
    -- ENVIRONMENT_SENSOR_AIRSENSE_V1 profile, which migration 199 did not
    -- add any config.device_profile_required_fields rows for, so the new
    -- gate call must be a pure no-op for it.
    -- ==================================================================

    DECLARE
        v_airsense_profile UUID;
        v_airsense_category UUID;
        v_env_model UUID;
    BEGIN
        SELECT id INTO v_airsense_profile
        FROM config.device_profiles
        WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';

        IF v_airsense_profile IS NULL THEN
            RAISE EXCEPTION 'TEST F FAILED: fixture assumption violated -- ENVIRONMENT_SENSOR_AIRSENSE_V1 must exist on the canonical database';
        END IF;

        IF EXISTS (
            SELECT 1 FROM config.device_profile_required_fields
            WHERE profile_id = v_airsense_profile
        ) THEN
            RAISE EXCEPTION 'TEST F FAILED: fixture assumption violated -- AirSense unexpectedly has device_profile_required_fields rows (migration 199 must not have touched it)';
        END IF;

        -- analytics.v_commissioning_readiness's PROFILE_CATEGORY_INCOMPATIBLE
        -- check requires a config.device_profile_categories row linking this
        -- profile to the device_model's category -- AirSense has none
        -- pre-seeded on the canonical test database (a pre-existing,
        -- unrelated condition), so this fixture adds one for the duration of
        -- this rolled-back test transaction, exactly mirroring how the
        -- complete/incomplete synthetic profiles above are wired.
        SELECT id INTO v_airsense_category
        FROM config.device_categories
        WHERE name = 'Environmental Sensor';

        IF v_airsense_category IS NULL THEN
            RAISE EXCEPTION 'TEST F FAILED: fixture assumption violated -- no Environmental Sensor device category exists to build a compatible device_model from';
        END IF;

        INSERT INTO config.device_profile_categories(profile_id, device_category_id)
        VALUES (v_airsense_profile, v_airsense_category)
        ON CONFLICT (profile_id, device_category_id) DO NOTHING;

        INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
        VALUES ('WiseWatts Test', 'Commissioning Gate AirSense Test Sensor', 'Environment Sensor', v_airsense_category)
        ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
        DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
        RETURNING id INTO v_env_model;

        INSERT INTO metadata.devices(
            organization_id, gateway_id, profile_id, device_model_id,
            name, external_id, protocol, operational_policy, lifecycle_status
        ) VALUES (
            v_org, v_gateway, v_airsense_profile, v_env_model,
            'Test F Device', 'COMMISSIONING-GATE-TEST-F', 'MQTT', 'STANDALONE', 'REGISTERED'
        ) RETURNING id INTO v_device;

        -- No telemetry.device_point_state fixtures are added: AirSense has
        -- no is_required rows, so the pre-existing readiness view's
        -- required_point_count is 0 for this device regardless, and it
        -- should be considered ready on that dimension alone.
        v_result := admin.commission_device(v_actor, v_device);

        IF (v_result->>'success')::boolean IS NOT TRUE THEN
            RAISE EXCEPTION 'TEST F FAILED: AirSense commissioning must not be blocked by an Eniscope-or-other-profile-specific field list, got %', v_result;
        END IF;
    END;

    RAISE NOTICE 'TEST F passed: an existing non-electrical profile (AirSense) commissions normally, unaffected by any other profile''s required-field list.';

    -- ==================================================================
    -- TEST G -- tenant isolation: the gate must resolve the profile
    -- actually assigned to the entity being commissioned, and must not
    -- read another organization's device/profile configuration. Proven
    -- by commissioning a second organization's device against the SAME
    -- complete profile (config.profile_field_mapping is profile-scoped,
    -- not tenant-scoped, so the real isolation property to prove is that
    -- device B's own profile_id is what gets checked -- not org A's
    -- device, not a hardcoded profile, not another tenant's mapping).
    -- ==================================================================

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Commissioning Gate Test Org 2', 'COMMISSIONING_GATE_TEST_2', 'UTC')
    RETURNING id INTO v_org2;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org2, 'Commissioning Gate Test Site 2', 'COMMISSIONING_GATE_SITE_2', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site2;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org2, v_site2, 'Commissioning Gate Test Gateway 2', 'COMMISSIONING-GATE-GW-2')
    RETURNING id INTO v_gateway2;

    -- Org 2's device uses the same complete profile as Test A/D -- must
    -- succeed on its own merits (its own telemetry proof), not because
    -- org 1 already commissioned a device against this profile.
    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org2, v_gateway2, v_complete_profile, v_device_model,
        'Test G Device (org 2, complete profile)', 'COMMISSIONING-GATE-TEST-G-OK', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    INSERT INTO telemetry.device_point_state(
        device_id, logical_point_id, first_seen_at, last_seen_at, last_received_at,
        first_valid_seen_at, last_valid_seen_at, last_valid_received_at
    ) VALUES
        (v_device, v_lp_power, now(), now(), now(), now(), now(), now()),
        (v_device, v_lp_voltage, now(), now(), now(), now(), now(), now());

    v_result := admin.commission_device(v_actor, v_device);

    IF (v_result->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST G FAILED (positive case): org 2 device with the complete profile must commission successfully, got %', v_result;
    END IF;

    -- And org 2's device using the SAME incomplete profile that blocked
    -- org 1's devices (Test B/C) must ALSO be blocked -- proving the
    -- check is keyed off the device's own profile_id, not organization_id.
    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol, operational_policy, lifecycle_status
    ) VALUES (
        v_org2, v_gateway2, v_incomplete_profile, v_device_model,
        'Test G Device (org 2, incomplete profile)', 'COMMISSIONING-GATE-TEST-G-FAIL', 'MQTT', 'STANDALONE', 'REGISTERED'
    ) RETURNING id INTO v_device;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.commission_device(v_actor, v_device);
        RAISE EXCEPTION 'TEST FAILURE MARKER: commission_device did not raise for org 2''s device on the same incomplete profile';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE MARKER%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST G FAILED (negative case): org 2 device on the incomplete profile must also be blocked';
    END IF;

    RAISE NOTICE 'TEST G passed: readiness is resolved per-device/per-profile, correctly independent of organization_id, with no cross-tenant leakage.';

END;
$test$;

ROLLBACK;

SELECT
    'Commissioning semantic-completeness gate assertions passed.'
    AS result;
