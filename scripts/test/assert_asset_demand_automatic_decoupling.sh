#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Automatic asset-demand decoupling assertions ==='

docker compose -f "${PROJECT_ROOT}/compose.test.yaml" exec -T timescaledb-test \
psql -X -v ON_ERROR_STOP=1 -U ems_admin -d ems_test <<'SQL'
BEGIN;

DO $test$
DECLARE
    v_org UUID;
    v_site UUID;
    v_gateway UUID;
    v_asset UUID;
    v_device UUID;
    v_protocol UUID;
    v_profile UUID;
    v_lp_active_power UUID;
    v_energy_meter_category UUID;
    v_device_model UUID;
    v_asset_policy UUID;
    v_site_policy UUID;
    v_status TEXT;
    v_method TEXT;
    v_asset_state_count INTEGER;
    v_site_state_count INTEGER;
    v_final_count INTEGER;
    v_current_kw DOUBLE PRECISION;
    v_final_kw DOUBLE PRECISION;
    v_t TIMESTAMPTZ;
    v_test_now CONSTANT TIMESTAMPTZ := TIMESTAMPTZ '2026-08-10 12:07:00+00';
BEGIN
    SELECT id INTO v_protocol
    FROM config.protocols
    WHERE name = 'MQTT'
    LIMIT 1;

    SELECT id INTO v_lp_active_power
    FROM metadata.logical_points
    WHERE name = 'ACTIVE_POWER_TOTAL'
    LIMIT 1;

    SELECT id INTO v_energy_meter_category
    FROM config.device_categories
    WHERE lower(name) = 'energy meter'
    ORDER BY id
    LIMIT 1;

    IF v_protocol IS NULL OR v_lp_active_power IS NULL OR v_energy_meter_category IS NULL THEN
        RAISE EXCEPTION 'Automatic asset-demand fixture requires MQTT, ENERGY_ACTIVE_POWER_TOTAL, and Energy Meter category';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Asset Demand Decoupling Test Org', 'ASSET_DEMAND_DECOUPLING_TEST', 'UTC')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(
        organization_id, name, code, timezone, address, is_active
    ) VALUES (
        v_org, 'Asset Demand Decoupling Test Site', 'ASSET_DEMAND_DECOUPLING_SITE',
        'UTC', '{}'::jsonb, TRUE
    ) RETURNING id INTO v_site;

    -- Migration 017 must create the platform-managed ASSET policy automatically.
    SELECT p.id INTO v_asset_policy
    FROM config.site_demand_policies AS p
    WHERE p.site_id = v_site
      AND p.policy_scope = 'ASSET'
      AND p.is_enabled
      AND p.demand_interval_seconds = 900
      AND p.demand_basis = 'ACTIVE_POWER_KW'
      AND p.site_demand_source_role IS NULL
      AND p.effective_to IS NULL
    ORDER BY p.effective_from DESC
    LIMIT 1;

    IF v_asset_policy IS NULL THEN
        RAISE EXCEPTION 'Expected automatic 15-minute ACTIVE_POWER_KW ASSET policy for new site';
    END IF;

    -- Explicitly create a disabled SITE policy. This is the regression condition:
    -- SITE monitoring is off while ASSET demand must continue automatically.
    INSERT INTO config.site_demand_policies(
        site_id, policy_scope, is_enabled, demand_interval_seconds, demand_basis,
        site_demand_source_role, alignment_mode, minimum_coverage_percent,
        late_arrival_tolerance_seconds, effective_from, effective_to
    ) VALUES (
        v_site, 'SITE', FALSE, 900, 'ACTIVE_POWER_KW', 'GRID_IMPORT',
        'WALL_CLOCK', 90.00, 30, TIMESTAMPTZ '2000-01-01 00:00:00+00', NULL
    ) RETURNING id INTO v_site_policy;

    INSERT INTO metadata.gateways(
        organization_id, site_id, name, external_id
    ) VALUES (
        v_org, v_site, 'Asset Demand Decoupling Gateway', 'ASSET-DEMAND-DECOUPLING-GW'
    ) RETURNING id INTO v_gateway;

    INSERT INTO metadata.device_models(
        vendor, model, device_type, device_category_id
    ) VALUES (
        'WiseWatts Test', 'Asset Demand Decoupling Meter', 'Energy Meter', v_energy_meter_category
    )
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET
        device_type = EXCLUDED.device_type,
        device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    INSERT INTO config.device_profiles(
        protocol_id, profile_code, manufacturer, model, firmware_version,
        profile_name, description, is_active
    ) VALUES (
        v_protocol, 'TEST_ASSET_DEMAND_AUTO_POWER', 'WiseWatts Test',
        'AssetDemandPowerOnly', '1', 'Automatic Asset Demand Power Test',
        'Rollback-only automatic asset-demand regression fixture', TRUE
    ) RETURNING id INTO v_profile;

    -- Power-only profile deliberately exercises the TIME_WEIGHTED_POWER fallback.
    INSERT INTO config.profile_field_mapping(
        profile_id, raw_field_name, logical_point_id, is_required, display_order
    ) VALUES (
        v_profile, 'P', v_lp_active_power, FALSE, 10
    );

    INSERT INTO metadata.devices(
        organization_id, gateway_id, profile_id, device_model_id,
        name, external_id, protocol
    ) VALUES (
        v_org, v_gateway, v_profile, v_device_model,
        'Automatic Asset Demand Meter', 'ASSET-DEMAND-DECOUPLING-METER', 'MQTT'
    ) RETURNING id INTO v_device;

    INSERT INTO metadata.assets(
        organization_id, site_id, name, status, metering_requirement
    ) VALUES (
        v_org, v_site, 'Automatic Asset Demand Test Asset', 'active', 'DIRECT_METER_REQUIRED'
    ) RETURNING id INTO v_asset;

    INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type)
    VALUES (v_asset, v_device, 'PRIMARY_METER');

    -- analytics.refresh_demand_analytics's ASSET-scope enumeration/resolution
    -- (migration 250) now requires a confirmed metadata.asset_points binding,
    -- not PRIMARY_METER/asset_devices alone. The profile above maps only
    -- ACTIVE_POWER_TOTAL, which is exactly the point the TIME_WEIGHTED_POWER
    -- fallback this fixture exercises requires.
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (v_asset, v_device, v_lp_active_power, v_org, TIMESTAMPTZ '2026-08-10 00:00:00+00', NULL);

    SELECT selected_method, readiness_status
    INTO v_method, v_status
    FROM analytics.resolve_demand_capability(v_site, 'ASSET', v_asset, v_test_now);

    IF v_method IS DISTINCT FROM 'TIME_WEIGHTED_POWER'
       OR v_status IS DISTINCT FROM 'READY' THEN
        RAISE EXCEPTION
            'Expected automatic ASSET capability TIME_WEIGHTED_POWER/READY with SITE disabled, got %/%',
            v_method, v_status;
    END IF;

    -- Finalized 11:30-11:45 UTC interval: constant 12 kW, 60-second samples.
    v_t := TIMESTAMPTZ '2026-08-10 11:30:00+00';
    WHILE v_t <= TIMESTAMPTZ '2026-08-10 11:45:00+00' LOOP
        INSERT INTO telemetry.energy_measurements(
            bucket_start, received_at, source_timestamp,
            organization_id, site_id, gateway_id, device_id, asset_id,
            measurement_interval_seconds, quality_code, is_estimated,
            active_power_total_w
        ) VALUES (
            v_t, v_t + INTERVAL '5 seconds', v_t,
            v_org, v_site, v_gateway, v_device, v_asset,
            60, 0, FALSE, 12000
        );
        v_t := v_t + INTERVAL '1 minute';
    END LOOP;

    -- Current provisional 12:00-12:15 UTC interval through test-now 12:07.
    v_t := TIMESTAMPTZ '2026-08-10 12:00:00+00';
    WHILE v_t <= v_test_now LOOP
        INSERT INTO telemetry.energy_measurements(
            bucket_start, received_at, source_timestamp,
            organization_id, site_id, gateway_id, device_id, asset_id,
            measurement_interval_seconds, quality_code, is_estimated,
            active_power_total_w
        ) VALUES (
            v_t, v_t + INTERVAL '5 seconds', v_t,
            v_org, v_site, v_gateway, v_device, v_asset,
            60, 0, FALSE, 12000
        );
        v_t := v_t + INTERVAL '1 minute';
    END LOOP;

    CALL analytics.refresh_demand_analytics(v_test_now, INTERVAL '1 hour');

    SELECT count(*), max(current_demand_kw)
    INTO v_asset_state_count, v_current_kw
    FROM analytics.demand_state
    WHERE site_id = v_site
      AND scope_type = 'ASSET'
      AND asset_id = v_asset;

    IF v_asset_state_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one ASSET demand_state row, found %', v_asset_state_count;
    END IF;

    IF v_current_kw IS NULL OR abs(v_current_kw - 12.0) > 0.001 THEN
        RAISE EXCEPTION 'Expected provisional ASSET demand 12.0 kW, got %', v_current_kw;
    END IF;

    SELECT count(*) INTO v_site_state_count
    FROM analytics.demand_state
    WHERE site_id = v_site
      AND scope_type = 'SITE';

    IF v_site_state_count <> 0 THEN
        RAISE EXCEPTION 'Disabled SITE demand unexpectedly created % SITE demand_state row(s)', v_site_state_count;
    END IF;

    SELECT count(*), max(demand_kw)
    INTO v_final_count, v_final_kw
    FROM analytics.demand_intervals
    WHERE site_id = v_site
      AND scope_type = 'ASSET'
      AND asset_id = v_asset
      AND interval_start = TIMESTAMPTZ '2026-08-10 11:30:00+00'
      AND interval_end = TIMESTAMPTZ '2026-08-10 11:45:00+00'
      AND quality_status = 'VALID';

    IF v_final_count <> 1 THEN
        RAISE EXCEPTION 'Expected one finalized VALID ASSET demand interval, found %', v_final_count;
    END IF;

    IF v_final_kw IS NULL OR abs(v_final_kw - 12.0) > 0.001 THEN
        RAISE EXCEPTION 'Expected finalized ASSET demand 12.0 kW, got %', v_final_kw;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM analytics.demand_intervals
        WHERE site_id = v_site
          AND scope_type = 'SITE'
    ) THEN
        RAISE EXCEPTION 'Disabled SITE demand unexpectedly created finalized SITE intervals';
    END IF;
END;
$test$;

\echo 'PASS: SITE demand can be disabled while ASSET demand remains automatic'
\echo 'PASS: PRIMARY_METER capability resolved independently of SITE enablement'
\echo 'PASS: provisional 15-minute ASSET demand state calculated at 12.0 kW'
\echo 'PASS: finalized VALID ASSET demand interval calculated at 12.0 kW'

ROLLBACK;
SQL

printf '%s\n' 'PASS: automatic asset-demand decoupling assertions completed.'
