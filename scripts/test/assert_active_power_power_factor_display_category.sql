-- ============================================================================
-- File:
--   scripts/test/assert_active_power_power_factor_display_category.sql
--
-- Purpose:
--   Regression test for migration 262 (ACTIVE_POWER -> Power, POWER_FACTOR
--   -> Power Quality display categories).
--
--   Covers:
--     1. config.point_categories has a 'Power Quality' row.
--     2. ACTIVE_POWER's parameter_category_id resolves to 'Power'.
--     3. POWER_FACTOR's parameter_category_id resolves to 'Power Quality'.
--     4. Neither parameter's measurement_group_id (migration 254's
--        enforcement rule) changed -- ACTIVE_POWER stays POWER,
--        POWER_FACTOR stays POWER_QUALITY.
--     5. admin.list_asset_point_assignment_candidates (migration 253)
--        surfaces the corrected point_category_name end-to-end for a real
--        candidate row of each point -- not just the reference-data
--        tables in isolation.
--     6. No other, unrelated parameter was pulled into 'Power'/'Power
--        Quality' by this migration (scope stayed exactly as approved).
--
--   All changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id UUID;
    v_active_power_total_id UUID;
    v_power_factor_total_id UUID;

    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_device_model UUID;
    v_device UUID;
    v_asset UUID;
    v_user BIGINT;

    v_category TEXT;
    v_group TEXT;
    v_stray_count INTEGER;
    v_row RECORD;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_active_power_total_id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_power_factor_total_id FROM metadata.logical_points WHERE name = 'POWER_FACTOR_TOTAL';

    IF v_energy_meter_category IS NULL OR v_profile_id IS NULL
       OR v_active_power_total_id IS NULL OR v_power_factor_total_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter category, ENERGY_METER_ENISCOPE_V1 profile, and ACTIVE_POWER_TOTAL/POWER_FACTOR_TOTAL logical points';
    END IF;

    -- ------------------------------------------------------------------
    -- 1-4. Reference-data assertions, no fixtures needed.
    -- ------------------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM config.point_categories WHERE name = 'Power Quality') THEN
        RAISE EXCEPTION 'Expected a Power Quality point category to exist';
    END IF;

    SELECT pc.name INTO v_category
    FROM config.parameters p LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'ACTIVE_POWER';
    IF v_category IS DISTINCT FROM 'Power' THEN
        RAISE EXCEPTION 'Expected ACTIVE_POWER display category Power, got %', v_category;
    END IF;

    SELECT pc.name INTO v_category
    FROM config.parameters p LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'POWER_FACTOR';
    IF v_category IS DISTINCT FROM 'Power Quality' THEN
        RAISE EXCEPTION 'Expected POWER_FACTOR display category Power Quality, got %', v_category;
    END IF;

    SELECT cmg.code INTO v_group
    FROM config.parameters p LEFT JOIN config.canonical_measurement_groups cmg ON cmg.id = p.measurement_group_id
    WHERE p.code = 'ACTIVE_POWER';
    IF v_group IS DISTINCT FROM 'POWER' THEN
        RAISE EXCEPTION 'Expected ACTIVE_POWER measurement_group POWER (unchanged by this migration), got %', v_group;
    END IF;

    SELECT cmg.code INTO v_group
    FROM config.parameters p LEFT JOIN config.canonical_measurement_groups cmg ON cmg.id = p.measurement_group_id
    WHERE p.code = 'POWER_FACTOR';
    IF v_group IS DISTINCT FROM 'POWER_QUALITY' THEN
        RAISE EXCEPTION 'Expected POWER_FACTOR measurement_group POWER_QUALITY (unchanged by this migration), got %', v_group;
    END IF;

    SELECT count(*) INTO v_stray_count
    FROM config.parameters p
    JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE pc.name IN ('Power', 'Power Quality')
      AND p.code NOT IN ('ACTIVE_POWER', 'POWER_FACTOR');
    IF v_stray_count > 0 THEN
        RAISE EXCEPTION 'Expected no other parameter assigned to Power/Power Quality, found %', v_stray_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 5. End-to-end: the candidate function surfaces the corrected
    --    category for a real device/point, not just the reference tables.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Display Category Test Org', 'DISPLAY_CATEGORY_TEST_ORG', 'UTC') RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Display Category Test Site', 'DISPLAY_CATEGORY_TEST_SITE', 'UTC', '{}'::jsonb, TRUE) RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Display Category Test Gateway', 'DISPLAY-CATEGORY-TEST-GW') RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Display Category Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Display Category Test Meter', 'DISPLAY-CATEGORY-TEST-METER', 'MQTT') RETURNING id INTO v_device;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org, v_site, 'Display Category Test Asset', 'active', 'DIRECT_METER_REQUIRED') RETURNING id INTO v_asset;
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset, v_device, 'PRIMARY_METER');
    INSERT INTO admin.portal_users(username, display_name, password_hash, role_code, is_active, access_scope_mode, organization_id, created_by)
    VALUES ('display-category-test-user', 'Display Category Test User', 'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org, 'test-fixture')
    RETURNING portal_user_id INTO v_user;

    SELECT point_category_name INTO v_row
    FROM admin.list_asset_point_assignment_candidates(v_user, v_asset)
    WHERE logical_point_id = v_active_power_total_id;
    IF v_row.point_category_name IS DISTINCT FROM 'Power' THEN
        RAISE EXCEPTION 'Expected the candidate function to show ACTIVE_POWER_TOTAL under Power, got %', v_row.point_category_name;
    END IF;

    SELECT point_category_name INTO v_row
    FROM admin.list_asset_point_assignment_candidates(v_user, v_asset)
    WHERE logical_point_id = v_power_factor_total_id;
    IF v_row.point_category_name IS DISTINCT FROM 'Power Quality' THEN
        RAISE EXCEPTION 'Expected the candidate function to show POWER_FACTOR_TOTAL under Power Quality, got %', v_row.point_category_name;
    END IF;
END;
$test$;

\echo 'PASS: config.point_categories has a Power Quality row'
\echo 'PASS: ACTIVE_POWER resolves to display category Power, POWER_FACTOR to Power Quality'
\echo 'PASS: measurement_group_id (enforcement) is unchanged for both parameters'
\echo 'PASS: no other parameter was pulled into Power/Power Quality'
\echo 'PASS: admin.list_asset_point_assignment_candidates surfaces the corrected category end-to-end'

ROLLBACK;

SELECT 'ACTIVE_POWER/POWER_FACTOR display-category assertions (migration 262) passed.' AS result;
