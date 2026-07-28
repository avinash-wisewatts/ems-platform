\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS asset and telemetry tenant-isolation contract
--
-- Test tenants:
--   Grafana org 92001 -> Tenant Alpha
--   Grafana org 92002 -> Tenant Beta
--
-- Coverage:
--   * Asset selectors
--   * Asset energy latest/KPI views
--   * Environment sensor selectors
--   * Environment latest/KPI views
--   * Cross-tenant negative assertions
--
-- All test records are created inside one transaction and rolled back.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Verify required reference catalog records
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM config.device_profiles
        WHERE profile_code LIKE 'ENVIRONMENT_SENSOR_%'
    ) THEN
        RAISE EXCEPTION
            'No ENVIRONMENT_SENSOR_%% profile exists';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.asset_types
    ) THEN
        RAISE EXCEPTION
            'No asset type exists for the isolation test';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Organizations, sites, and Grafana mappings
-- ---------------------------------------------------------------------------

INSERT INTO metadata.organizations (
    id,
    name,
    code,
    description,
    is_active
)
VALUES
    (
        '93000000-0000-0000-0000-000000000001',
        'Telemetry Tenant Alpha',
        'TELEMETRY_ALPHA',
        'Disposable telemetry isolation tenant',
        TRUE
    ),
    (
        '93000000-0000-0000-0000-000000000002',
        'Telemetry Tenant Beta',
        'TELEMETRY_BETA',
        'Disposable telemetry isolation tenant',
        TRUE
    );

INSERT INTO metadata.sites (
    id,
    organization_id,
    name,
    code,
    timezone,
    address,
    is_active
)
VALUES
    (
        '93100000-0000-0000-0000-000000000001',
        '93000000-0000-0000-0000-000000000001',
        'Telemetry Alpha Site',
        'TELEMETRY_ALPHA_SITE',
        'Asia/Kolkata',
        '{}'::jsonb,
        TRUE
    ),
    (
        '93100000-0000-0000-0000-000000000002',
        '93000000-0000-0000-0000-000000000002',
        'Telemetry Beta Site',
        'TELEMETRY_BETA_SITE',
        'Asia/Kolkata',
        '{}'::jsonb,
        TRUE
    );

INSERT INTO metadata.grafana_organization_map (
    grafana_org_id,
    organization_id,
    is_active
)
VALUES
    (
        92001,
        '93000000-0000-0000-0000-000000000001',
        TRUE
    ),
    (
        92002,
        '93000000-0000-0000-0000-000000000002',
        TRUE
    );

-- ---------------------------------------------------------------------------
-- Gateways
-- ---------------------------------------------------------------------------

INSERT INTO metadata.gateways (
    id,
    organization_id,
    site_id,
    name,
    external_id
)
VALUES
    (
        '93200000-0000-0000-0000-000000000001',
        '93000000-0000-0000-0000-000000000001',
        '93100000-0000-0000-0000-000000000001',
        'Alpha Test Gateway',
        'ALPHA_TEST_GATEWAY'
    ),
    (
        '93200000-0000-0000-0000-000000000002',
        '93000000-0000-0000-0000-000000000002',
        '93100000-0000-0000-0000-000000000002',
        'Beta Test Gateway',
        'BETA_TEST_GATEWAY'
    );

-- ---------------------------------------------------------------------------
-- Energy devices
--
-- The energy analytics contract does not require a payload profile at this
-- layer. Profile resolution belongs to normalization/ingestion tests.
-- ---------------------------------------------------------------------------

INSERT INTO metadata.devices (
    id,
    organization_id,
    gateway_id,
    name,
    external_id,
    protocol,
    profile_id
)
VALUES
    (
        '93300000-0000-0000-0000-000000000001',
        '93000000-0000-0000-0000-000000000001',
        '93200000-0000-0000-0000-000000000001',
        'Alpha Energy Meter',
        'ALPHA_ENERGY_METER',
        'MQTT',
        NULL
    ),
    (
        '93300000-0000-0000-0000-000000000002',
        '93000000-0000-0000-0000-000000000002',
        '93200000-0000-0000-0000-000000000002',
        'Beta Energy Meter',
        'BETA_ENERGY_METER',
        'MQTT',
        NULL
    );

