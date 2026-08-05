-- ============================================================================
-- File: 08_energy_measurements.sql
-- Schema: telemetry
-- Table : energy_measurements
--
-- Purpose
-- ----------------------------------------------------------------------------
-- Stores parsed electrical measurements from power meters.
--
-- This is the primary production telemetry hypertable for electrical energy.
--
-- Design Principles
-- ----------------------------------------------------------------------------
-- • Vendor-neutral engineering data model
-- • Hybrid wide-table architecture
-- • Optimized for TimescaleDB
-- • Optimized for Grafana
-- • No foreign keys (high write throughput)
-- • UUID references only
-- • Late-binding metadata architecture
--
-- Source Examples
-- ----------------------------------------------------------------------------
-- Eniscope
-- Schneider EM6400
-- Schneider EM6436H
-- Siemens
-- ABB
-- Socomec
--
-- ============================================================================
CREATE TABLE IF NOT EXISTS telemetry.energy_measurements (

    --------------------------------------------------------------------------
    -- Identity
    --------------------------------------------------------------------------

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
    -- Measurement Metadata
    --------------------------------------------------------------------------

    measurement_interval_seconds SMALLINT,

    quality_code SMALLINT,

    is_estimated BOOLEAN DEFAULT FALSE,

    sequence_number BIGINT,



    --------------------------------------------------------------------------
    -- Active Energy (Import)
    --------------------------------------------------------------------------

    import_energy_total_wh NUMERIC(20,6),

    import_energy_l1_wh NUMERIC(20,6),

    import_energy_l2_wh NUMERIC(20,6),

    import_energy_l3_wh NUMERIC(20,6),



    --------------------------------------------------------------------------
    -- Active Energy (Export)
    --------------------------------------------------------------------------

    export_energy_total_wh NUMERIC(20,6),

    export_energy_l1_wh NUMERIC(20,6),

    export_energy_l2_wh NUMERIC(20,6),

    export_energy_l3_wh NUMERIC(20,6),



    --------------------------------------------------------------------------
    -- Reactive Energy
    --------------------------------------------------------------------------

    reactive_energy_total_varh NUMERIC(20,6),

    reactive_energy_l1_varh NUMERIC(20,6),

    reactive_energy_l2_varh NUMERIC(20,6),

    reactive_energy_l3_varh NUMERIC(20,6),



    --------------------------------------------------------------------------
    -- Reactive Export Energy
    --------------------------------------------------------------------------

    reactive_export_energy_total_varh NUMERIC(20,6),

    reactive_export_energy_l1_varh NUMERIC(20,6),

    reactive_export_energy_l2_varh NUMERIC(20,6),

    reactive_export_energy_l3_varh NUMERIC(20,6),



    --------------------------------------------------------------------------
    -- Apparent Energy
    --------------------------------------------------------------------------

    apparent_energy_total_vah NUMERIC(20,6),

    apparent_energy_l1_vah NUMERIC(20,6),

    apparent_energy_l2_vah NUMERIC(20,6),

    apparent_energy_l3_vah NUMERIC(20,6),



    --------------------------------------------------------------------------
    -- Active Power
    --------------------------------------------------------------------------

    active_power_total_w DOUBLE PRECISION,

    active_power_l1_w DOUBLE PRECISION,

    active_power_l2_w DOUBLE PRECISION,

    active_power_l3_w DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Reactive Power
    --------------------------------------------------------------------------

    reactive_power_total_var DOUBLE PRECISION,

    reactive_power_l1_var DOUBLE PRECISION,

    reactive_power_l2_var DOUBLE PRECISION,

    reactive_power_l3_var DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Apparent Power
    --------------------------------------------------------------------------

    apparent_power_total_va DOUBLE PRECISION,

    apparent_power_l1_va DOUBLE PRECISION,

    apparent_power_l2_va DOUBLE PRECISION,

    apparent_power_l3_va DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Voltage
    --------------------------------------------------------------------------

    voltage_ln_avg_v DOUBLE PRECISION,

    voltage_l1_v DOUBLE PRECISION,

    voltage_l2_v DOUBLE PRECISION,

    voltage_l3_v DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Line-Line Voltage
    --------------------------------------------------------------------------

    voltage_ll_avg_v DOUBLE PRECISION,

    voltage_l12_v DOUBLE PRECISION,

    voltage_l23_v DOUBLE PRECISION,

    voltage_l31_v DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Current
    --------------------------------------------------------------------------

    current_total_a DOUBLE PRECISION,

    current_l1_a DOUBLE PRECISION,

    current_l2_a DOUBLE PRECISION,

    current_l3_a DOUBLE PRECISION,

    neutral_current_a DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Power Factor
    --------------------------------------------------------------------------

    power_factor_total DOUBLE PRECISION,

    power_factor_l1 DOUBLE PRECISION,

    power_factor_l2 DOUBLE PRECISION,

    power_factor_l3 DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Frequency
    --------------------------------------------------------------------------

    frequency_hz DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Phase Angle
    --------------------------------------------------------------------------

    phase_angle_l1_deg DOUBLE PRECISION,

    phase_angle_l2_deg DOUBLE PRECISION,

    phase_angle_l3_deg DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Harmonics
    --------------------------------------------------------------------------

    current_thd_total_percent DOUBLE PRECISION,

    current_thd_l1_percent DOUBLE PRECISION,

    current_thd_l2_percent DOUBLE PRECISION,

    current_thd_l3_percent DOUBLE PRECISION,

    voltage_thd_l1_percent DOUBLE PRECISION,

    voltage_thd_l2_percent DOUBLE PRECISION,

    voltage_thd_l3_percent DOUBLE PRECISION,



    --------------------------------------------------------------------------
    -- Pulse Counter
    --------------------------------------------------------------------------

    pulse_count BIGINT,



    --------------------------------------------------------------------------
    -- Traceability
    --------------------------------------------------------------------------

    raw_archive_id BIGINT,


    --------------------------------------------------------------------------
    -- Primary Key
    --------------------------------------------------------------------------

    PRIMARY KEY (received_at, id)
);

COMMENT ON TABLE telemetry.energy_measurements IS
'Primary TimescaleDB hypertable storing parsed electrical telemetry using the WiseWatts Enterprise Energy Measurement Model (EEMM).';

SELECT create_hypertable(
    'telemetry.energy_measurements',
    'received_at',
    if_not_exists => TRUE
);
