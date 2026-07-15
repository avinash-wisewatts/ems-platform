-- ============================================================================
-- File: 10_water_measurements.sql
-- Purpose: Water and fluid telemetry measurements.
--
-- Supports:
--   - Water meters
--   - Flow sensors
--   - STP monitoring
--   - Cooling water systems
--
-- Design:
--   - Vendor neutral
--   - Late-binding metadata
--   - TimescaleDB hypertable
-- ============================================================================


CREATE TABLE IF NOT EXISTS telemetry.water_measurements (

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
    -- Flow Measurements
    --------------------------------------------------------------------------

    flow_rate_m3_per_hr DOUBLE PRECISION,

    flow_rate_lpm DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Totalized Consumption
    --------------------------------------------------------------------------

    total_volume_m3 NUMERIC(20,6),


    --------------------------------------------------------------------------
    -- Pressure
    --------------------------------------------------------------------------

    pressure_bar DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Temperature
    --------------------------------------------------------------------------

    temperature_c DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Water Quality (Future Ready)
    --------------------------------------------------------------------------

    ph DOUBLE PRECISION,

    conductivity_us_cm DOUBLE PRECISION,

    turbidity_ntu DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Traceability
    --------------------------------------------------------------------------

    raw_archive_id BIGINT,


    PRIMARY KEY(received_at,id)

);


COMMENT ON TABLE telemetry.water_measurements IS
'TimescaleDB hypertable storing water and fluid telemetry measurements.';


SELECT create_hypertable(
    'telemetry.water_measurements',
    'received_at',
    if_not_exists => TRUE
);