-- ---------------------------------------------------------------------------
-- Environment devices
-- ---------------------------------------------------------------------------

INSERT INTO metadata.devices (
    id,
    organization_id,
    gateway_id,
    name,
    external_id,
    protocol,
    profile_id
)
SELECT
    '93400000-0000-0000-0000-000000000001'::uuid,
    '93000000-0000-0000-0000-000000000001'::uuid,
    '93200000-0000-0000-0000-000000000001'::uuid,
    'Alpha Environment Sensor',
    'ALPHA_ENV_SENSOR',
    'MQTT',
    dp.id
FROM config.device_profiles dp
WHERE dp.profile_code LIKE 'ENVIRONMENT_SENSOR_%'
ORDER BY dp.profile_code
LIMIT 1;

INSERT INTO metadata.devices (
    id,
    organization_id,
    gateway_id,
    name,
    external_id,
    protocol,
    profile_id
)
SELECT
    '93400000-0000-0000-0000-000000000002'::uuid,
    '93000000-0000-0000-0000-000000000002'::uuid,
    '93200000-0000-0000-0000-000000000002'::uuid,
    'Beta Environment Sensor',
    'BETA_ENV_SENSOR',
    'MQTT',
    dp.id
FROM config.device_profiles dp
WHERE dp.profile_code LIKE 'ENVIRONMENT_SENSOR_%'
ORDER BY dp.profile_code
LIMIT 1;

-- ---------------------------------------------------------------------------
-- Assets and primary-meter relationships
-- ---------------------------------------------------------------------------

INSERT INTO metadata.assets (
    id,
    organization_id,
    site_id,
    asset_type_id,
    name,
    status,
    metering_requirement,
    metadata
)
SELECT
    '93500000-0000-0000-0000-000000000001'::uuid,
    '93000000-0000-0000-0000-000000000001'::uuid,
    '93100000-0000-0000-0000-000000000001'::uuid,
    at.id,
    'Alpha Chiller',
    'active',
    'DIRECT_METER_REQUIRED',
    '{}'::jsonb
FROM metadata.asset_types at
ORDER BY at.name
LIMIT 1;

INSERT INTO metadata.assets (
    id,
    organization_id,
    site_id,
    asset_type_id,
    name,
    status,
    metering_requirement,
    metadata
)
SELECT
    '93500000-0000-0000-0000-000000000002'::uuid,
    '93000000-0000-0000-0000-000000000002'::uuid,
    '93100000-0000-0000-0000-000000000002'::uuid,
    at.id,
    'Beta Chiller',
    'active',
    'DIRECT_METER_REQUIRED',
    '{}'::jsonb
FROM metadata.asset_types at
ORDER BY at.name
LIMIT 1;

INSERT INTO metadata.asset_devices (
    id,
    asset_id,
    device_id,
    relationship_type
)
VALUES
    (
        '93600000-0000-0000-0000-000000000001',
        '93500000-0000-0000-0000-000000000001',
        '93300000-0000-0000-0000-000000000001',
        'PRIMARY_METER'
    ),
    (
        '93600000-0000-0000-0000-000000000002',
        '93500000-0000-0000-0000-000000000002',
        '93300000-0000-0000-0000-000000000002',
        'PRIMARY_METER'
    );

-- ---------------------------------------------------------------------------
-- Direct energy measurements
--
-- Distinct values make accidental cross-tenant exposure easy to detect:
--   Alpha: 11 kW, 101 kWh
--   Beta:  22 kW, 202 kWh
-- ---------------------------------------------------------------------------

INSERT INTO telemetry.energy_measurements (
    received_at,
    source_timestamp,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    asset_id,
    measurement_interval_seconds,
    quality_code,
    is_estimated,
    import_energy_total_wh,
    active_power_total_w,
    power_factor_total,
    frequency_hz
)
VALUES
    (
        clock_timestamp() - interval '5 seconds',
        clock_timestamp() - interval '5 seconds',
        '93000000-0000-0000-0000-000000000001',
        '93100000-0000-0000-0000-000000000001',
        '93200000-0000-0000-0000-000000000001',
        '93300000-0000-0000-0000-000000000001',
        '93500000-0000-0000-0000-000000000001',
        60,
        0,
        FALSE,
        101000,
        11000,
        0.95,
        50.0
    ),
    (
        clock_timestamp() - interval '4 seconds',
        clock_timestamp() - interval '4 seconds',
        '93000000-0000-0000-0000-000000000002',
        '93100000-0000-0000-0000-000000000002',
        '93200000-0000-0000-0000-000000000002',
        '93300000-0000-0000-0000-000000000002',
        '93500000-0000-0000-0000-000000000002',
        60,
        0,
        FALSE,
        202000,
        22000,
        0.90,
        50.0
    );

