-- ============================================================================
-- File: 09_environment_measurements.sql
-- Purpose: Environmental telemetry measurements.
--
-- Supports:
--   - Temperature
--   - Humidity
--   - Air quality sensors
--   - Future environmental devices
--
-- Design:
--   - Vendor neutral
--   - Late-binding metadata
--   - TimescaleDB hypertable
-- ============================================================================


CREATE TABLE IF NOT EXISTS telemetry.environment_measurements (

    id BIGINT GENERATED ALWAYS AS IDENTITY,

    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    source_timestamp TIMESTAMPTZ,


    --------------------------------------------------------------------------
    -- Tenant Context
    --------------------------------------------------------------------------

    organization_id UUID NOT NULL,

    site_id UUID,

    gateway_id UUID,

    device_id UUID,

    asset_id UUID,


    --------------------------------------------------------------------------
    -- Measurement Context
    --------------------------------------------------------------------------

    measurement_interval_seconds SMALLINT,

    quality_code SMALLINT,

    is_estimated BOOLEAN DEFAULT FALSE,


    --------------------------------------------------------------------------
    -- Environmental Measurements
    --------------------------------------------------------------------------

    temperature_c DOUBLE PRECISION,

    humidity_percent DOUBLE PRECISION,

    pressure_hpa DOUBLE PRECISION,

    co2_ppm DOUBLE PRECISION,

    voc_ppb DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Device Status / Battery
    --------------------------------------------------------------------------

    battery_voltage_v DOUBLE PRECISION,

    signal_strength_dbm DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Traceability
    --------------------------------------------------------------------------

    raw_archive_id BIGINT,


    PRIMARY KEY(received_at,id)

);


COMMENT ON TABLE telemetry.environment_measurements IS
'TimescaleDB hypertable storing environmental sensor telemetry.';


SELECT create_hypertable(
    'telemetry.environment_measurements',
    'received_at',
    if_not_exists => TRUE
);
