-- ============================================================================
-- File: 12_device_status.sql
-- Purpose: IoT device and gateway operational status telemetry.
--
-- Supports:
--   - Gateways
--   - Smart meters
--   - Environmental sensors
--   - IoT edge devices
--
-- Design:
--   - Vendor neutral
--   - Late-binding metadata
--   - TimescaleDB hypertable
-- ============================================================================


CREATE TABLE IF NOT EXISTS telemetry.device_status (

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


    --------------------------------------------------------------------------
    -- Communication Status
    --------------------------------------------------------------------------

    communication_status TEXT,

    last_successful_communication TIMESTAMPTZ,

    connection_duration_seconds BIGINT,


    --------------------------------------------------------------------------
    -- Network Health
    --------------------------------------------------------------------------

    signal_strength_dbm DOUBLE PRECISION,

    packet_loss_percent DOUBLE PRECISION,

    latency_ms DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Device Health
    --------------------------------------------------------------------------

    battery_voltage_v DOUBLE PRECISION,

    battery_percent DOUBLE PRECISION,

    internal_temperature_c DOUBLE PRECISION,


    --------------------------------------------------------------------------
    -- Firmware / Software
    --------------------------------------------------------------------------

    firmware_version TEXT,

    software_version TEXT,


    --------------------------------------------------------------------------
    -- Error Tracking
    --------------------------------------------------------------------------

    error_code TEXT,

    error_message TEXT,


    --------------------------------------------------------------------------
    -- Traceability
    --------------------------------------------------------------------------

    raw_archive_id BIGINT,


    PRIMARY KEY(received_at,id)

);


COMMENT ON TABLE telemetry.device_status IS
'TimescaleDB hypertable storing IoT device operational health and connectivity telemetry.';


SELECT create_hypertable(
    'telemetry.device_status',
    'received_at',
    if_not_exists => TRUE
);
