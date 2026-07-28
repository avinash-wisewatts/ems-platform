-- ============================================================================
-- File:
--   79_profile_aware_energy_routing.sql
--
-- Epic:
--   Epic 4 — Core Energy Analytics
--
-- Story:
--   4.1 — Formalize import/export register semantics
--
-- Purpose:
--   Replace hard-coded kWh/kW-to-Wh/W conversion assumptions with
--   profile-aware routing.
--
-- Eniscope hardware contract:
--
--   E, Ex     -> Wh
--   RE, REx   -> varh
--   AE        -> VAh
--   P, P1-P3  -> W
--   Q         -> var
--   S         -> VA
--
-- Cumulative-register conversion is driven by:
--
--   config.energy_register_semantics
--
-- Instantaneous Eniscope values are already in destination storage units and
-- therefore use scale 1.
--
-- The route output column order is intentionally preserved so the incremental
-- loader and downstream analytics remain compatible.
-- ============================================================================


DROP VIEW IF EXISTS telemetry.v_energy_measurements_route;


CREATE VIEW telemetry.v_energy_measurements_route AS

WITH profile_context AS
(
    SELECT
        np.*,
        d.profile_id,
        dp.profile_code
    FROM telemetry.normalized_points np

    JOIN metadata.devices d
      ON d.id = np.device_id

    LEFT JOIN config.device_profiles dp
      ON dp.id = d.profile_id
),

register_scales AS
(
    SELECT
        pc.event_time,
        pc.organization_id,
        pc.site_id,
        pc.gateway_id,
        pc.device_id,
        pc.logical_point_id,
        pc.logical_point,
        pc.numeric_value,
        pc.quality_code,
        pc.profile_id,
        pc.profile_code,

        ers.scale_to_normalized_unit

    FROM profile_context pc

    LEFT JOIN config.energy_register_semantics ers
      ON ers.profile_id = pc.profile_id
     AND ers.logical_point_id = pc.logical_point_id
     AND ers.is_active = TRUE
),

pivoted AS
(
    SELECT
        rs.event_time AS received_at,
        rs.event_time AS source_timestamp,

        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id,

        NULL::UUID AS asset_id,


        -- --------------------------------------------------------------------
        -- Cumulative active-energy registers.
        --
        -- A register is routed only when an active profile-level semantics row
        -- exists. This prevents unconfigured profiles from silently inheriting
        -- Eniscope assumptions.
        -- --------------------------------------------------------------------

        MAX
        (
            rs.numeric_value *
            rs.scale_to_normalized_unit
        )
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS import_energy_total_wh,

        MAX
        (
            rs.numeric_value *
            rs.scale_to_normalized_unit
        )
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS export_energy_total_wh,


        -- --------------------------------------------------------------------
        -- Cumulative reactive and apparent energy.
        -- --------------------------------------------------------------------

        MAX
        (
            rs.numeric_value *
            rs.scale_to_normalized_unit
        )
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_energy_total_varh,

        MAX
        (
            rs.numeric_value *
            rs.scale_to_normalized_unit
        )
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS reactive_export_energy_total_varh,

        MAX
        (
            rs.numeric_value *
            rs.scale_to_normalized_unit
        )
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_APPARENT_ENERGY_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.scale_to_normalized_unit IS NOT NULL
        ) AS apparent_energy_total_vah,


        -- --------------------------------------------------------------------
        -- Instantaneous Eniscope measurements.
        --
        -- Real Eniscope payloads already emit W, var and VA. No multiplication
        -- is applied.
        -- --------------------------------------------------------------------

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS active_power_total_w,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L1'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS active_power_l1_w,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L2'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS active_power_l2_w,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_ACTIVE_POWER_L3'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS active_power_l3_w,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_REACTIVE_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS reactive_power_total_var,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'ENERGY_APPARENT_POWER_TOTAL'
              AND rs.quality_code = 'GOOD'
              AND rs.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        ) AS apparent_power_total_va,


        -- --------------------------------------------------------------------
        -- Voltage, current, power factor, frequency and phase THD.
        -- These values already use destination units.
        -- --------------------------------------------------------------------

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'VOLTAGE_L1'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'VOLTAGE_L2'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'VOLTAGE_L3'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l3_v,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_L1'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_L2'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_L3'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l3_a,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'POWER_FACTOR_TOTAL'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS power_factor_total,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'FREQUENCY'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS frequency_hz,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_THD_L1'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_THD_L2'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(rs.numeric_value)
        FILTER
        (
            WHERE rs.logical_point = 'CURRENT_THD_L3'
              AND rs.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        COUNT(*) FILTER
        (
            WHERE rs.quality_code = 'GOOD'
              AND rs.numeric_value IS NOT NULL
        ) AS populated_point_count,

        COUNT(*) FILTER
        (
            WHERE rs.quality_code = 'INVALID_NUMERIC'
        ) AS invalid_point_count

    FROM register_scales rs

    GROUP BY
        rs.event_time,
        rs.organization_id,
        rs.site_id,
        rs.gateway_id,
        rs.device_id
)

SELECT *
FROM pivoted
WHERE populated_point_count > 0;


COMMENT ON VIEW telemetry.v_energy_measurements_route IS
'Profile-aware energy routing with declarative cumulative-register scaling and real Eniscope W/Wh unit handling.';
