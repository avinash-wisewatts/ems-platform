-- ============================================================================
-- File:
--   46_energy_routing_contract.sql
--
-- Purpose:
--   Finalize the database contract between canonical normalized telemetry and
--   the wide telemetry.energy_measurements domain hypertable.
--
-- Identity:
--
--   One energy_measurements row represents:
--
--       one device + one device event timestamp
--
--   The domain table currently uses received_at as its TimescaleDB partition
--   column. For deterministic historical routing, the normalized event_time is
--   used for both:
--
--       received_at
--       source_timestamp
--
--   A later schema enhancement may add a separate source_received_at column to
--   normalized_points so device time and database arrival time remain distinct.
--
-- Unit conversion:
--
--   metadata.logical_points stores engineering units:
--
--       kW    -> destination column ending in _w
--       kWh   -> destination column ending in _wh
--       kvar  -> destination column ending in _var
--       kvarh -> destination column ending in _varh
--       kVA   -> destination column ending in _va
--       kVAh  -> destination column ending in _vah
--
--   Therefore these values are multiplied by 1000 during routing.
--
--   Values already expressed in volts, amperes, hertz, percent, or unitless
--   power factor are not converted.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Prevent duplicate domain rows.
--
-- TimescaleDB requires the partitioning column received_at to be included in
-- every unique index.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS uq_energy_measurements_identity
ON telemetry.energy_measurements
(
    received_at,
    device_id
);


-- ----------------------------------------------------------------------------
-- 2. Canonical energy routing view.
--
-- Only valid numeric values are pivoted. Missing or invalid values remain NULL.
--
-- asset_id remains NULL until metadata.asset_devices assignments are created.
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS telemetry.v_energy_measurements_route;
CREATE OR REPLACE VIEW telemetry.v_energy_measurements_route AS

WITH pivoted AS
(
    SELECT
        np.event_time AS received_at,
        np.event_time AS source_timestamp,

        np.organization_id,
        np.site_id,
        np.gateway_id,
        np.device_id,

        NULL::UUID AS asset_id,

        -- ------------------------------------------------------------
        -- Cumulative active energy: kWh -> Wh
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_IMPORT_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS import_energy_total_wh,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_EXPORT_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS export_energy_total_wh,


        -- ------------------------------------------------------------
        -- Cumulative reactive energy: kvarh -> varh
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_REACTIVE_ENERGY_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS reactive_energy_total_varh,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_REACTIVE_EXPORT_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS reactive_export_energy_total_varh,


        -- ------------------------------------------------------------
        -- Cumulative apparent energy: kVAh -> VAh
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_APPARENT_ENERGY_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS apparent_energy_total_vah,


        -- ------------------------------------------------------------
        -- Active power: kW -> W
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_ACTIVE_POWER_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS active_power_total_w,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_ACTIVE_POWER_L1'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS active_power_l1_w,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_ACTIVE_POWER_L2'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS active_power_l2_w,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_ACTIVE_POWER_L3'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS active_power_l3_w,


        -- ------------------------------------------------------------
        -- Reactive power: kvar -> var
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_REACTIVE_POWER_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS reactive_power_total_var,


        -- ------------------------------------------------------------
        -- Apparent power: kVA -> VA
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'ENERGY_APPARENT_POWER_TOTAL'
              AND np.quality_code = 'GOOD'
        ) * 1000.0 AS apparent_power_total_va,


        -- ------------------------------------------------------------
        -- Phase-to-neutral voltage: V -> V
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'VOLTAGE_L1'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l1_v,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'VOLTAGE_L2'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l2_v,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'VOLTAGE_L3'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS voltage_l3_v,


        -- ------------------------------------------------------------
        -- Current: A -> A
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_L1'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l1_a,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_L2'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l2_a,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_L3'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_l3_a,


        -- ------------------------------------------------------------
        -- Power factor: unitless
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'POWER_FACTOR_TOTAL'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS power_factor_total,


        -- ------------------------------------------------------------
        -- Frequency: Hz -> Hz
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'FREQUENCY'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS frequency_hz,


        -- ------------------------------------------------------------
        -- Current harmonic distortion: percent -> percent
        -- ------------------------------------------------------------

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_THD_L1'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l1_percent,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_THD_L2'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l2_percent,

        MAX(np.numeric_value) FILTER
        (
            WHERE np.logical_point = 'CURRENT_THD_L3'
              AND np.quality_code = 'GOOD'
        )::DOUBLE PRECISION AS current_thd_l3_percent,

        COUNT(*) FILTER
        (
            WHERE np.quality_code = 'GOOD'
              AND np.numeric_value IS NOT NULL
        ) AS populated_point_count,

        COUNT(*) FILTER
        (
            WHERE np.quality_code = 'INVALID_NUMERIC'
        ) AS invalid_point_count

    FROM telemetry.normalized_points np

    GROUP BY
        np.event_time,
        np.organization_id,
        np.site_id,
        np.gateway_id,
        np.device_id
)

SELECT *
FROM pivoted

-- Prevent creation of completely empty energy-domain rows.
WHERE populated_point_count > 0;
