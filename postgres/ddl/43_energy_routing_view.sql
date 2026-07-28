CREATE OR REPLACE VIEW telemetry.v_energy_measurements_route AS

SELECT
    np.event_time AS received_at,

    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,

    NULL::uuid AS asset_id,

    MAX(CASE
        WHEN logical_point='ENERGY_IMPORT_TOTAL'
        THEN numeric_value
    END) AS import_energy_total_wh,

    MAX(CASE
        WHEN logical_point='ENERGY_ACTIVE_POWER_TOTAL'
        THEN numeric_value
    END) AS active_power_total_w,

    MAX(CASE
        WHEN logical_point='ENERGY_APPARENT_POWER_TOTAL'
        THEN numeric_value
    END) AS apparent_power_total_va,

    MAX(CASE
        WHEN logical_point='ENERGY_REACTIVE_POWER_TOTAL'
        THEN numeric_value
    END) AS reactive_power_total_var,

    MAX(CASE
        WHEN logical_point='CURRENT_L1'
        THEN numeric_value
    END) AS current_l1_a,

    MAX(CASE
        WHEN logical_point='CURRENT_L2'
        THEN numeric_value
    END) AS current_l2_a,

    MAX(CASE
        WHEN logical_point='CURRENT_L3'
        THEN numeric_value
    END) AS current_l3_a,

    MAX(CASE
        WHEN logical_point='VOLTAGE_L1'
        THEN numeric_value
    END) AS voltage_l1_v,

    MAX(CASE
        WHEN logical_point='VOLTAGE_L2'
        THEN numeric_value
    END) AS voltage_l2_v,

    MAX(CASE
        WHEN logical_point='VOLTAGE_L3'
        THEN numeric_value
    END) AS voltage_l3_v,

    MAX(CASE
        WHEN logical_point='POWER_FACTOR_TOTAL'
        THEN numeric_value
    END) AS power_factor_total,

    MAX(CASE
        WHEN logical_point='FREQUENCY'
        THEN numeric_value
    END) AS frequency_hz

FROM telemetry.normalized_points np

GROUP BY
    np.event_time,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id;
