#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Demand confirmed-point priority assertions (migration 251) ==='

# Verifies analytics.resolve_demand_source_for_interval applies the 3-tier
# priority among an asset's CONFIRMED asset_points only, never a device's
# unconfirmed theoretical capability (the gap fixed by migration 251).
docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_energy_meter_category UUID;
    v_device_model UUID;
    v_profile_id UUID;
    v_device_power_only UUID;
    v_device_both UUID;
    v_energy_import_total_id UUID;
    v_active_power_total_id UUID;
    v_asset_lower_only UUID;
    v_asset_both_confirmed UUID;
    v_row RECORD;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    SELECT id INTO v_energy_import_total_id
    FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL';
    SELECT id INTO v_active_power_total_id
    FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL';
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_energy_meter_category IS NULL OR v_energy_import_total_id IS NULL
       OR v_active_power_total_id IS NULL OR v_profile_id IS NULL THEN
        RAISE EXCEPTION 'Confirmed-priority fixture requires Energy Meter category, ENERGY_IMPORT_TOTAL, ACTIVE_POWER_TOTAL, and ENERGY_METER_ENISCOPE_V1';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Demand Priority Test Org', 'DEMAND_PRIORITY_TEST_ORG', 'UTC')
    RETURNING id INTO v_org;
    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Demand Priority Test Site', 'DEMAND_PRIORITY_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site;
    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Demand Priority Test Gateway', 'DEMAND-PRIORITY-TEST-GW')
    RETURNING id INTO v_gateway;
    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Demand Priority Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    -- Device "power_only": on ENERGY_METER_ENISCOPE_V1, which supports
    -- BOTH ENERGY_COUNTER_DELTA (higher priority) and TIME_WEIGHTED_POWER
    -- (lower priority) at the profile-capability level -- but this asset
    -- will confirm ONLY the ACTIVE_POWER_TOTAL point on it.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Demand Priority Meter Power-Only', 'DEMAND-PRIORITY-METER-POWER-ONLY', 'MQTT')
    RETURNING id INTO v_device_power_only;

    -- Device "both": same profile capability, but this asset confirms
    -- BOTH points on it.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Demand Priority Meter Both', 'DEMAND-PRIORITY-METER-BOTH', 'MQTT')
    RETURNING id INTO v_device_both;

    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org, v_site, 'Demand Priority -- Lower Confirmed Only', 'active', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_lower_only;
    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org, v_site, 'Demand Priority -- Both Confirmed', 'active', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset_both_confirmed;

    -- ------------------------------------------------------------------
    -- 1. Lower-priority confirmed point on a device capable of a
    --    higher-priority UNCONFIRMED method: only ACTIVE_POWER_TOTAL
    --    (TIME_WEIGHTED_POWER) is confirmed on this device -- even though
    --    its profile also supports ENERGY_COUNTER_DELTA via an
    --    unconfirmed ENERGY_IMPORT_TOTAL point, the device must NOT be
    --    rejected: TIME_WEIGHTED_POWER must be selected.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (
        v_asset_lower_only, v_device_power_only, v_active_power_total_id, v_org,
        TIMESTAMPTZ '2026-08-10 10:00:00+00', NULL
    );

    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset_lower_only,
        TIMESTAMPTZ '2026-08-10 10:00:00+00', TIMESTAMPTZ '2026-08-10 10:15:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.device_id IS DISTINCT FROM v_device_power_only OR v_row.selected_method IS DISTINCT FROM 'TIME_WEIGHTED_POWER' THEN
        RAISE EXCEPTION 'Expected the confirmed lower-priority point (TIME_WEIGHTED_POWER) to be used despite an unconfirmed higher-priority method being device-capable, got device=%/method=%',
            v_row.device_id, v_row.selected_method;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Higher-priority confirmed point wins when multiple confirmed
    --    methods exist: BOTH ENERGY_IMPORT_TOTAL (ENERGY_COUNTER_DELTA)
    --    and ACTIVE_POWER_TOTAL (TIME_WEIGHTED_POWER) are confirmed on
    --    this device -- ENERGY_COUNTER_DELTA (higher priority) must win.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES
        (v_asset_both_confirmed, v_device_both, v_energy_import_total_id, v_org,
         TIMESTAMPTZ '2026-08-10 10:00:00+00', NULL),
        (v_asset_both_confirmed, v_device_both, v_active_power_total_id, v_org,
         TIMESTAMPTZ '2026-08-10 10:00:00+00', NULL);

    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset_both_confirmed,
        TIMESTAMPTZ '2026-08-10 10:00:00+00', TIMESTAMPTZ '2026-08-10 10:15:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.selected_method IS DISTINCT FROM 'ENERGY_COUNTER_DELTA'
       OR v_row.logical_point_id IS DISTINCT FROM v_energy_import_total_id THEN
        RAISE EXCEPTION 'Expected ENERGY_COUNTER_DELTA (higher priority) to win when both confirmed methods are available, got method=%/point=%',
            v_row.selected_method, v_row.logical_point_id;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Existing single-source behaviour unchanged: the same fixture as
    --    case 1, re-checked with only the lower-priority point confirmed
    --    and no competing device -- must still resolve deterministically
    --    to exactly that one device/method (regression against migration
    --    250's own single-source case).
    -- ------------------------------------------------------------------
    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset_lower_only,
        TIMESTAMPTZ '2026-08-10 10:05:00+00', TIMESTAMPTZ '2026-08-10 10:20:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.device_id IS DISTINCT FROM v_device_power_only OR v_row.selected_method IS DISTINCT FROM 'TIME_WEIGHTED_POWER' THEN
        RAISE EXCEPTION 'Regression failure: single confirmed source no longer resolves deterministically, got device=%/method=%',
            v_row.device_id, v_row.selected_method;
    END IF;
END;
$test$;

\echo 'PASS: a lower-priority confirmed point is used when the device is only capable of a higher-priority method via an unconfirmed point'
\echo 'PASS: the higher-priority confirmed point wins when multiple confirmed methods are available on the same device'
\echo 'PASS: single confirmed-source resolution remains deterministic (regression)'

ROLLBACK;
SQL

printf '%s\n' 'PASS: demand confirmed-point priority assertions completed.'
