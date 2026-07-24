\set ON_ERROR_STOP on

-- =============================================================================
-- WiseWatts EMS canonical database assertions
--
-- This script must fail immediately when a required production object is
-- missing or incorrectly configured.
-- =============================================================================

DO $$
DECLARE
    missing_objects text[];
BEGIN
    SELECT array_agg(required_object)
    INTO missing_objects
    FROM (
        VALUES
            ('schema:metadata'),
            ('schema:config'),
            ('schema:telemetry'),
            ('schema:analytics'),
            ('schema:admin'),

            ('table:admin.schema_migrations'),

            ('table:metadata.organizations'),
            ('table:metadata.sites'),
            ('table:metadata.gateways'),
            ('table:metadata.devices'),
            ('table:metadata.assets'),
            ('table:metadata.logical_points'),

            ('table:config.device_profiles'),
            ('table:config.profile_field_mapping'),
            ('table:config.device_profile_categories'),

            ('table:telemetry.raw_messages'),
            ('table:telemetry.normalized_points'),
            ('table:telemetry.energy_measurements'),
            ('table:telemetry.environment_measurements'),

            -- Shared dashboard selectors
            ('view:analytics.v_sites'),
            ('view:analytics.v_asset_selector'),

            -- Energy Overview dashboard
            ('view:analytics.v_asset_energy_kpis'),
            ('view:analytics.v_asset_demand_15min'),
            ('view:analytics.v_asset_energy_15min'),

            -- Energy Performance dashboard
            ('view:analytics.v_asset_consumption_daily'),
            ('view:analytics.v_asset_consumption_monthly'),
            ('view:analytics.v_energy_consumption_site_kpis'),

            -- Peak Demand & Load Profile dashboard
            ('view:analytics.v_asset_load_profile_hourly'),
            ('view:analytics.v_asset_load_profile_hour_of_day'),
            ('view:analytics.v_asset_peak_demand_daily'),
            ('view:analytics.v_asset_peak_demand_monthly'),
            ('view:analytics.v_energy_site_demand_kpis'),

            -- Indoor Environment dashboard
            ('view:analytics.v_environment_sensor_selector'),
            ('view:analytics.v_environment_sensor_kpis'),
            ('view:analytics.v_environment_15min'),
            ('view:analytics.v_environment_hourly')
    ) AS required(required_object)
    WHERE CASE
        WHEN required_object LIKE 'schema:%' THEN
            to_regnamespace(split_part(required_object, ':', 2)) IS NULL

        WHEN required_object LIKE 'table:%' THEN
            to_regclass(split_part(required_object, ':', 2)) IS NULL

        WHEN required_object LIKE 'view:%' THEN
            to_regclass(split_part(required_object, ':', 2)) IS NULL

        ELSE true
    END;

    IF missing_objects IS NOT NULL THEN
        RAISE EXCEPTION
            'Canonical database is missing required objects: %',
            missing_objects;
    END IF;
END
$$;

-- The migration ledger must expose its required immutable contract.
DO $$
DECLARE
    missing_columns text[];
BEGIN
    SELECT array_agg(required_column)
    INTO missing_columns
    FROM (
        VALUES
            ('migration_id'),
            ('file_path'),
            ('checksum_sha256'),
            ('applied_at'),
            ('applied_by'),
            ('execution_ms'),
            ('application_mode')
    ) AS required(required_column)
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'admin'
          AND c.table_name = 'schema_migrations'
          AND c.column_name = required.required_column
    );

    IF missing_columns IS NOT NULL THEN
        RAISE EXCEPTION
            'Migration ledger is missing required columns: %',
            missing_columns;
    END IF;
END
$$;

-- A canonical clean installation must begin with an empty forward-migration
-- ledger. Canonical DDL is the current complete state and is not itself a
-- historical migration.
DO $$
DECLARE
    migration_count bigint;
BEGIN
    SELECT count(*)
    INTO migration_count
    FROM admin.schema_migrations;

    IF migration_count <> 0 THEN
        RAISE EXCEPTION
            'Fresh canonical database unexpectedly contains % migration records',
            migration_count;
    END IF;
END
$$;

-- TimescaleDB must be installed.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'timescaledb'
    ) THEN
        RAISE EXCEPTION 'TimescaleDB extension is not installed';
    END IF;
END
$$;

-- Core telemetry tables must be hypertables.
DO $$
DECLARE
    missing_hypertables text[];
BEGIN
    SELECT array_agg(expected_table)
    INTO missing_hypertables
    FROM (
        VALUES
            ('raw_messages'),
            ('normalized_points'),
            ('energy_measurements'),
            ('environment_measurements')
    ) AS expected(expected_table)
    WHERE NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables h
        WHERE h.hypertable_schema = 'telemetry'
          AND h.hypertable_name = expected.expected_table
    );

    IF missing_hypertables IS NOT NULL THEN
        RAISE EXCEPTION
            'Required telemetry hypertables are missing: %',
            missing_hypertables;
    END IF;
END
$$;

-- Required database roles must exist.
DO $$
DECLARE
    missing_roles text[];
BEGIN
    SELECT array_agg(required_role)
    INTO missing_roles
    FROM (
        VALUES
            ('ems_app'),
            ('ems_readonly'),
            ('grafana_reader'),
            ('telegraf_writer')
    ) AS required(required_role)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = required.required_role
    );

    IF missing_roles IS NOT NULL THEN
        RAISE EXCEPTION
            'Required database roles are missing: %',
            missing_roles;
    END IF;
END
$$;

-- Device profile compatibility support must exist.
DO $$
BEGIN
    IF to_regclass('config.device_profile_categories') IS NULL THEN
        RAISE EXCEPTION
            'config.device_profile_categories is missing';
    END IF;
END
$$;

-- Dashboard-facing analytics objects must be ordinary views.
DO $$
DECLARE
    invalid_relations text[];
BEGIN
    SELECT array_agg(expected_view)
    INTO invalid_relations
    FROM (
        VALUES
            ('v_sites'),
            ('v_asset_selector'),
            ('v_asset_energy_kpis'),
            ('v_asset_demand_15min'),
            ('v_asset_energy_15min'),
            ('v_asset_consumption_daily'),
            ('v_asset_consumption_monthly'),
            ('v_energy_consumption_site_kpis'),
            ('v_asset_load_profile_hourly'),
            ('v_asset_load_profile_hour_of_day'),
            ('v_asset_peak_demand_daily'),
            ('v_asset_peak_demand_monthly'),
            ('v_energy_site_demand_kpis'),
            ('v_environment_sensor_selector'),
            ('v_environment_sensor_kpis'),
            ('v_environment_15min'),
            ('v_environment_hourly')
    ) AS expected(expected_view)
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n
          ON n.oid = c.relnamespace
        WHERE n.nspname = 'analytics'
          AND c.relname = expected.expected_view
          AND c.relkind = 'v'
    );

    IF invalid_relations IS NOT NULL THEN
        RAISE EXCEPTION
            'Required analytics views are missing or have the wrong relation type: %',
            invalid_relations;
    END IF;
END
$$;

SELECT
    current_database() AS database_name,
    extversion AS timescaledb_version
FROM pg_extension
WHERE extname = 'timescaledb';

SELECT
    hypertable_schema,
    hypertable_name
FROM timescaledb_information.hypertables
WHERE hypertable_schema = 'telemetry'
ORDER BY hypertable_name;

SELECT 'Canonical database assertions passed.' AS result;
