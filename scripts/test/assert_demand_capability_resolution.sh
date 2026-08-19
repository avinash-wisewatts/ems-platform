#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

COMPOSE_FILE="${PROJECT_ROOT}/compose.test.yaml"
SERVICE_NAME="timescaledb-test"

printf '%s\n' '=== Demand capability resolution assertions ==='

docker compose -f "${COMPOSE_FILE}" exec -T "${SERVICE_NAME}" \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_protocol UUID;
    v_lp_import UUID;
    v_lp_active_power UUID;
    v_profile_counter UUID;
    v_profile_power UUID;
    v_profile_native UUID;
    v_profile_native_mismatch UUID;
    v_device_counter UUID;
    v_device_power UUID;
    v_device_native UUID;
    v_device_native_mismatch UUID;
    v_method TEXT;
    v_status TEXT;
BEGIN
    SELECT id INTO v_protocol
    FROM config.protocols
    WHERE name = 'MQTT'
    LIMIT 1;

    IF v_protocol IS NULL THEN
        RAISE EXCEPTION 'Demand capability test requires canonical MQTT protocol';
    END IF;

    SELECT id INTO v_lp_import
    FROM metadata.logical_points
    WHERE name = 'ENERGY_IMPORT_TOTAL'
    LIMIT 1;

    SELECT id INTO v_lp_active_power
    FROM metadata.logical_points
    WHERE name = 'ENERGY_ACTIVE_POWER_TOTAL'
    LIMIT 1;

    IF v_lp_import IS NULL OR v_lp_active_power IS NULL THEN
        RAISE EXCEPTION 'Demand capability test requires canonical energy logical points';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Demand Capability Test Org', 'DEMAND_CAP_TEST', 'Asia/Kolkata')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(
        organization_id,
        name,
        code,
        timezone,
        lifecycle_status
    ) VALUES (
        v_org,
        'Demand Capability Test Site',
        'DEMAND_CAP_SITE',
        'Asia/Kolkata',
        'ACTIVE'
    )
    RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(
        organization_id,
        site_id,
        name,
        external_id,
        lifecycle_status
    ) VALUES (
        v_org,
        v_site,
        'Demand Capability Test Gateway',
        'DEMAND_CAP_GATEWAY',
        'COMMISSIONING'
    )
    RETURNING id INTO v_gateway;

    -- Profile 1: cumulative active energy + instantaneous active power.
    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model,
        firmware_version, profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_DEMAND_COUNTER', 'WiseWatts Test', 'Counter+Power',
        '1', 'Demand Counter Test', 'Rollback-only capability fixture', TRUE
    ) RETURNING id INTO v_profile_counter;

    INSERT INTO config.profile_field_mapping(
        profile_id, raw_field_name, logical_point_id, is_required, display_order
    ) VALUES
        (v_profile_counter, 'E', v_lp_import, FALSE, 10),
        (v_profile_counter, 'P', v_lp_active_power, FALSE, 20);

    INSERT INTO config.energy_register_semantics(
        profile_id, logical_point_id, source_unit_symbol,
        normalized_unit_symbol, scale_to_normalized_unit,
        counter_direction, rollover_behavior, rollover_value,
        reset_behavior, flow_interpretation,
        expected_max_interval_delta, is_active
    ) VALUES (
        v_profile_counter, v_lp_import, 'Wh', 'Wh', 1,
        'INCREASING', 'NONE', NULL,
        'REJECT_DELTA', 'GRID_IMPORT', 1000000000, TRUE
    );

    INSERT INTO metadata.devices(
        organization_id, gateway_id, name, external_id, profile_id
    ) VALUES (
        v_org, v_gateway, 'Counter Demand Device', 'DEMAND_COUNTER_DEVICE', v_profile_counter
    ) RETURNING id INTO v_device_counter;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_counter, 'ACTIVE_POWER_KW', 900
    );

    IF v_method IS DISTINCT FROM 'ENERGY_COUNTER_DELTA'
       OR v_status IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION
            'Expected counter device -> ENERGY_COUNTER_DELTA/READY, got %/%',
            v_method, v_status;
    END IF;

    -- Profile 2: instantaneous active power only.
    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model,
        firmware_version, profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_DEMAND_POWER_ONLY', 'WiseWatts Test', 'PowerOnly',
        '1', 'Demand Power Test', 'Rollback-only capability fixture', TRUE
    ) RETURNING id INTO v_profile_power;

    INSERT INTO config.profile_field_mapping(
        profile_id, raw_field_name, logical_point_id, is_required, display_order
    ) VALUES
        (v_profile_power, 'P', v_lp_active_power, FALSE, 10);

    INSERT INTO metadata.devices(
        organization_id, gateway_id, name, external_id, profile_id
    ) VALUES (
        v_org, v_gateway, 'Power Demand Device', 'DEMAND_POWER_DEVICE', v_profile_power
    ) RETURNING id INTO v_device_power;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_power, 'ACTIVE_POWER_KW', 900
    );

    IF v_method IS DISTINCT FROM 'TIME_WEIGHTED_POWER'
       OR v_status IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION
            'Expected power-only device -> TIME_WEIGHTED_POWER/READY, got %/%',
            v_method, v_status;
    END IF;

    -- Same profile cannot fabricate apparent-power demand.
    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_power, 'APPARENT_POWER_KVA', 900
    );

    IF v_method IS NOT NULL
       OR v_status IS DISTINCT FROM 'BASIS_NOT_SUPPORTED' THEN
        RAISE EXCEPTION
            'Expected active-only profile -> BASIS_NOT_SUPPORTED for kVA, got %/%',
            v_method, v_status;
    END IF;

    -- A profile-capable point disabled on this physical device is distinct
    -- from a profile that never supported the basis.
    UPDATE config.device_point_configuration
    SET is_enabled = FALSE
    WHERE device_id = v_device_power
      AND logical_point_id = v_lp_active_power;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_power, 'ACTIVE_POWER_KW', 900
    );

    IF v_method IS NOT NULL
       OR v_status IS DISTINCT FROM 'SOURCE_POINT_NOT_ENABLED' THEN
        RAISE EXCEPTION
            'Expected disabled active-power point -> SOURCE_POINT_NOT_ENABLED, got %/%',
            v_method, v_status;
    END IF;

    -- Profile 3: explicitly certified native 15-minute demand register.
    -- We reuse a canonical numeric point for the rollback-only resolver fixture;
    -- production native semantics must use a vendor-documented demand point.
    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model,
        firmware_version, profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_DEMAND_NATIVE', 'WiseWatts Test', 'NativeDemand',
        '1', 'Native Demand Test', 'Rollback-only capability fixture', TRUE
    ) RETURNING id INTO v_profile_native;

    INSERT INTO config.profile_field_mapping(
        profile_id, raw_field_name, logical_point_id, is_required, display_order
    ) VALUES
        (v_profile_native, 'D15', v_lp_active_power, FALSE, 10);

    INSERT INTO config.demand_register_semantics(
        profile_id, logical_point_id, demand_basis,
        native_interval_seconds, alignment_mode,
        source_unit_symbol, normalized_unit_symbol,
        scale_to_normalized_unit, is_active
    ) VALUES (
        v_profile_native, v_lp_active_power, 'ACTIVE_POWER_KW',
        900, 'WALL_CLOCK', 'kW', 'kW', 1, TRUE
    );

    INSERT INTO metadata.devices(
        organization_id, gateway_id, name, external_id, profile_id
    ) VALUES (
        v_org, v_gateway, 'Native Demand Device', 'DEMAND_NATIVE_DEVICE', v_profile_native
    ) RETURNING id INTO v_device_native;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_native, 'ACTIVE_POWER_KW', 900
    );

    IF v_method IS DISTINCT FROM 'METER_NATIVE'
       OR v_status IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION
            'Expected certified native meter -> METER_NATIVE/READY, got %/%',
            v_method, v_status;
    END IF;

    -- Profile 4: native register is certified only for 30 minutes, while the
    -- requested policy is 15 minutes. Resolver must not misuse it and instead
    -- fall back to the compatible instantaneous power point.
    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model,
        firmware_version, profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_DEMAND_NATIVE_30', 'WiseWatts Test', 'NativeDemand30',
        '1', 'Native Demand 30 Test', 'Rollback-only capability fixture', TRUE
    ) RETURNING id INTO v_profile_native_mismatch;

    INSERT INTO config.profile_field_mapping(
        profile_id, raw_field_name, logical_point_id, is_required, display_order
    ) VALUES
        (v_profile_native_mismatch, 'D30', v_lp_active_power, FALSE, 10);

    INSERT INTO config.demand_register_semantics(
        profile_id, logical_point_id, demand_basis,
        native_interval_seconds, alignment_mode,
        source_unit_symbol, normalized_unit_symbol,
        scale_to_normalized_unit, is_active
    ) VALUES (
        v_profile_native_mismatch, v_lp_active_power, 'ACTIVE_POWER_KW',
        1800, 'WALL_CLOCK', 'kW', 'kW', 1, TRUE
    );

    INSERT INTO metadata.devices(
        organization_id, gateway_id, name, external_id, profile_id
    ) VALUES (
        v_org, v_gateway, 'Native Mismatch Device', 'DEMAND_NATIVE_30_DEVICE', v_profile_native_mismatch
    ) RETURNING id INTO v_device_native_mismatch;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_native_mismatch, 'ACTIVE_POWER_KW', 900
    );

    IF v_method IS DISTINCT FROM 'TIME_WEIGHTED_POWER'
       OR v_status IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION
            'Expected 30-min native register queried at 15 min -> TIME_WEIGHTED_POWER/READY, got %/%',
            v_method, v_status;
    END IF;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_counter, 'NOT_A_BASIS', 900
    );

    IF v_method IS NOT NULL
       OR v_status IS DISTINCT FROM 'INVALID_DEMAND_BASIS' THEN
        RAISE EXCEPTION
            'Expected invalid basis rejection, got %/%', v_method, v_status;
    END IF;

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM config.resolve_device_demand_method(
        v_device_counter, 'ACTIVE_POWER_KW', 600
    );

    IF v_method IS NOT NULL
       OR v_status IS DISTINCT FROM 'INVALID_DEMAND_INTERVAL' THEN
        RAISE EXCEPTION
            'Expected invalid interval rejection, got %/%', v_method, v_status;
    END IF;
END;
$test$;

\echo 'PASS: demand capability resolver method matrix'

ROLLBACK;
SQL

printf '%s\n' 'PASS: demand capability resolution assertions completed.'