-- ---------------------------------------------------------------------------
-- Direct environment measurements
--
-- Alpha: 21.5 C, 45%
-- Beta:  29.5 C, 70%
-- ---------------------------------------------------------------------------

INSERT INTO telemetry.environment_measurements (
    received_at,
    source_timestamp,
    organization_id,
    site_id,
    gateway_id,
    device_id,
    measurement_interval_seconds,
    quality_code,
    is_estimated,
    temperature_c,
    humidity_percent,
    illuminance_lux,
    occupancy_activity,
    battery_voltage_v
)
VALUES
    (
        clock_timestamp() - interval '5 seconds',
        clock_timestamp() - interval '5 seconds',
        '93000000-0000-0000-0000-000000000001',
        '93100000-0000-0000-0000-000000000001',
        '93200000-0000-0000-0000-000000000001',
        '93400000-0000-0000-0000-000000000001',
        60,
        0,
        FALSE,
        21.5,
        45.0,
        350.0,
        1.0,
        3.20
    ),
    (
        clock_timestamp() - interval '4 seconds',
        clock_timestamp() - interval '4 seconds',
        '93000000-0000-0000-0000-000000000002',
        '93100000-0000-0000-0000-000000000002',
        '93200000-0000-0000-0000-000000000002',
        '93400000-0000-0000-0000-000000000002',
        60,
        0,
        FALSE,
        29.5,
        70.0,
        600.0,
        0.0,
        2.90
    );

-- ---------------------------------------------------------------------------
-- Asset selector isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_rows bigint;
    beta_rows bigint;
    cross_rows bigint;
BEGIN
    SELECT count(*)
    INTO alpha_rows
    FROM analytics.v_asset_selector
    WHERE grafana_org_id = 92001
      AND asset_name = 'Alpha Chiller'
      AND external_id = 'ALPHA_ENERGY_METER';

    IF alpha_rows <> 1 THEN
        RAISE EXCEPTION
            'Alpha asset selector returned % expected rows instead of 1',
            alpha_rows;
    END IF;

    SELECT count(*)
    INTO beta_rows
    FROM analytics.v_asset_selector
    WHERE grafana_org_id = 92002
      AND asset_name = 'Beta Chiller'
      AND external_id = 'BETA_ENERGY_METER';

    IF beta_rows <> 1 THEN
        RAISE EXCEPTION
            'Beta asset selector returned % expected rows instead of 1',
            beta_rows;
    END IF;

    SELECT count(*)
    INTO cross_rows
    FROM analytics.v_asset_selector
    WHERE (
        grafana_org_id = 92001
        AND external_id = 'BETA_ENERGY_METER'
    )
       OR (
        grafana_org_id = 92002
        AND external_id = 'ALPHA_ENERGY_METER'
    );

    IF cross_rows <> 0 THEN
        RAISE EXCEPTION
            'Asset selector exposed % cross-tenant rows',
            cross_rows;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Energy KPI isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_demand double precision;
    beta_demand double precision;
    cross_rows bigint;
