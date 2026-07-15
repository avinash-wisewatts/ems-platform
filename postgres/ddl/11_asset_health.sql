-- ============================================================================
-- File: 11_asset_health.sql
-- Purpose: Asset condition and operational health telemetry.
--
-- Supports:
--   - Pumps
--   - Chillers
--   - AHUs
--   - Motors
--   - Compressors
--   - Other industrial assets
--
-- Design:
--   - Vendor neutral
--   - Late-binding metadata
--   - TimescaleDB hypertable
-- ============================================================================


CREATE TABLE IF NOT EXISTS telemetry.asset_health (

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
    -- Equipment Operating State
    --------------------------------------------------------------------------

    running_status BOOLEAN,

    operating_state TEXT,


    --------------------------------------------------------------------------
    -- Runtime
    --------------------------------------------------------------------------

    runtime_hours_total NUMERIC(20,6),

    starts_count BIGINT,


    --------------------------------------------------------------------------
    -- Thermal Health
    --------------------------------------------------------------------------

    temperature_c DOUBLE PRECISION,

    winding_temperature_c DOUBLE PRECISION,

    bearing_temperature_c DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Mechanical Health
    --------------------------------------------------------------------------

    vibration_mm_s DOUBLE PRECISION,

    vibration_x_mm_s DOUBLE PRECISION,

    vibration_y_mm_s DOUBLE PRECISION,

    vibration_z_mm_s DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Electrical Health
    --------------------------------------------------------------------------

    current_a DOUBLE PRECISION,

    power_kw DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Diagnostics
    --------------------------------------------------------------------------

    alarm_active BOOLEAN,

    alarm_code TEXT,

    fault_code TEXT,


    --------------------------------------------------------------------------
    -- Traceability
    --------------------------------------------------------------------------

    raw_archive_id BIGINT,


    PRIMARY KEY(received_at,id)

);


COMMENT ON TABLE telemetry.asset_health IS
'TimescaleDB hypertable storing asset condition, runtime, and diagnostic telemetry.';


SELECT create_hypertable(
    'telemetry.asset_health',
    'received_at',
    if_not_exists => TRUE
);
