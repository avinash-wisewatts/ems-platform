#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Asset point-assignment candidate read assertions (migration 253) ==='

# Exercises admin.list_asset_point_assignment_candidates directly. Covers:
# candidate scope across every metadata.asset_devices relationship type
# (never PRIMARY_METER-only), current confirmation state (including that a
# PRIMARY_METER device's unconfirmed points are NOT treated as owned),
# exclusion of a historical (closed) assignment, exclusion of a disabled
# config.device_point_configuration row, cross-tenant denial (zero rows,
# never an error), and friendly_name persistence/readback.
docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_energy_meter_category UUID;
    v_active_power_total_id UUID;
    v_energy_import_total_id UUID;
    v_profile_id UUID;

    v_org_a UUID;
    v_org_b UUID;
    v_site_a UUID;
    v_gateway_a UUID;
    v_device_model UUID;
    v_device_a UUID;
    v_device_b UUID;
    v_asset UUID;
    v_user_a BIGINT;
    v_user_b BIGINT;

    v_count INTEGER;
    v_row RECORD;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_active_power_total_id
    FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_energy_import_total_id
    FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL';
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_energy_meter_category IS NULL OR v_active_power_total_id IS NULL
       OR v_energy_import_total_id IS NULL OR v_profile_id IS NULL THEN
        RAISE EXCEPTION 'Candidate-read fixture requires an Energy Meter category, ACTIVE_POWER_TOTAL/ENERGY_IMPORT_TOTAL logical points, and the ENERGY_METER_ENISCOPE_V1 profile';
    END IF;

    -- ------------------------------------------------------------------
    -- Fixture: two tenants (org B exists only to prove cross-tenant
    -- denial), one asset in org A related to two devices via two
    -- DIFFERENT relationship types -- device A as PRIMARY_METER, device B
    -- as SECONDARY_METER -- to prove candidates are not PRIMARY_METER-only.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Point Assignment Candidates Test Org A', 'POINT_ASSIGN_CANDIDATES_TEST_ORG_A', 'UTC')
    RETURNING id INTO v_org_a;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Point Assignment Candidates Test Org B', 'POINT_ASSIGN_CANDIDATES_TEST_ORG_B', 'UTC')
    RETURNING id INTO v_org_b;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org_a, 'Point Assignment Candidates Test Site', 'POINT_ASSIGN_CANDIDATES_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site_a;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org_a, v_site_a, 'Point Assignment Candidates Test Gateway', 'POINT-ASSIGN-CANDIDATES-TEST-GW')
    RETURNING id INTO v_gateway_a;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Point Assignment Candidates Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Point Assignment Candidates Meter A', 'POINT-ASSIGN-CANDIDATES-METER-A', 'MQTT')
    RETURNING id INTO v_device_a;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway_a, v_device_model, v_profile_id, 'Point Assignment Candidates Meter B', 'POINT-ASSIGN-CANDIDATES-METER-B', 'MQTT')
    RETURNING id INTO v_device_b;

    -- config.device_point_configuration is auto-populated for both devices
    -- by trg_sync_device_points_after_profile_change the moment profile_id
    -- was set above -- no explicit insert needed.

    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Point Assignment Candidates Test Asset', 'active', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device_a, 'PRIMARY_METER');
    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device_b, 'SECONDARY_METER');

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'point-assign-candidates-test-user-a', 'Point Assignment Candidates Test User A',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'point-assign-candidates-test-user-b', 'Point Assignment Candidates Test User B',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_b, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_b;

    -- ------------------------------------------------------------------
    -- 1. Candidate scope: both devices' enabled points appear, across
    --    both relationship types -- never PRIMARY_METER-only.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_a;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected candidate points from device A (PRIMARY_METER), got none';
    END IF;

    SELECT count(*) INTO v_count
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_b;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected candidate points from device B (SECONDARY_METER), got none -- candidates must not be PRIMARY_METER-only';
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Current confirmation + friendly_name persistence/readback: confirm
    --    exactly one point on device A with a friendly_name. A DIFFERENT
    --    point on the same PRIMARY_METER device must still show
    --    unconfirmed -- PRIMARY_METER does not imply all its points are
    --    owned by the asset.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device_a, v_energy_import_total_id, v_org_a, 'Main Incoming Energy', TIMESTAMPTZ '2026-08-01 00:00:00+00', NULL);

    SELECT is_confirmed, asset_point_id IS NOT NULL AS has_id, friendly_name
    INTO v_row
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_a AND logical_point_id = v_energy_import_total_id;
    IF NOT v_row.is_confirmed OR NOT v_row.has_id OR v_row.friendly_name IS DISTINCT FROM 'Main Incoming Energy' THEN
        RAISE EXCEPTION 'Expected the confirmed point to read back is_confirmed=true/asset_point_id set/friendly_name=Main Incoming Energy, got is_confirmed=%/has_id=%/friendly_name=%',
            v_row.is_confirmed, v_row.has_id, v_row.friendly_name;
    END IF;

    SELECT is_confirmed, friendly_name INTO v_row
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_a AND logical_point_id = v_active_power_total_id;
    IF v_row.is_confirmed OR v_row.friendly_name IS NOT NULL THEN
        RAISE EXCEPTION 'Expected an unconfirmed point on the same PRIMARY_METER device to show is_confirmed=false/friendly_name=NULL, got is_confirmed=%/friendly_name=%',
            v_row.is_confirmed, v_row.friendly_name;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Historical (closed) assignment exclusion: a previously-removed
    --    assignment on device B must not count as currently confirmed.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, friendly_name, effective_from, effective_to)
    VALUES (v_asset, v_device_b, v_energy_import_total_id, v_org_a, 'Old Sub-Meter Reading', TIMESTAMPTZ '2026-01-01 00:00:00+00', TIMESTAMPTZ '2026-06-01 00:00:00+00');

    SELECT is_confirmed, asset_point_id, friendly_name INTO v_row
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_b AND logical_point_id = v_energy_import_total_id;
    IF v_row.is_confirmed OR v_row.asset_point_id IS NOT NULL OR v_row.friendly_name IS NOT NULL THEN
        RAISE EXCEPTION 'Expected a historical (closed) assignment to show unconfirmed, got is_confirmed=%/asset_point_id=%/friendly_name=%',
            v_row.is_confirmed, v_row.asset_point_id, v_row.friendly_name;
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Disabled config.device_point_configuration row is excluded
    --    entirely, not merely shown as unconfirmed.
    -- ------------------------------------------------------------------
    UPDATE config.device_point_configuration
    SET is_enabled = FALSE
    WHERE device_id = v_device_b AND logical_point_id = v_active_power_total_id;

    SELECT count(*) INTO v_count
    FROM admin.list_asset_point_assignment_candidates(v_user_a, v_asset)
    WHERE device_id = v_device_b AND logical_point_id = v_active_power_total_id;
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected a disabled device_point_configuration row to be excluded entirely, got % row(s)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 5. Tenant isolation: a portal user from a different organization
    --    gets zero rows, never an error, never a partial view.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM admin.list_asset_point_assignment_candidates(v_user_b, v_asset);
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Cross-tenant caller unexpectedly saw % candidate row(s)', v_count;
    END IF;
END;
$test$;

\echo 'PASS: candidate points come from every asset_devices relationship type, not PRIMARY_METER-only'
\echo 'PASS: a confirmed point reads back is_confirmed=true with its friendly_name; an unconfirmed point on the same PRIMARY_METER device stays unconfirmed'
\echo 'PASS: a historical (closed) assignment is excluded from current confirmation state'
\echo 'PASS: a disabled device_point_configuration row is excluded from candidates entirely'
\echo 'PASS: a cross-tenant caller sees zero rows, never an error'

ROLLBACK;
SQL

printf '%s\n' 'PASS: asset point-assignment candidate read assertions completed.'
