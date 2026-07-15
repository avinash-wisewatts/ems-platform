-- ============================================================================
-- File:
--   99_03_test_eniscope_ingestion.sql
--
-- Purpose:
--   Validate Eniscope telemetry mapping into energy_measurements.
--
-- This represents one parsed MQTT message.
-- ============================================================================


INSERT INTO telemetry.energy_measurements
(
    received_at,
    source_timestamp,

    organization_id,
    site_id,
    gateway_id,
    device_id,

    import_energy_total_wh,
    export_energy_total_wh,

    reactive_energy_total_varh,
    reactive_export_energy_total_varh,

    apparent_energy_total_vah,

    active_power_total_w,
    reactive_power_total_var,
    apparent_power_total_va,

    voltage_l1_v,
    voltage_l2_v,
    voltage_l3_v,

    current_l1_a,
    current_l2_a,
    current_l3_a,

    power_factor_total,
    frequency_hz,

    current_thd_l1_percent,
    current_thd_l2_percent,
    current_thd_l3_percent
)

SELECT

    now(),
    to_timestamp(1516362683),

    o.id,
    s.id,
    g.id,
    d.id,

    53559.31592,
    317545.1858,

    2285337.066,
    317545.1858,

    3088475.549,

    788.26,
    -282.33,
    837.36,

    241.30,
    241.68,
    242.17,

    2.436,
    2.423,
    2.4304,

    0.94137,
    50.055,

    NULL,
    NULL,
    NULL

FROM metadata.organizations o

JOIN metadata.sites s
ON s.organization_id=o.id

JOIN metadata.gateways g
ON g.site_id=s.id

JOIN metadata.devices d
ON d.gateway_id=g.id

WHERE d.external_id='ENI-DEMO-001';
