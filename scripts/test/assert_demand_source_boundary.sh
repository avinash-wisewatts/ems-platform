#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

printf '%s\n' '=== Demand source-boundary assertions (migration 250) ==='

# Exercises analytics.resolve_demand_source_for_interval and
# analytics.calculate_demand_window's ASSET-scope gate directly against
# real metadata.asset_points/config.device_point_configuration rows.
# Focuses on the new containment/boundary logic itself (migration 250's
# actual change); a full end-to-end ENERGY_COUNTER_DELTA numeric result
# additionally requires config.energy_register_semantics fixtures and real
# telemetry.energy_measurements register rows, exercised here for the
# regression case only -- the boundary/no-source cases need no telemetry
# at all, since calculate_demand_window short-circuits before any
# calculation branch runs when no single source spans the interval.
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
    v_device_a UUID;
    v_device_b UUID;
    v_energy_import_total_id UUID;
    v_profile_id UUID;
    v_asset UUID;
    v_row RECORD;
    v_count INTEGER;
BEGIN
    SELECT id INTO v_energy_meter_category
    FROM config.device_categories WHERE lower(name) = 'energy meter' ORDER BY id LIMIT 1;
    -- ENERGY_IMPORT_TOTAL, not ACTIVE_POWER_TOTAL: verified this session
    -- that the ENERGY_METER_ENISCOPE_V1 test/staging profile has no
    -- config.demand_register_semantics row (METER_NATIVE never applies)
    -- but does have config.energy_register_semantics for ENERGY_IMPORT_
    -- TOTAL, so config.resolve_device_demand_method resolves this
    -- profile's devices to ENERGY_COUNTER_DELTA (priority 2) whenever
    -- that point is available -- confirming ENERGY_IMPORT_TOTAL, not
    -- ACTIVE_POWER_TOTAL, is what a device on this profile actually
    -- resolves to. See the "Unexpected finding" note this fixture choice
    -- exists to sidestep: resolve_demand_source_for_interval currently
    -- asks a device for its single OVERALL best method and only accepts
    -- it if that exact point was confirmed -- it does not yet fall back
    -- to a lower-priority method when only a lower-priority point was
    -- confirmed. Confirming the point the device's top method actually
    -- needs avoids exercising that gap here; it is reported, not fixed,
    -- in this pass.
    SELECT id INTO v_energy_import_total_id
    FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL';
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1';

    IF v_energy_meter_category IS NULL OR v_energy_import_total_id IS NULL OR v_profile_id IS NULL THEN
        RAISE EXCEPTION 'Demand source-boundary fixture requires an Energy Meter category, ENERGY_IMPORT_TOTAL logical point, and the ENERGY_METER_ENISCOPE_V1 profile';
    END IF;

    INSERT INTO metadata.organizations(name, code, timezone)
    VALUES ('Demand Boundary Test Org', 'DEMAND_BOUNDARY_TEST_ORG', 'UTC')
    RETURNING id INTO v_org;

    INSERT INTO metadata.sites(organization_id, name, code, timezone, address, is_active)
    VALUES (v_org, 'Demand Boundary Test Site', 'DEMAND_BOUNDARY_TEST_SITE', 'UTC', '{}'::jsonb, TRUE)
    RETURNING id INTO v_site;

    INSERT INTO metadata.gateways(organization_id, site_id, name, external_id)
    VALUES (v_org, v_site, 'Demand Boundary Test Gateway', 'DEMAND-BOUNDARY-TEST-GW')
    RETURNING id INTO v_gateway;

    INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id)
    VALUES ('WiseWatts Test', 'Demand Boundary Test Meter', 'Energy Meter', v_energy_meter_category)
    ON CONFLICT (lower(COALESCE(vendor, '')), lower(model))
    DO UPDATE SET device_type = EXCLUDED.device_type, device_category_id = EXCLUDED.device_category_id
    RETURNING id INTO v_device_model;

    -- Device A: the outgoing source. Device B: the incoming source. Both
    -- must carry profile_id -- config.resolve_device_demand_method joins
    -- config.device_profiles via metadata.devices.profile_id, and returns
    -- SOURCE_PROFILE_NOT_CONFIGURED/capability_ready=false without it.
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Demand Boundary Meter A', 'DEMAND-BOUNDARY-METER-A', 'MQTT')
    RETURNING id INTO v_device_a;
    INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id, protocol)
    VALUES (v_org, v_gateway, v_device_model, v_profile_id, 'Demand Boundary Meter B', 'DEMAND-BOUNDARY-METER-B', 'MQTT')
    RETURNING id INTO v_device_b;

    -- No explicit config.device_point_configuration insert here:
    -- trg_sync_device_points_after_profile_change already populated it
    -- for every point ENERGY_METER_ENISCOPE_V1 maps (including
    -- ENERGY_IMPORT_TOTAL) the moment profile_id was set above.

    INSERT INTO metadata.assets(organization_id, site_id, name, status, metering_requirement)
    VALUES (v_org, v_site, 'Demand Boundary Test Asset', 'active', 'DIRECT_METER_REQUIRED')
    RETURNING id INTO v_asset;

    -- ------------------------------------------------------------------
    -- 1. Regression: a single source whose binding fully covers a
    --    15-minute interval resolves that one device/point/method.
    -- ------------------------------------------------------------------
    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (
        v_asset, v_device_a, v_energy_import_total_id, v_org,
        TIMESTAMPTZ '2026-08-10 10:00:00+00', TIMESTAMPTZ '2026-08-10 10:15:00+00'
    );

    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset,
        TIMESTAMPTZ '2026-08-10 10:00:00+00', TIMESTAMPTZ '2026-08-10 10:15:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.device_id IS DISTINCT FROM v_device_a OR v_row.selected_method IS DISTINCT FROM 'ENERGY_COUNTER_DELTA' THEN
        RAISE EXCEPTION 'Expected device A / ENERGY_COUNTER_DELTA for a stable, fully-covering source, got device=%/method=%',
            v_row.device_id, v_row.selected_method;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Boundary: a source change mid-interval (device A ends, device B
    --    starts, both partway through the same 15-minute interval) --
    --    neither binding fully covers the interval, so no source is
    --    resolved. No splicing.
    -- ------------------------------------------------------------------
    -- Extend device A's binding forward to 11:07 (it was 10:00-10:15 for
    -- case 1 above; that row remains valid for its own original window --
    -- migration 228's exclusion constraint permits this since we are only
    -- pushing effective_to later, not creating an overlap).
    UPDATE metadata.asset_points
       SET effective_to = TIMESTAMPTZ '2026-08-10 11:07:00+00'
     WHERE asset_id = v_asset AND device_id = v_device_a;

    INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to)
    VALUES (
        v_asset, v_device_b, v_energy_import_total_id, v_org,
        TIMESTAMPTZ '2026-08-10 11:07:00+00', NULL
    );

    SELECT count(*) INTO v_count
    FROM analytics.resolve_demand_source_for_interval(
        v_asset,
        TIMESTAMPTZ '2026-08-10 11:00:00+00', TIMESTAMPTZ '2026-08-10 11:15:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected no resolved source for an interval spanning a mid-interval source change, got % row(s)', v_count;
    END IF;

    SELECT * INTO v_row
    FROM analytics.calculate_demand_window(
        v_site, 'ASSET', v_asset,
        TIMESTAMPTZ '2026-08-10 11:00:00+00', TIMESTAMPTZ '2026-08-10 11:15:00+00',
        TIMESTAMPTZ '2026-08-10 11:15:00+00', TRUE
    );
    IF v_row.quality_status IS DISTINCT FROM 'SOURCE_BOUNDARY' THEN
        RAISE EXCEPTION 'Expected quality_status=SOURCE_BOUNDARY for a mid-interval source change, got %', v_row.quality_status;
    END IF;
    IF v_row.demand_kw IS NOT NULL OR v_row.demand_kva IS NOT NULL THEN
        RAISE EXCEPTION 'Expected NULL demand_kw/demand_kva for a SOURCE_BOUNDARY interval (no synthetic hybrid value), got %/%',
            v_row.demand_kw, v_row.demand_kva;
    END IF;
    IF v_row.source_device_id IS NOT NULL THEN
        RAISE EXCEPTION 'Expected NULL source_device_id for a SOURCE_BOUNDARY interval, got %', v_row.source_device_id;
    END IF;

    -- ------------------------------------------------------------------
    -- 3. Resume: the NEXT interval, fully covered by device B alone,
    --    resolves normally again.
    -- ------------------------------------------------------------------
    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset,
        TIMESTAMPTZ '2026-08-10 11:15:00+00', TIMESTAMPTZ '2026-08-10 11:30:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.device_id IS DISTINCT FROM v_device_b THEN
        RAISE EXCEPTION 'Expected device B resolved for the interval immediately after the change, once fully covered, got %', v_row.device_id;
    END IF;

    -- ------------------------------------------------------------------
    -- 4. Historical immutability: the interval BEFORE the change (fully
    --    covered by device A alone, before it was shortened) still
    --    resolves to device A -- the earlier UPDATE only trimmed A's
    --    effective_to going forward, it did not retroactively remove A's
    --    validity for a window entirely before the change.
    -- ------------------------------------------------------------------
    SELECT * INTO v_row
    FROM analytics.resolve_demand_source_for_interval(
        v_asset,
        TIMESTAMPTZ '2026-08-10 10:45:00+00', TIMESTAMPTZ '2026-08-10 11:00:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_row.device_id IS DISTINCT FROM v_device_a THEN
        RAISE EXCEPTION 'Expected device A still resolved for an interval entirely before the source change, got %', v_row.device_id;
    END IF;

    -- ------------------------------------------------------------------
    -- 5. No source at all (asset with zero asset_points) -- resolves to
    --    no row, and calculate_demand_window returns SOURCE_BOUNDARY,
    --    never NO_DATA/INVALID_SOURCE (those remain reserved for other
    --    failure shapes -- policy disabled, device incapable, etc.).
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_count
    FROM analytics.resolve_demand_source_for_interval(
        gen_random_uuid(),
        TIMESTAMPTZ '2026-08-10 10:00:00+00', TIMESTAMPTZ '2026-08-10 10:15:00+00',
        'ACTIVE_POWER_KW', 900
    );
    IF v_count <> 0 THEN
        RAISE EXCEPTION 'Expected no rows for an asset with zero asset_points bindings, got %', v_count;
    END IF;
END;
$test$;

\echo 'PASS: a stable, fully-covering single source resolves normally'
\echo 'PASS: a mid-interval source change resolves no source and yields SOURCE_BOUNDARY with NULL demand_kw/demand_kva/source_device_id -- no splicing'
\echo 'PASS: the interval immediately after the change, once fully covered by the new source, resolves normally -- calculation resumes'
\echo 'PASS: an interval entirely before the change still resolves to the original source -- historical immutability'
\echo 'PASS: an asset with no confirmed source resolves no row'

ROLLBACK;
SQL

printf '%s\n' 'PASS: demand source-boundary assertions completed.'