BEGIN
    SELECT current_demand_kw
    INTO alpha_demand
    FROM analytics.v_asset_energy_kpis
    WHERE grafana_org_id = 92001
      AND external_id = 'ALPHA_ENERGY_METER';

    IF alpha_demand IS DISTINCT FROM 11.0 THEN
        RAISE EXCEPTION
            'Alpha demand was %, expected 11.0 kW',
            alpha_demand;
    END IF;

    SELECT current_demand_kw
    INTO beta_demand
    FROM analytics.v_asset_energy_kpis
    WHERE grafana_org_id = 92002
      AND external_id = 'BETA_ENERGY_METER';

    IF beta_demand IS DISTINCT FROM 22.0 THEN
        RAISE EXCEPTION
            'Beta demand was %, expected 22.0 kW',
            beta_demand;
    END IF;

    SELECT count(*)
    INTO cross_rows
    FROM analytics.v_asset_energy_kpis
    WHERE (
        grafana_org_id = 92001
        AND external_id = 'BETA_ENERGY_METER'
    )
       OR (
        grafana_org_id = 92002
        AND external_id = 'ALPHA_ENERGY_METER'
    );

    IF cross_rows <> 0 THEN
        RAISE EXCEPTION
            'Energy KPI view exposed % cross-tenant rows',
            cross_rows;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Environment selector isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_rows bigint;
    beta_rows bigint;
    cross_rows bigint;
BEGIN
    SELECT count(*)
    INTO alpha_rows
    FROM analytics.v_environment_sensor_selector
    WHERE grafana_org_id = 92001
      AND external_id = 'ALPHA_ENV_SENSOR';

    IF alpha_rows <> 1 THEN
        RAISE EXCEPTION
            'Alpha environment selector returned % rows instead of 1',
            alpha_rows;
    END IF;

    SELECT count(*)
    INTO beta_rows
    FROM analytics.v_environment_sensor_selector
    WHERE grafana_org_id = 92002
      AND external_id = 'BETA_ENV_SENSOR';

    IF beta_rows <> 1 THEN
        RAISE EXCEPTION
            'Beta environment selector returned % rows instead of 1',
            beta_rows;
    END IF;

    SELECT count(*)
    INTO cross_rows
    FROM analytics.v_environment_sensor_selector
    WHERE (
        grafana_org_id = 92001
        AND external_id = 'BETA_ENV_SENSOR'
    )
       OR (
        grafana_org_id = 92002
        AND external_id = 'ALPHA_ENV_SENSOR'
    );

    IF cross_rows <> 0 THEN
        RAISE EXCEPTION
            'Environment selector exposed % cross-tenant rows',
            cross_rows;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Environment KPI isolation
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    alpha_temperature double precision;
    beta_temperature double precision;
    cross_rows bigint;
BEGIN
    SELECT temperature_c
    INTO alpha_temperature
    FROM analytics.v_environment_sensor_kpis
    WHERE grafana_org_id = 92001
      AND external_id = 'ALPHA_ENV_SENSOR';

    IF alpha_temperature IS DISTINCT FROM 21.5 THEN
        RAISE EXCEPTION
            'Alpha temperature was %, expected 21.5 C',
            alpha_temperature;
    END IF;

    SELECT temperature_c
    INTO beta_temperature
    FROM analytics.v_environment_sensor_kpis
    WHERE grafana_org_id = 92002
      AND external_id = 'BETA_ENV_SENSOR';

    IF beta_temperature IS DISTINCT FROM 29.5 THEN
        RAISE EXCEPTION
            'Beta temperature was %, expected 29.5 C',
            beta_temperature;
    END IF;

    SELECT count(*)
    INTO cross_rows
    FROM analytics.v_environment_sensor_kpis
    WHERE (
        grafana_org_id = 92001
        AND external_id = 'BETA_ENV_SENSOR'
    )
       OR (
        grafana_org_id = 92002
        AND external_id = 'ALPHA_ENV_SENSOR'
    );

    IF cross_rows <> 0 THEN
        RAISE EXCEPTION
            'Environment KPI view exposed % cross-tenant rows',
            cross_rows;
    END IF;
END
$$;

SELECT
    grafana_org_id,
    asset_name,
    external_id,
    current_demand_kw,
    import_energy_register_kwh
FROM analytics.v_asset_energy_kpis
WHERE grafana_org_id IN (92001, 92002)
ORDER BY grafana_org_id;

SELECT
    grafana_org_id,
    external_id,
    temperature_c,
    humidity_percent,
    sensor_status
FROM analytics.v_environment_sensor_kpis
WHERE grafana_org_id IN (92001, 92002)
ORDER BY grafana_org_id;

ROLLBACK;

SELECT 'Asset and telemetry tenant-isolation assertions passed.' AS result;
