-- ============================================================================
-- File:
--   66_environment_routing_contract.sql
--
-- Purpose:
--   Extend the environmental measurement contract and create the normalized
--   point routing view used by the incremental environment loader.
--
-- Source logical points:
--
--   ENV_TEMPERATURE          -> temperature_c
--   ENV_RELATIVE_HUMIDITY    -> humidity_percent
--   ENV_ILLUMINANCE_LUX      -> illuminance_lux
--   OCCUPANCY_ACTIVITY       -> occupancy_activity
--   DEVICE_BATTERY_VOLTAGE   -> battery_voltage_v
--
-- Generic-profile behavior:
--
--   Sensors may publish any subset of these optional fields. Missing fields
--   remain NULL in the resulting wide environmental row.
--
-- Routing scope:
--
--   Only devices assigned profile ENVIRONMENT_SENSOR_AIRSENSE_V1 are included.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Extend the destination table.
-- ----------------------------------------------------------------------------

ALTER TABLE telemetry.environment_measurements
ADD COLUMN IF NOT EXISTS illuminance_lux DOUBLE PRECISION;


ALTER TABLE telemetry.environment_measurements
ADD COLUMN IF NOT EXISTS occupancy_activity DOUBLE PRECISION;


COMMENT ON COLUMN telemetry.environment_measurements.illuminance_lux IS
'Ambient illuminance reported by the environmental sensor, expressed in lux.';


COMMENT ON COLUMN telemetry.environment_measurements.occupancy_activity IS
'Raw numeric PIR occupancy or motion activity. Vendor-specific semantics are preserved without threshold conversion.';


-- ----------------------------------------------------------------------------
-- 2. Add idempotency protection for one environmental row per device/time.
--
-- device_id is expected for normalized environmental telemetry. The partial
-- unique index avoids changing behavior for any future legacy rows where
-- device_id might be NULL.
-- ----------------------------------------------------------------------------

CREATE UNIQUE INDEX IF NOT EXISTS
uq_environment_measurements_received_device

ON telemetry.environment_measurements
(
    received_at,
    device_id
)

WHERE device_id IS NOT NULL;


-- ----------------------------------------------------------------------------
-- 3. Add query indexes for tenant/site/device time-range scans.
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS
idx_environment_measurements_org_site_time

ON telemetry.environment_measurements
(
    organization_id,
    site_id,
    received_at DESC
);


CREATE INDEX IF NOT EXISTS
idx_environment_measurements_device_time

ON telemetry.environment_measurements
(
    device_id,
    received_at DESC
);


-- ----------------------------------------------------------------------------
-- 4. Create the environmental routing view.
--
-- normalized_points is long-form:
--
--   event_time | device_id | logical_point | numeric_value
--
-- This view pivots those logical points into one wide environmental row per
-- device and event timestamp.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE VIEW telemetry.v_environment_measurements_route
AS

SELECT
    np.event_time
        AS received_at,

    np.event_time
        AS source_timestamp,

    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id,

    -- Environment sensors are not yet assigned to operational assets.
    NULL::UUID
        AS asset_id,

    NULL::SMALLINT
        AS measurement_interval_seconds,

    NULL::SMALLINT
        AS quality_code,

    FALSE
        AS is_estimated,

    MAX(np.numeric_value) FILTER
    (
        WHERE np.logical_point = 'ENV_TEMPERATURE'
    ) AS temperature_c,

    MAX(np.numeric_value) FILTER
    (
        WHERE np.logical_point = 'ENV_RELATIVE_HUMIDITY'
    ) AS humidity_percent,

    -- Not currently published by ENVIRONMENT_SENSOR_AIRSENSE_V1.
    NULL::DOUBLE PRECISION
        AS pressure_hpa,

    -- Not currently published by ENVIRONMENT_SENSOR_AIRSENSE_V1.
    NULL::DOUBLE PRECISION
        AS co2_ppm,

    -- Not currently published by ENVIRONMENT_SENSOR_AIRSENSE_V1.
    NULL::DOUBLE PRECISION
        AS voc_ppb,

    MAX(np.numeric_value) FILTER
    (
        WHERE np.logical_point = 'BATTERY_VOLTAGE'
           OR np.logical_point = 'DEVICE_BATTERY_VOLTAGE'
    ) AS battery_voltage_v,

    -- Not currently published by ENVIRONMENT_SENSOR_AIRSENSE_V1.
    NULL::DOUBLE PRECISION
        AS signal_strength_dbm,

    MAX(np.numeric_value) FILTER
    (
        WHERE np.logical_point = 'ENV_ILLUMINANCE_LUX'
    ) AS illuminance_lux,

    MAX(np.numeric_value) FILTER
    (
        WHERE np.logical_point = 'OCCUPANCY_ACTIVITY'
    ) AS occupancy_activity,

    NULL::BIGINT
        AS raw_archive_id

FROM telemetry.normalized_points np

JOIN metadata.devices d
  ON d.id = np.device_id

JOIN config.device_profiles dp
  ON dp.id = d.profile_id

WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'

  AND np.logical_point IN
  (
      'ENV_TEMPERATURE',
      'ENV_RELATIVE_HUMIDITY',
      'ENV_ILLUMINANCE_LUX',
      'OCCUPANCY_ACTIVITY',
      'DEVICE_BATTERY_VOLTAGE',
      'BATTERY_VOLTAGE'
  )

GROUP BY
    np.event_time,
    np.organization_id,
    np.site_id,
    np.gateway_id,
    np.device_id;


COMMENT ON VIEW telemetry.v_environment_measurements_route IS
'Wide environmental routing contract pivoted from normalized logical points for devices assigned ENVIRONMENT_SENSOR_AIRSENSE_V1.';
