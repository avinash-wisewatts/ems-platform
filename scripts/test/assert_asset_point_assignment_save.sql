-- ============================================================================
-- File:
--   scripts/test/assert_asset_point_assignment_save.sql
--
-- Purpose:
--   Regression test for migration 255 (admin.save_asset_point_assignments).
--
--   Covers, as separate concerns:
--     1. Add.
--     2. Remove (closes, never deletes) + history preservation.
--     3. Friendly-name-only edit (updates in place, does not re-date
--        effective_from / close+reopen).
--     4. Duplicate logical_point_id within one payload rejected.
--     5. A non-existent/disabled point rejected.
--     6. Unauthorized actor (no asset.manage) and cross-tenant actor
--        rejected, zero mutation.
--     7. Decommissioned asset rejected.
--     8. Same measurement group ("Power": Active/Reactive/Apparent),
--        different device -> rejected; same device -> allowed.
--     9. Different Energy groups (Import vs Export), different device ->
--        allowed (Energy's three groups are independent).
--    10. Same Energy group (Import), different device -> rejected,
--        leaving prior state unchanged (no partial apply).
--
--   Note on timestamps: the whole test runs inside one outer transaction,
--   and PostgreSQL's now()/transaction_timestamp() is fixed for the
--   entire transaction -- it does not advance between statements or
--   function calls. A row ADDED via the Save function earlier in this
--   same test transaction therefore cannot later be REMOVED via the Save
--   function within the same transaction (effective_to would equal
--   effective_from exactly, violating ck_asset_points_effective_window).
--   This is purely a test-harness artifact of wrapping many Save calls in
--   one transaction, not a production concern (a real Save is its own
--   transaction, so now() genuinely differs between an add and a later
--   remove). The remove/history-preservation scenario below therefore
--   fixtures its row via a direct INSERT with an explicit PAST
--   effective_from (same idiom as migration 253's own test), then closes
--   it through the Save function -- exactly like migration 253's
--   "historical (closed) assignment" fixture.
--
--   All changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_energy_meter_category UUID;
    v_profile_id            UUID;

    v_active_power_total_id  UUID;
    v_reactive_power_l1_id   UUID;
    v_apparent_power_l1_id   UUID;
    v_power_factor_total_id  UUID;
    v_energy_import_total_id UUID;
    v_energy_export_total_id UUID;

    v_org_a UUID;
    v_org_b UUID;
    v_site_a UUID;
    v_gateway_a UUID;
    v_device_model UUID;
    v_device_a UUID;
    v_device_b UUID;
    v_asset UUID;
    v_decommissioned_asset UUID;
    v_user_a BIGINT;       -- org A, OPERATOR (asset.manage)
    v_user_b BIGINT;       -- org B, OPERATOR (cross-tenant)
    v_user_viewer BIGINT;  -- org A, VIEWER (no asset.manage)

    v_device_a_points JSONB := '[]'::jsonb;  -- accumulated full-replace payload for device A
    v_result JSONB;
    v_count INTEGER;
    v_pf_asset_point_id UUID;
    v_pf_effective_from_before TIMESTAMPTZ;
    v_ap_effective_from_before TIMESTAMPTZ;
    v_ap_effective_from_after  TIMESTAMPTZ;
    v_ap_asset_point_id UUID;
    v_raised BOOLEAN;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_active_power_total_id  FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_reactive_power_l1_id   FROM metadata.logical_points WHERE name = 'REACTIVE_POWER_L1';
    SELECT id INTO v_apparent_power_l1_id   FROM metadata.logical_points WHERE name = 'APPARENT_POWER_L1';
    SELECT id INTO v_power_factor_total_id  FROM metadata.logical_points WHERE name = 'POWER_FACTOR_TOTAL';
    SELECT id INTO v_energy_import_total_id FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL';
    SELECT id INTO v_energy_export_total_id FROM metadata.logical_points WHERE name = 'ENERGY_EXPORT_TOTAL';

    IF v_energy_meter_category IS NULL OR v_profile_id IS NULL
       OR v_active_power_total_id IS NULL OR v_reactive_power_l1_id IS NULL
       OR v_apparent_power_l1_id IS NULL OR v_power_factor_total_id IS NULL
       OR v_energy_import_total_id IS NULL OR v_energy_export_total_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter category, ENERGY_METER_ENISCOPE_V1 profile, and ACTIVE_POWER_TOTAL/REACTIVE_POWER_L1/APPARENT_POWER_L1/POWER_FACTOR_TOTAL/ENERGY_IMPORT_TOTAL/ENERGY_EXPORT_TOTAL logical points (migration 254 coverage)';
    END IF;

    -- ------------------------------------------------------------------
    -- Fixture: two tenants, one asset in org A related to two devices
    -- (device A = PRIMARY_METER, device B = SECONDARY_METER), one
    -- decommissioned asset, three portal users.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Point Save Test Org A', 'POINT_SAVE_TEST_ORG_A', 'UTC') RETURNING id INTO v_org_a;
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Point Save Test Org B', 'POINT_SAVE_TEST_ORG_B', 'UTC') RETURNING id INTO v_org_b;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org_a, 'Point Save Test Site', 'POINT_SAVE_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site_a;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org_a, v_site_a, 'Point Save Test Gateway', 'POINT-SAVE-TEST-GW')
    RETURNING id INTO v_gateway_a;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Point Save Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Point Save Meter A', 'POINT-SAVE-METER-A', 'MQTT')
    RETURNING id INTO v_device_a;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Point Save Meter B', 'POINT-SAVE-METER-B', 'MQTT')
    RETURNING id INTO v_device_b;
    -- config.device_point_configuration auto-populated for both devices by
    -- trg_sync_device_points_after_profile_change when profile_id was set.

    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Point Save Test Asset', 'active', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;

    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Point Save Test Decommissioned Asset', 'inactive', 'DECOMMISSIONED', 'NOT_REQUIRED')
    RETURNING id INTO v_decommissioned_asset;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device_a, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device_b, 'SECONDARY_METER');

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'point-save-test-user-a', 'Point Save Test User A',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'point-save-test-user-b', 'Point Save Test User B',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org_b, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_b;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'point-save-test-user-viewer', 'Point Save Test Viewer',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_viewer;

    -- ------------------------------------------------------------------
    -- 6. Unauthorized actor (no asset.manage) rejected -- zero mutation.
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_viewer, v_asset, v_device_a,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'x'))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected unauthorized actor (VIEWER, no asset.manage) to be rejected with 42501';
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_points WHERE asset_id = v_asset;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Unauthorized Save call must not have mutated metadata.asset_points, found % row(s)', v_count;
    END IF;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_b, v_asset, v_device_a,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'x'))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '42501' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected cross-tenant actor to be rejected with 42501';
    END IF;

    -- ------------------------------------------------------------------
    -- 7. Decommissioned asset rejected.
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_decommissioned_asset, v_device_a,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'x'))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23514' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected a decommissioned asset to be rejected with 23514';
    END IF;

    -- ------------------------------------------------------------------
    -- 5. A point not enabled/configured for the device is rejected.
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset, v_device_a,
            jsonb_build_array(jsonb_build_object('logical_point_id', gen_random_uuid(), 'friendly_name', NULL))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23514' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected a non-enabled/non-existent point to be rejected with 23514';
    END IF;

    UPDATE config.device_point_configuration
    SET is_enabled = FALSE
    WHERE device_id = v_device_a AND logical_point_id = v_apparent_power_l1_id;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset, v_device_a,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_apparent_power_l1_id, 'friendly_name', NULL))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23514' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected a disabled device_point_configuration row to be rejected with 23514';
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Duplicate logical_point_id within one payload rejected.
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset, v_device_a,
            jsonb_build_array(
                jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'x'),
                jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'y')
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23505' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected a duplicate logical_point_id in one payload to be rejected with 23505';
    END IF;

    -- All rejections above must have left the asset with zero rows.
    SELECT count(*) INTO v_count FROM metadata.asset_points WHERE asset_id = v_asset;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero asset_points rows after all rejection scenarios, found %', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 1. Add -- confirm ACTIVE_POWER_TOTAL on device A.
    -- ------------------------------------------------------------------
    v_device_a_points := jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Main Active Power'));

    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_a, v_device_a_points);

    IF jsonb_array_length(v_result->'added') <> 1
       OR jsonb_array_length(v_result->'removed') <> 0
       OR jsonb_array_length(v_result->'unchanged') <> 0 THEN
        RAISE EXCEPTION 'Expected add result added=1/removed=0/unchanged=0, got %', v_result;
    END IF;

    SELECT id, effective_from INTO v_ap_asset_point_id, v_ap_effective_from_before
    FROM metadata.asset_points
    WHERE asset_id = v_asset AND device_id = v_device_a AND logical_point_id = v_active_power_total_id
      AND effective_range @> now();
    IF v_ap_asset_point_id IS NULL THEN
        RAISE EXCEPTION 'Expected a currently-effective asset_points row after add';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM admin.onboarding_audit
        WHERE id = (v_result->>'audit_transaction_id')::uuid
          AND request_payload->>'operation' = 'SAVE_ASSET_POINT_ASSIGNMENTS'
    ) THEN
        RAISE EXCEPTION 'Expected an admin.onboarding_audit row for the add Save';
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Friendly-name-only edit -- same point, changed friendly_name.
    --    Must update in place: same asset_point_id, same effective_from.
    -- ------------------------------------------------------------------
    v_device_a_points := jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Main Incoming Power'));

    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_a, v_device_a_points);

    IF jsonb_array_length(v_result->'unchanged') <> 1
       OR jsonb_array_length(v_result->'added') <> 0
       OR jsonb_array_length(v_result->'removed') <> 0 THEN
        RAISE EXCEPTION 'Expected friendly-name-only result added=0/removed=0/unchanged=1, got %', v_result;
    END IF;

    SELECT effective_from INTO v_ap_effective_from_after
    FROM metadata.asset_points WHERE id = v_ap_asset_point_id;

    IF (v_result->'unchanged'->0->>'asset_point_id')::uuid <> v_ap_asset_point_id THEN
        RAISE EXCEPTION 'Expected the friendly-name-only edit to keep the same asset_point_id';
    END IF;
    IF v_ap_effective_from_after <> v_ap_effective_from_before THEN
        RAISE EXCEPTION 'Friendly-name-only edit must not change effective_from (before=%, after=%)', v_ap_effective_from_before, v_ap_effective_from_after;
    END IF;
    IF (SELECT friendly_name FROM metadata.asset_points WHERE id = v_ap_asset_point_id) <> 'Main Incoming Power' THEN
        RAISE EXCEPTION 'Expected friendly_name to be updated to the new value';
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Remove + history preservation. Fixture a SEPARATE point
    --    (POWER_FACTOR_TOTAL) directly via INSERT with an explicit past
    --    effective_from (same idiom as migration 253's "historical
    --    assignment" case), then close it through the Save function by
    --    omitting it from the (still ACTIVE_POWER_TOTAL-only) payload.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device_a, v_power_factor_total_id, v_org_a, 'Legacy PF Reading', now() - INTERVAL '2 days', NULL)
    RETURNING id, effective_from INTO v_pf_asset_point_id, v_pf_effective_from_before;

    -- v_device_a_points still holds only ACTIVE_POWER_TOTAL -- omitting
    -- POWER_FACTOR_TOTAL from this full-replace payload closes it.
    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_a, v_device_a_points);

    IF jsonb_array_length(v_result->'removed') <> 1
       OR jsonb_array_length(v_result->'added') <> 0
       OR jsonb_array_length(v_result->'unchanged') <> 1 THEN
        RAISE EXCEPTION 'Expected remove result added=0/removed=1/unchanged=1 (ACTIVE_POWER_TOTAL synced, POWER_FACTOR_TOTAL closed), got %', v_result;
    END IF;

    -- History preservation: the row still exists (not deleted), closed
    -- (effective_to set, > effective_from), original effective_from
    -- untouched.
    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_points
        WHERE id = v_pf_asset_point_id
          AND effective_to IS NOT NULL
          AND effective_to > effective_from
          AND effective_from = v_pf_effective_from_before
    ) THEN
        RAISE EXCEPTION 'Expected the removed row to persist as closed history with its original effective_from intact';
    END IF;

    SELECT count(*) INTO v_count
    FROM metadata.asset_points
    WHERE asset_id = v_asset AND device_id = v_device_a AND logical_point_id = v_power_factor_total_id
      AND effective_range @> now();
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected no currently-effective row for POWER_FACTOR_TOTAL after remove, found %', v_count;
    END IF;

    -- ACTIVE_POWER_TOTAL must remain confirmed and untouched.
    SELECT effective_from INTO v_ap_effective_from_after
    FROM metadata.asset_points WHERE id = v_ap_asset_point_id;
    IF v_ap_effective_from_after <> v_ap_effective_from_before THEN
        RAISE EXCEPTION 'Expected ACTIVE_POWER_TOTAL''s effective_from to remain untouched by an unrelated remove on the same device';
    END IF;

    -- Empty payload is valid (Amendment 5: unconfirming everything for a
    -- device is a legitimate action) -- exercised structurally by every
    -- rejection-path PERFORM call above having implicitly accepted
    -- '[]'::jsonb as p_confirmed_points' default; explicitly confirmed
    -- here against device B, which has never had anything confirmed.
    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_b, '[]'::jsonb);
    IF jsonb_array_length(v_result->'added') <> 0
       OR jsonb_array_length(v_result->'removed') <> 0
       OR jsonb_array_length(v_result->'unchanged') <> 0 THEN
        RAISE EXCEPTION 'Expected an empty payload against a device with nothing confirmed to be a valid no-op, got %', v_result;
    END IF;

    -- ------------------------------------------------------------------
    -- 8. Same measurement group ("Power": Active/Reactive/Apparent),
    --    different device -> rejected; same device -> allowed.
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset, v_device_b,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_reactive_power_l1_id, 'friendly_name', 'Reactive Power'))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'EM001' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected confirming REACTIVE_POWER_L1 on device B, while ACTIVE_POWER_TOTAL is confirmed on device A (same POWER group), to be rejected with EM001 (migration 259)';
    END IF;

    -- Confirming multiple points in the SAME group from the SAME device
    -- (device A) remains allowed.
    v_device_a_points := v_device_a_points || jsonb_build_array(jsonb_build_object('logical_point_id', v_reactive_power_l1_id, 'friendly_name', 'Reactive Power L1'));

    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_a, v_device_a_points);
    IF jsonb_array_length(v_result->'added') <> 1 OR jsonb_array_length(v_result->'unchanged') <> 1 THEN
        RAISE EXCEPTION 'Expected confirming two POWER-group points from the SAME device to succeed, got %', v_result;
    END IF;

    -- ------------------------------------------------------------------
    -- 9. Different Energy groups (Import vs Export), different device ->
    --    allowed. Energy's three groups are independent.
    -- ------------------------------------------------------------------
    v_device_a_points := v_device_a_points || jsonb_build_array(jsonb_build_object('logical_point_id', v_energy_import_total_id, 'friendly_name', 'Main Import'));

    v_result := admin.save_asset_point_assignments(v_user_a, v_asset, v_device_a, v_device_a_points);
    IF jsonb_array_length(v_result->'added') <> 1 THEN
        RAISE EXCEPTION 'Expected ENERGY_IMPORT_TOTAL confirmed on device A to succeed, got %', v_result;
    END IF;

    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset, v_device_b,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_energy_export_total_id, 'friendly_name', 'Sub Export'))
    );
    IF jsonb_array_length(v_result->'added') <> 1 THEN
        RAISE EXCEPTION 'Expected ENERGY_EXPORT_TOTAL confirmed on a DIFFERENT device (device B) to succeed -- Energy Import/Export are independent groups, got %', v_result;
    END IF;

    -- ------------------------------------------------------------------
    -- 10. Same Energy group (Import), different device -> rejected,
    --     leaving device B's prior state unchanged (no partial apply).
    -- ------------------------------------------------------------------
    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset, v_device_b,
            jsonb_build_array(
                jsonb_build_object('logical_point_id', v_energy_export_total_id, 'friendly_name', 'Sub Export'),
                jsonb_build_object('logical_point_id', v_energy_import_total_id, 'friendly_name', 'Sub Import')
            )
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'EM001' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected confirming ENERGY_IMPORT_TOTAL on device B, while already confirmed on device A (same ENERGY_IMPORT group), to be rejected with EM001 (migration 259)';
    END IF;

    SELECT count(*) INTO v_count
    FROM metadata.asset_points
    WHERE asset_id = v_asset AND device_id = v_device_b AND effective_range @> now();
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected the rejected Save to leave device B''s state unchanged (1 confirmed point), found %', v_count;
    END IF;
END;
$test$;

\echo 'PASS: add creates a currently-effective row with the requested friendly_name'
\echo 'PASS: friendly-name-only edit updates in place -- same asset_point_id, same effective_from'
\echo 'PASS: remove closes the row (effective_to set) without deleting it -- history preserved; unrelated confirmed points on the same device are untouched'
\echo 'PASS: an empty payload against a device with nothing confirmed is a valid no-op'
\echo 'PASS: duplicate logical_point_id within one payload is rejected'
\echo 'PASS: a non-existent/disabled point is rejected'
\echo 'PASS: an unauthorized actor (no asset.manage) and a cross-tenant actor are rejected, zero mutation'
\echo 'PASS: a decommissioned asset is rejected'
\echo 'PASS: same POWER-group point from a different device is rejected; same device is allowed'
\echo 'PASS: different Energy groups (Import vs Export) from different devices are allowed'
\echo 'PASS: same Energy group (Import) from a different device is rejected, leaving prior state unchanged'

ROLLBACK;

SELECT 'Asset point-assignment Save assertions (migration 255) passed.' AS result;
