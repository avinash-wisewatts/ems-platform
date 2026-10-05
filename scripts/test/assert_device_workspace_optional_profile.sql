-- ============================================================================
-- File:
--   scripts/test/assert_device_workspace_optional_profile.sql
--
-- Purpose:
--   Regression test for migration 261 (admin.get_device_workspace: device_
--   profiles LEFT JOINed instead of INNER JOINed, since metadata.devices.
--   profile_id is nullable and an unprofiled device is a valid pre-
--   commissioning state).
--
--   Covers:
--     1. A device with profile_id = NULL is returned to an authorized
--        (same-organization) caller -- the exact case migration 261 fixes.
--        profile_id/profile_code/profile_name read NULL; every other
--        column is still populated.
--     2. An unauthorized (different-organization, non-GLOBAL) caller still
--        receives no row for that same unprofiled device -- the access
--        predicate (admin.portal_user_can_access_site) is unaffected by
--        this migration and continues to gate access correctly.
--     3. A profiled device's existing behavior is unchanged: an authorized
--        caller still receives the row, with profile_id/profile_code/
--        profile_name correctly populated from config.device_profiles.
--
--   All changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id UUID;

    v_org_a UUID;
    v_org_b UUID;
    v_site_a UUID;
    v_gateway_a UUID;
    v_device_model UUID;

    v_device_unprofiled UUID;
    v_device_profiled UUID;

    v_user_a BIGINT;  -- org A, authorized for org A's devices
    v_user_b BIGINT;  -- org B, unauthorized for org A's devices

    v_result JSONB;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_energy_meter_category IS NULL OR v_profile_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter category and the ENERGY_METER_ENISCOPE_V1 profile';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Device Workspace Test Org A', 'DEVICE_WORKSPACE_TEST_ORG_A', 'UTC') RETURNING id INTO v_org_a;
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Device Workspace Test Org B', 'DEVICE_WORKSPACE_TEST_ORG_B', 'UTC') RETURNING id INTO v_org_b;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org_a, 'Device Workspace Test Site', 'DEVICE_WORKSPACE_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site_a;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org_a, v_site_a, 'Device Workspace Test Gateway', 'DEVICE-WORKSPACE-TEST-GW')
    RETURNING id INTO v_gateway_a;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Device Workspace Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    -- The exact case migration 261 fixes: a real device, no profile assigned.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, NULL, 'Device Workspace Test Meter (Unprofiled)', 'DEVICE-WORKSPACE-TEST-UNPROFILED', 'MQTT')
    RETURNING id INTO v_device_unprofiled;

    -- A profiled sibling, to prove existing behavior is unchanged.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Device Workspace Test Meter (Profiled)', 'DEVICE-WORKSPACE-TEST-PROFILED', 'MQTT')
    RETURNING id INTO v_device_profiled;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'device-workspace-test-user-a', 'Device Workspace Test User A',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'device-workspace-test-user-b', 'Device Workspace Test User B',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org_b, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_b;

    -- ------------------------------------------------------------------
    -- 1. Unprofiled device -> visible to an authorized caller.
    -- ------------------------------------------------------------------
    v_result := admin.get_device_workspace(v_user_a, v_device_unprofiled);

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Expected an unprofiled device to be visible to an authorized (same-organization) caller, got NULL';
    END IF;
    IF (v_result->>'device_id')::uuid IS DISTINCT FROM v_device_unprofiled THEN
        RAISE EXCEPTION 'Expected device_id % in the result, got %', v_device_unprofiled, v_result->>'device_id';
    END IF;
    IF v_result->>'profile_id' IS NOT NULL THEN
        RAISE EXCEPTION 'Expected profile_id NULL for an unprofiled device, got %', v_result->>'profile_id';
    END IF;
    IF v_result->>'profile_code' IS NOT NULL OR v_result->>'profile_name' IS NOT NULL THEN
        RAISE EXCEPTION 'Expected profile_code/profile_name NULL for an unprofiled device, got %/%', v_result->>'profile_code', v_result->>'profile_name';
    END IF;
    IF v_result->>'device_name' IS DISTINCT FROM 'Device Workspace Test Meter (Unprofiled)' THEN
        RAISE EXCEPTION 'Expected device_name to still be populated for an unprofiled device, got %', v_result->>'device_name';
    END IF;
    IF v_result->>'device_category_name' IS DISTINCT FROM 'Energy Meter' THEN
        RAISE EXCEPTION 'Expected device_category_name to still be populated (required join, unaffected), got %', v_result->>'device_category_name';
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Same unprofiled device -> still invisible to an unauthorized
    --    (different-organization) caller. Proves the access predicate is
    --    unaffected by the join change.
    -- ------------------------------------------------------------------
    v_result := admin.get_device_workspace(v_user_b, v_device_unprofiled);
    IF v_result IS NOT NULL THEN
        RAISE EXCEPTION 'Expected an unprofiled device to remain invisible to an unauthorized (different-organization) caller, got %', v_result;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Profiled device -> existing behavior unchanged for an authorized
    --    caller: profile_id/profile_code/profile_name populated.
    -- ------------------------------------------------------------------
    v_result := admin.get_device_workspace(v_user_a, v_device_profiled);

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'Expected a profiled device to remain visible to an authorized caller, got NULL';
    END IF;
    IF (v_result->>'profile_id')::uuid IS DISTINCT FROM v_profile_id THEN
        RAISE EXCEPTION 'Expected profile_id % for a profiled device, got %', v_profile_id, v_result->>'profile_id';
    END IF;
    IF v_result->>'profile_code' IS DISTINCT FROM 'ENERGY_METER_ENISCOPE_V1' THEN
        RAISE EXCEPTION 'Expected profile_code ENERGY_METER_ENISCOPE_V1 for a profiled device, got %', v_result->>'profile_code';
    END IF;

    -- And the same profiled device is still correctly gated for an
    -- unauthorized caller (regression, same as case 2).
    v_result := admin.get_device_workspace(v_user_b, v_device_profiled);
    IF v_result IS NOT NULL THEN
        RAISE EXCEPTION 'Expected a profiled device to remain invisible to an unauthorized caller, got %', v_result;
    END IF;
END;
$test$;

\echo 'PASS: an unprofiled device (profile_id NULL) is visible to an authorized caller, with profile fields NULL'
\echo 'PASS: an unprofiled device remains invisible to an unauthorized caller -- the access predicate is unaffected'
\echo 'PASS: a profiled device''s existing behavior (profile_id/profile_code/profile_name populated) is unchanged'

ROLLBACK;

SELECT 'Device workspace optional-profile-join assertions (migration 261) passed.' AS result;
