#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Portal-scoped Asset Power Trend read assertions (migration 246) ==='

# This exercises analytics.get_portal_asset_power_trend directly -- rows are
# inserted straight into telemetry.energy_measurements so this is a precise,
# deterministic check of the read path's own device-resolution/authorization/
# range logic, independent of any ingestion pipeline.
docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_org_a UUID;
    v_org_b UUID;
    v_site_a UUID;
    v_gateway UUID;
    v_protocol UUID;
    v_energy_meter_category UUID;
    v_device_model UUID;
    v_device UUID;
    v_asset_metered UUID;
    v_asset_unmetered UUID;
    v_user_a BIGINT;
    v_user_b BIGINT;
    v_row RECORD;
    v_count INTEGER;
BEGIN
    -- ------------------------------------------------------------------
    -- Fixture: two tenants, one metered asset (real PRIMARY_METER device,
    -- resolved the same way v_grafana_asset_electrical_samples does), one
    -- unmetered asset (no PRIMARY_METER -- the realistic "never processed"
    -- shape), one portal user per tenant.
    -- ------------------------------------------------------------------
    SELECT id INTO v_protocol FROM config.protocols WHERE name = 'MQTT' LIMIT 1;
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;

    IF v_protocol IS NULL OR v_energy_meter_category IS NULL THEN
        RAISE EXCEPTION 'Power trend fixture requires MQTT and Energy Meter category';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Asset Power Trend Test Org A', 'ASSET_POWER_TREND_TEST_ORG_A', 'UTC')
    RETURNING id INTO v_org_a;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Asset Power Trend Test Org B', 'ASSET_POWER_TREND_TEST_ORG_B', 'UTC')
    RETURNING id INTO v_org_b;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org_a, 'Asset Power Trend Test Site', 'ASSET_POWER_TREND_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site_a;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org_a, v_site_a, 'Asset Power Trend Gateway', 'ASSET-POWER-TREND-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Asset Power Trend Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, name, external_id, protocol)
    VALUES (v_org_a, v_gateway, v_device_model, 'Asset Power Trend Meter', 'ASSET-POWER-TREND-METER', 'MQTT')
    RETURNING id INTO v_device;

    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Asset Power Trend -- Metered Asset', 'active', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_metered;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset_metered, v_device, 'PRIMARY_METER');

    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org_a, v_site_a, 'Asset Power Trend -- Unmetered Asset', 'active', 'NOT_REQUIRED')
    RETURNING id INTO v_asset_unmetered;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'asset-power-trend-test-user-a', 'Asset Power Trend Test User A',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_a, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_a;

    INSERT INTO admin.portal_users(
        username, display_name, password_hash, role_code, is_active,
        access_scope_mode, organization_id, created_by
    ) VALUES (
        'asset-power-trend-test-user-b', 'Asset Power Trend Test User B',
        'not-a-real-hash', 'VIEWER', TRUE, 'ORGANIZATION', v_org_b, 'test-fixture'
    ) RETURNING portal_user_id INTO v_user_b;

    -- ------------------------------------------------------------------
    -- Two known samples for the metered asset's device.
    -- ------------------------------------------------------------------
    INSERT INTO telemetry.energy_measurements(
        bucket_start, organization_id, site_id, device_id,
        quality_code, is_estimated, active_power_total_w
    ) VALUES
        (TIMESTAMPTZ '2026-08-10 11:30:00+00', v_org_a, v_site_a, v_device, 0, FALSE, 12500),
        (TIMESTAMPTZ '2026-08-10 11:31:00+00', v_org_a, v_site_a, v_device, 0, TRUE,  12800);

    -- ------------------------------------------------------------------
    -- 1. Correct returned values for the authorized user, unit conversion
    --    (W -> kW) and is_estimated both correct.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Expected 2 power trend samples, found %', v_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 11:30:00+00', TIMESTAMPTZ '2026-08-10 11:30:30+00'
    );
    IF v_row.active_power_kw IS DISTINCT FROM 12.5 OR v_row.is_estimated IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION 'Expected first sample 12.5 kW / is_estimated=false, got %/%',
            v_row.active_power_kw, v_row.is_estimated;
    END IF;

    SELECT * INTO v_row
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 11:31:00+00', TIMESTAMPTZ '2026-08-10 11:31:30+00'
    );
    IF v_row.active_power_kw IS DISTINCT FROM 12.8 OR v_row.is_estimated IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Expected second sample 12.8 kW / is_estimated=true, got %/%',
            v_row.active_power_kw, v_row.is_estimated;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Cross-tenant denial.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_b, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Cross-tenant caller unexpectedly saw % power trend row(s)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. No-data asset -- no PRIMARY_METER device at all.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_unmetered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Unmetered asset unexpectedly returned % power trend row(s)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Range boundary -- [p_from, p_to).
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 11:31:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected 1 row when p_from excludes the first sample (got %)', v_count;
    END IF;

    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2026-08-10 00:00:00+00', TIMESTAMPTZ '2026-08-10 11:31:00+00'
    );
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected 1 row when p_to equals the second sample''s time (half-open window, got %)', v_count;
    END IF;

    -- ------------------------------------------------------------------
    -- 5. Long range (>31 days) succeeds -- proves no artificial window
    --    limit exists at the SQL layer either (there never was one; this
    --    documents that fact for the reconciled Demand-cap-removal work).
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.get_portal_asset_power_trend(
        v_user_a, v_asset_metered,
        TIMESTAMPTZ '2020-01-01 00:00:00+00', TIMESTAMPTZ '2026-08-11 00:00:00+00'
    );
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Expected 2 rows over a multi-year range (got %)', v_count;
    END IF;
END;
$test$;

\echo 'PASS: authorized caller sees correct power trend values (unit conversion, is_estimated)'
\echo 'PASS: a caller in a different organization is denied (zero rows, no error)'
\echo 'PASS: an asset with no PRIMARY_METER device returns zero rows, not an error'
\echo 'PASS: [p_from, p_to) window boundaries on bucket_start are enforced correctly'
\echo 'PASS: a multi-year range returns all matching samples -- no artificial window limit'

ROLLBACK;
SQL

printf '%s\n' 'PASS: portal-scoped asset power trend read assertions completed.'
