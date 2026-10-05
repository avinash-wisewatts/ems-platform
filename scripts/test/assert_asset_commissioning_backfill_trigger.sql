-- ============================================================================
-- File:
--   scripts/test/assert_asset_commissioning_backfill_trigger.sql
--
-- Purpose:
--   Regression test for migration 256 (first-assignment commissioning
--   trigger + durable backfill state, admin.save_asset_point_assignments
--   extended).
--
-- Note on timestamps: the whole test runs inside one outer transaction,
-- and PostgreSQL's now()/transaction_timestamp() is fixed for the entire
-- transaction. A row ADDED via the Save function earlier in this same
-- test transaction therefore cannot later be REMOVED via the Save
-- function within the same transaction (effective_to would equal
-- effective_from exactly, violating ck_asset_points_effective_window --
-- the same constraint migration 255's test already had to design around).
-- Every scenario below is therefore an independent asset with the
-- MINIMUM fixture needed for that one concern: scenarios that need a
-- "removed" or "historical" row fixture it directly via INSERT with an
-- explicit past effective_from/effective_to, exactly like migration
-- 253/255's own tests, rather than removing a row the Save function
-- itself added earlier in this transaction.
--
--   Covers, as separate concerns, using six independent assets:
--     Asset A: first assignment -> lifecycle_status COMMISSIONING,
--       exactly one PENDING backfill record; a second assignment (same
--       device, then a different device) creates no new record and
--       leaves lifecycle_status unchanged.
--     Asset B: removal leaving zero currently-effective points (fixtured
--       directly, simulating a point confirmed in a prior session) does
--       not retrigger -- the backfill record count and lifecycle_status
--       from that prior commissioning are unchanged.
--     Asset C: re-assignment after all points were previously closed,
--       on an asset that has since reached ACTIVE (simulated) -> does
--       NOT retrigger and does NOT revert lifecycle_status. This is the
--       resolved ambiguity -- see migration 256's header: "first
--       successful assignment" is keyed to whether a backfill record has
--       EVER been created for the asset, not to a live currently-
--       effective-row count.
--     Asset D: a failed Save (disabled point) causes no lifecycle or
--       backfill-state mutation.
--     Asset E: a friendly-name-only edit (no points actually added by
--       this Save) never triggers commissioning, tested against a point
--       that was already currently-effective before any Save call on
--       this asset.
--     Asset F: simulated concurrent race -- a backfill record already
--       exists (as if another concurrent Save just won) at the moment a
--       first-ever add is attempted -> no duplicate record, no error,
--       commissioning_triggered=false.
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
    v_energy_export_total_id UUID;

    v_org_a UUID;
    v_site_a UUID;
    v_gateway_a UUID;
    v_device_model UUID;

    v_device_a1 UUID; v_device_a2 UUID;  -- Asset A: same-device / different-device
    v_device_b  UUID;                    -- Asset B
    v_device_c  UUID;                    -- Asset C
    v_device_d  UUID;                    -- Asset D
    v_device_e  UUID;                    -- Asset E
    v_device_f  UUID;                    -- Asset F

    v_asset_a UUID;
    v_asset_b UUID;
    v_asset_c UUID;
    v_asset_d UUID;
    v_asset_e UUID;
    v_asset_f UUID;

    v_user_a BIGINT;

    v_result JSONB;
    v_count INTEGER;
    v_lifecycle TEXT;
    v_backfill_id UUID;
    v_raised BOOLEAN;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';
    SELECT id INTO v_active_power_total_id  FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_reactive_power_l1_id   FROM metadata.logical_points WHERE name = 'REACTIVE_POWER_L1';
    SELECT id INTO v_apparent_power_l1_id   FROM metadata.logical_points WHERE name = 'APPARENT_POWER_L1';
    SELECT id INTO v_energy_export_total_id FROM metadata.logical_points WHERE name = 'ENERGY_EXPORT_TOTAL';

    IF v_energy_meter_category IS NULL OR v_profile_id IS NULL
       OR v_active_power_total_id IS NULL OR v_reactive_power_l1_id IS NULL
       OR v_apparent_power_l1_id IS NULL OR v_energy_export_total_id IS NULL THEN
        RAISE EXCEPTION 'Fixture requires an Energy Meter category, ENERGY_METER_ENISCOPE_V1 profile, and ACTIVE_POWER_TOTAL/REACTIVE_POWER_L1/APPARENT_POWER_L1/ENERGY_EXPORT_TOTAL logical points';
    END IF;

    -- ------------------------------------------------------------------
    -- Fixture: one org/site/gateway, one device per asset (kept simple
    -- and independent -- Asset A gets two, for its same-device/
    -- different-device sub-cases), six assets (all start DRAFT), one
    -- portal user with asset.manage.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Commissioning Trigger Test Org', 'COMMISSIONING_TRIGGER_TEST_ORG', 'UTC') RETURNING id INTO v_org_a;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org_a, 'Commissioning Trigger Test Site', 'COMMISSIONING_TRIGGER_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site_a;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Gateway', 'COMMISSIONING-TRIGGER-TEST-GW')
    RETURNING id INTO v_gateway_a;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Commissioning Trigger Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter A1', 'COMMISSIONING-TRIGGER-METER-A1', 'MQTT')
    RETURNING id INTO v_device_a1;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter A2', 'COMMISSIONING-TRIGGER-METER-A2', 'MQTT')
    RETURNING id INTO v_device_a2;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter B', 'COMMISSIONING-TRIGGER-METER-B', 'MQTT')
    RETURNING id INTO v_device_b;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter C', 'COMMISSIONING-TRIGGER-METER-C', 'MQTT')
    RETURNING id INTO v_device_c;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter D', 'COMMISSIONING-TRIGGER-METER-D', 'MQTT')
    RETURNING id INTO v_device_d;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter E', 'COMMISSIONING-TRIGGER-METER-E', 'MQTT')
    RETURNING id INTO v_device_e;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Commissioning Trigger Meter F', 'COMMISSIONING-TRIGGER-METER-F', 'MQTT')
    RETURNING id INTO v_device_f;

    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset A (first+second assignment)', 'draft', 'DRAFT', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_a;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset B (removal to zero)', 'draft', 'COMMISSIONING', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_b;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset C (re-assignment after full removal)', 'active', 'ACTIVE', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_c;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset D (failed Save)', 'draft', 'DRAFT', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_d;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset E (friendly-name-only)', 'draft', 'DRAFT', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_e;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, lifecycle_status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Commissioning Trigger Test Asset F (simulated race)', 'draft', 'DRAFT', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_f;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_a, v_device_a1, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_a, v_device_a2, 'SECONDARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_b, v_device_b, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_c, v_device_c, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_d, v_device_d, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_e, v_device_e, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (v_asset_f, v_device_f, 'PRIMARY_METER');

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'commissioning-trigger-test-user-a', 'Commissioning Trigger Test User A',
        'not-a-real-hash', 'OPERATOR', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    -- ==================================================================
    -- ASSET A: first assignment, then second assignment (same device,
    -- then a different device). No removals -- avoids the same-
    -- transaction add-then-remove timestamp problem entirely.
    -- ==================================================================
    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_a, v_device_a1,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Main Active Power'))
    );

    IF (v_result->>'commissioning_triggered')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=true on the first successful assignment, got %', v_result;
    END IF;
    IF v_result->>'backfill_record_id' IS NULL THEN
        RAISE EXCEPTION 'Expected a backfill_record_id on the first successful assignment, got %', v_result;
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_a;
    IF v_lifecycle <> 'COMMISSIONING' THEN
        RAISE EXCEPTION 'Expected asset lifecycle_status COMMISSIONING after first assignment, got %', v_lifecycle;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_a;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly 1 backfill record for asset A, found %', v_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_commissioning_backfill
        WHERE asset_id = v_asset_a
          AND status = 'PENDING'
          AND started_at IS NULL AND completed_at IS NULL AND failed_at IS NULL
          AND triggered_by_portal_user_id = v_user_a
    ) THEN
        RAISE EXCEPTION 'Expected the backfill record to be PENDING with no started/completed/failed timestamps and the correct triggering actor';
    END IF;

    -- Second assignment -- same device (adds a distinct point).
    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_a, v_device_a1,
        jsonb_build_array(
            jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Main Active Power'),
            jsonb_build_object('logical_point_id', v_reactive_power_l1_id, 'friendly_name', 'Reactive Power L1')
        )
    );
    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false on a second assignment (same device), got %', v_result;
    END IF;

    -- Second assignment -- a DIFFERENT device on the same asset (proves
    -- the gate is asset-scoped, not device-scoped).
    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_a, v_device_a2,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_energy_export_total_id, 'friendly_name', 'Sub Export'))
    );
    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false on a second assignment (different device, asset-scoped gate), got %', v_result;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_a;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected still exactly 1 backfill record for asset A after second assignments, found %', v_count;
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_a;
    IF v_lifecycle <> 'COMMISSIONING' THEN
        RAISE EXCEPTION 'Expected lifecycle_status to remain COMMISSIONING (unchanged) after second assignments, got %', v_lifecycle;
    END IF;

    -- ==================================================================
    -- ASSET B: removal leaving zero currently-effective points across
    -- the whole asset must not retrigger. Fixtured directly (past
    -- effective_from, simulating a point confirmed in an earlier
    -- session) together with the backfill record that original
    -- commissioning would already have created, so this scenario tests
    -- purely the REMOVE call's behavior without any same-transaction
    -- add-via-Save.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_b, v_device_b, v_active_power_total_id, v_org_a, 'Prior Session Reading', now() - INTERVAL '3 days', NULL);

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, requested_at)
    VALUES (v_asset_b, 'PENDING', v_user_a, now() - INTERVAL '3 days')
    RETURNING id INTO v_backfill_id;

    v_result := admin.save_asset_point_assignments(v_user_a, v_asset_b, v_device_b, '[]'::jsonb);

    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false when removing the asset''s last confirmed point, got %', v_result;
    END IF;
    IF jsonb_array_length(v_result->'removed') <> 1 THEN
        RAISE EXCEPTION 'Expected the removal itself to succeed, got %', v_result;
    END IF;

    SELECT count(*) INTO v_count
    FROM metadata.asset_points
    WHERE asset_id = v_asset_b AND effective_range @> now();
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero currently-effective points on asset B after removal, found %', v_count;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_b;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected still exactly 1 backfill record for asset B after removal-to-zero (no new one), found %', v_count;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.asset_commissioning_backfill WHERE id = v_backfill_id) THEN
        RAISE EXCEPTION 'Expected the ORIGINAL pre-existing backfill record to remain unchanged';
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_b;
    IF v_lifecycle <> 'COMMISSIONING' THEN
        RAISE EXCEPTION 'Expected asset B lifecycle_status to remain COMMISSIONING (unchanged) after removal-to-zero, got %', v_lifecycle;
    END IF;

    -- ==================================================================
    -- ASSET C: re-assignment after all points were previously closed --
    -- the resolved ambiguity. Fixtured with a HISTORICAL (already
    -- closed) point and a backfill record from the "original"
    -- commissioning, on an asset that has since reached ACTIVE. A new
    -- point assignment must succeed as an ordinary add WITHOUT
    -- retriggering commissioning or reverting lifecycle_status.
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_c, v_device_c, v_reactive_power_l1_id, v_org_a, 'Old Reading', now() - INTERVAL '30 days', now() - INTERVAL '10 days');

    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id, requested_at, started_at, completed_at)
    VALUES (v_asset_c, 'COMPLETED', v_user_a, now() - INTERVAL '30 days', now() - INTERVAL '29 days', now() - INTERVAL '28 days')
    RETURNING id INTO v_backfill_id;

    -- Sanity: asset C genuinely has zero currently-effective points right
    -- now (its only point is historical/closed) despite already being
    -- ACTIVE with a COMPLETED backfill record -- exactly the scenario
    -- decision 6 / Amendment 6 describe.
    SELECT count(*) INTO v_count FROM metadata.asset_points WHERE asset_id = v_asset_c AND effective_range @> now();
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Fixture error: expected asset C to have zero currently-effective points before re-assignment';
    END IF;

    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_c, v_device_c,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Re-assigned Active Power'))
    );

    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false on re-assignment after a full prior removal (already-commissioned asset), got %', v_result;
    END IF;
    IF jsonb_array_length(v_result->'added') <> 1 THEN
        RAISE EXCEPTION 'Expected the re-assignment itself to succeed as an ordinary add, got %', v_result;
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_c;
    IF v_lifecycle <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Expected lifecycle_status to remain ACTIVE (must NOT be reverted to COMMISSIONING) after re-assignment, got %', v_lifecycle;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_c;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected still exactly 1 backfill record for asset C after re-assignment (no second record), found %', v_count;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM metadata.asset_commissioning_backfill WHERE id = v_backfill_id AND status = 'COMPLETED') THEN
        RAISE EXCEPTION 'Expected the ORIGINAL COMPLETED backfill record to remain unchanged (not reset to PENDING)';
    END IF;

    -- ==================================================================
    -- ASSET D: a failed Save must cause no lifecycle/backfill mutation.
    -- ==================================================================
    UPDATE config.device_point_configuration
    SET is_enabled = FALSE
    WHERE device_id = v_device_d AND logical_point_id = v_apparent_power_l1_id;

    v_raised := FALSE;
    BEGIN
        PERFORM admin.save_asset_point_assignments(
            v_user_a, v_asset_d, v_device_d,
            jsonb_build_array(jsonb_build_object('logical_point_id', v_apparent_power_l1_id, 'friendly_name', 'x'))
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = '23514' THEN v_raised := TRUE; ELSE RAISE; END IF;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'Expected the disabled-point Save on asset D to fail with 23514';
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_d;
    IF v_lifecycle <> 'DRAFT' THEN
        RAISE EXCEPTION 'Expected asset D lifecycle_status to remain DRAFT (untouched) after a failed Save, got %', v_lifecycle;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_d;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero backfill records for asset D after a failed Save, found %', v_count;
    END IF;

    -- ==================================================================
    -- ASSET E: a friendly-name-only edit never triggers commissioning,
    -- even for a point that was already currently-effective before any
    -- Save call on this asset (directly fixtured, bypassing Save).
    -- ==================================================================
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset_e, v_device_e, v_active_power_total_id, v_org_a, 'Pre-existing Reading', now() - INTERVAL '1 day', NULL);

    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_e, v_device_e,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Renamed Only'))
    );

    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false for a friendly-name-only edit, got %', v_result;
    END IF;
    IF jsonb_array_length(v_result->'added') <> 0 OR jsonb_array_length(v_result->'unchanged') <> 1 THEN
        RAISE EXCEPTION 'Expected a pure friendly-name-only result (added=0/unchanged=1), got %', v_result;
    END IF;

    SELECT lifecycle_status INTO v_lifecycle FROM metadata.assets WHERE id = v_asset_e;
    IF v_lifecycle <> 'DRAFT' THEN
        RAISE EXCEPTION 'Expected asset E lifecycle_status to remain DRAFT after a friendly-name-only edit, got %', v_lifecycle;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_e;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected zero backfill records for asset E -- a friendly-name-only edit must never create one, found %', v_count;
    END IF;

    -- ==================================================================
    -- ASSET F: simulated concurrent race -- a backfill record already
    -- exists (as if another concurrent Save just won) at the moment a
    -- first-ever add is attempted.
    -- ==================================================================
    INSERT INTO metadata.asset_commissioning_backfill(asset_id, status, triggered_by_portal_user_id)
    VALUES (v_asset_f, 'PENDING', v_user_a)
    RETURNING id INTO v_backfill_id;

    v_result := admin.save_asset_point_assignments(
        v_user_a, v_asset_f, v_device_f,
        jsonb_build_array(jsonb_build_object('logical_point_id', v_active_power_total_id, 'friendly_name', 'Raced Point'))
    );

    IF (v_result->>'commissioning_triggered')::boolean IS NOT FALSE THEN
        RAISE EXCEPTION 'Expected commissioning_triggered=false when a backfill record already exists (simulated race), got %', v_result;
    END IF;
    IF jsonb_array_length(v_result->'added') <> 1 THEN
        RAISE EXCEPTION 'Expected the point assignment itself to still succeed despite losing the commissioning race, got %', v_result;
    END IF;

    SELECT count(*) INTO v_count FROM metadata.asset_commissioning_backfill WHERE asset_id = v_asset_f;
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected still exactly 1 backfill record for asset F (no duplicate created), found %', v_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_commissioning_backfill
        WHERE id = v_backfill_id AND asset_id = v_asset_f
    ) THEN
        RAISE EXCEPTION 'Expected the ORIGINAL pre-existing backfill record to remain, not be replaced';
    END IF;
END;
$test$;

\echo 'PASS: first assignment moves lifecycle_status to COMMISSIONING and creates exactly one PENDING backfill record'
\echo 'PASS: a second assignment (same device, then a different device) creates no new record and leaves lifecycle_status unchanged'
\echo 'PASS: removal leaving zero currently-effective points across the whole asset does not retrigger commissioning'
\echo 'PASS: re-assignment after a full prior removal (already-commissioned/ACTIVE asset) does not retrigger commissioning and does not revert lifecycle_status'
\echo 'PASS: a failed Save causes no lifecycle or backfill-state mutation'
\echo 'PASS: a friendly-name-only edit never triggers commissioning, even for a pre-existing currently-effective point'
\echo 'PASS: a simulated concurrent race (backfill record already exists) creates no duplicate record and does not error'

ROLLBACK;

SELECT 'Asset commissioning backfill trigger assertions (migration 256) passed.' AS result;
