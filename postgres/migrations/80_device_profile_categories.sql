-- ============================================================================
-- File: 80_device_profile_categories.sql
-- Purpose:
--   Introduce controlled compatibility between device profiles and physical
--   device categories.
--
-- Production guarantees:
--   1. Existing profiles and devices are preserved.
--   2. Compatibility mappings are idempotent.
--   3. Every currently assigned device/profile combination must be compatible.
--   4. Profile deletion removes only its compatibility mappings.
--   5. Device categories cannot be deleted while compatibility mappings exist.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. CREATE THE CONTROLLED COMPATIBILITY TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.device_profile_categories
(
    profile_id UUID NOT NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    device_category_id UUID NOT NULL
        REFERENCES config.device_categories(id)
        ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT device_profile_categories_pkey
        PRIMARY KEY
        (
            profile_id,
            device_category_id
        )
);


COMMENT ON TABLE config.device_profile_categories IS
'Controlled compatibility mapping between telemetry payload profiles and physical device categories.';

COMMENT ON COLUMN config.device_profile_categories.profile_id IS
'Reusable telemetry payload profile.';

COMMENT ON COLUMN config.device_profile_categories.device_category_id IS
'Physical device category permitted to use the profile.';


CREATE INDEX IF NOT EXISTS idx_device_profile_categories_category
    ON config.device_profile_categories(device_category_id);


-- ============================================================================
-- 2. SEED ENERGY-METER PROFILE COMPATIBILITY
-- ============================================================================

INSERT INTO config.device_profile_categories
(
    profile_id,
    device_category_id
)
SELECT
    dp.id,
    dc.id
FROM config.device_profiles dp
JOIN config.device_categories dc
  ON dc.name = 'Energy Meter'
WHERE dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
ON CONFLICT
(
    profile_id,
    device_category_id
)
DO NOTHING;


-- ============================================================================
-- 3. SEED ENVIRONMENT-PROFILE COMPATIBILITY
-- ============================================================================
--
-- The generic environment profile contains optional mappings. It may therefore
-- support a full environmental sensor or a dedicated temperature sensor.

INSERT INTO config.device_profile_categories
(
    profile_id,
    device_category_id
)
SELECT
    dp.id,
    dc.id
FROM config.device_profiles dp
JOIN config.device_categories dc
  ON dc.name IN
  (
      'Environmental Sensor',
      'Temperature Sensor'
  )
WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
ON CONFLICT
(
    profile_id,
    device_category_id
)
DO NOTHING;


-- ============================================================================
-- 4. VERIFY THAT REQUIRED CATALOG RECORDS WERE FOUND
-- ============================================================================

DO
$$
DECLARE
    v_expected_mapping_count INTEGER := 3;
    v_actual_mapping_count   INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_actual_mapping_count
    FROM config.device_profile_categories dpc
    JOIN config.device_profiles dp
      ON dp.id = dpc.profile_id
    JOIN config.device_categories dc
      ON dc.id = dpc.device_category_id
    WHERE
    (
        dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'
        AND dc.name = 'Energy Meter'
    )
    OR
    (
        dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
        AND dc.name IN
        (
            'Environmental Sensor',
            'Temperature Sensor'
        )
    );

    IF v_actual_mapping_count <> v_expected_mapping_count THEN
        RAISE EXCEPTION
            'Expected % profile-category mappings, but found %',
            v_expected_mapping_count,
            v_actual_mapping_count;
    END IF;
END;
$$;


-- ============================================================================
-- 5. VERIFY CURRENT DEVICE ASSIGNMENTS
-- ============================================================================
--
-- Refuse migration if any existing device has a profile that is incompatible
-- with the category of its device model.

DO
$$
DECLARE
    v_incompatible_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_incompatible_count
    FROM metadata.devices d
    JOIN metadata.device_models dm
      ON dm.id = d.device_model_id
    WHERE d.profile_id IS NOT NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM config.device_profile_categories dpc
          WHERE dpc.profile_id = d.profile_id
            AND dpc.device_category_id = dm.device_category_id
      );

    IF v_incompatible_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce profile compatibility: % existing device assignments are incompatible',
            v_incompatible_count;
    END IF;
END;
$$;


COMMIT;
