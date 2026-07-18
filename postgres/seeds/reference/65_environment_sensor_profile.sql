-- ============================================================================
-- File:
--   65_environment_sensor_profile.sql
--
-- Purpose:
--   Create a reusable generic environment sensor profile and its optional raw
--   field mappings.
--
-- Classification:
--   Canonical reference data. This file does not assign the profile to any
--   tenant-specific or environment-specific physical device.
--
-- Profile:
--
--   ENVIRONMENT_SENSOR_AIRSENSE_V1
--
-- Optional raw-field mappings:
--
--   T1   -> ENV_TEMPERATURE
--   RH   -> ENV_RELATIVE_HUMIDITY
--   LL   -> ENV_ILLUMINANCE_LUX
--   PIR  -> OCCUPANCY_ACTIVITY
--   Vbat -> DEVICE_BATTERY_VOLTAGE
--
-- Compatibility:
--
--   Sensors may publish any subset of these mapped fields.
--
--   Because every mapping is optional:
--
--     - Missing fields do not fail normalization.
--     - Present mapped fields are normalized.
--     - Unmapped fields are ignored.
--
--   A sensor using different raw names requires additional alias mappings or a
--   separate profile, depending on vendor semantics.
-- ============================================================================

DO
$$
DECLARE
    v_protocol_id UUID;
    v_profile_id UUID;
BEGIN
    -- Resolve MQTT directly from the canonical protocol catalog.
    SELECT id
    INTO v_protocol_id
    FROM config.protocols
    WHERE name = 'MQTT';

    IF v_protocol_id IS NULL THEN
        RAISE EXCEPTION
            'Cannot create ENVIRONMENT_SENSOR_AIRSENSE_V1: canonical MQTT protocol was not found';
    END IF;


    -- ------------------------------------------------------------------------
    -- 1. Create or update the generic environment sensor profile.
    -- ------------------------------------------------------------------------

    INSERT INTO config.device_profiles
    (
        protocol_id,
        manufacturer,
        model,
        firmware_version,
        profile_name,
        description,
        is_active,
        profile_code
    )
    VALUES
    (
        v_protocol_id,
        'Generic',
        'Environment Sensor',
        '1.0',
        'Environment Sensor Profile V1',
        'Generic optional-field profile for temperature, humidity, illuminance, occupancy activity, and battery voltage.',
        TRUE,
        'ENVIRONMENT_SENSOR_AIRSENSE_V1'
    )

    ON CONFLICT (profile_code)
    DO UPDATE
    SET
        protocol_id = EXCLUDED.protocol_id,
        manufacturer = EXCLUDED.manufacturer,
        model = EXCLUDED.model,
        firmware_version = EXCLUDED.firmware_version,
        profile_name = EXCLUDED.profile_name,
        description = EXCLUDED.description,
        is_active = TRUE,
        updated_at = now()

    RETURNING id
    INTO v_profile_id;


    -- ------------------------------------------------------------------------
    -- 2. T1 -> ENV_TEMPERATURE.
    -- ------------------------------------------------------------------------

    INSERT INTO config.profile_field_mapping
    (
        profile_id,
        raw_field_name,
        logical_point_id,
        json_path,
        transform_expression,
        is_required,
        display_order
    )
    SELECT
        v_profile_id,
        'T1',
        lp.id,
        NULL,
        NULL,
        FALSE,
        10
    FROM metadata.logical_points lp
    WHERE lp.name = 'ENV_TEMPERATURE'

    ON CONFLICT
    (
        profile_id,
        raw_field_name
    )
    DO UPDATE
    SET
        logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;


    -- ------------------------------------------------------------------------
    -- 3. RH -> ENV_RELATIVE_HUMIDITY.
    -- ------------------------------------------------------------------------

    INSERT INTO config.profile_field_mapping
    (
        profile_id,
        raw_field_name,
        logical_point_id,
        json_path,
        transform_expression,
        is_required,
        display_order
    )
    SELECT
        v_profile_id,
        'RH',
        lp.id,
        NULL,
        NULL,
        FALSE,
        20
    FROM metadata.logical_points lp
    WHERE lp.name = 'ENV_RELATIVE_HUMIDITY'

    ON CONFLICT
    (
        profile_id,
        raw_field_name
    )
    DO UPDATE
    SET
        logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;


    -- ------------------------------------------------------------------------
    -- 4. LL -> ENV_ILLUMINANCE_LUX.
    -- ------------------------------------------------------------------------

    INSERT INTO config.profile_field_mapping
    (
        profile_id,
        raw_field_name,
        logical_point_id,
        json_path,
        transform_expression,
        is_required,
        display_order
    )
    SELECT
        v_profile_id,
        'LL',
        lp.id,
        NULL,
        NULL,
        FALSE,
        30
    FROM metadata.logical_points lp
    WHERE lp.name = 'ENV_ILLUMINANCE_LUX'

    ON CONFLICT
    (
        profile_id,
        raw_field_name
    )
    DO UPDATE
    SET
        logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;


    -- ------------------------------------------------------------------------
    -- 5. PIR -> OCCUPANCY_ACTIVITY.
    -- ------------------------------------------------------------------------

    INSERT INTO config.profile_field_mapping
    (
        profile_id,
        raw_field_name,
        logical_point_id,
        json_path,
        transform_expression,
        is_required,
        display_order
    )
    SELECT
        v_profile_id,
        'PIR',
        lp.id,
        NULL,
        NULL,
        FALSE,
        40
    FROM metadata.logical_points lp
    WHERE lp.name = 'OCCUPANCY_ACTIVITY'

    ON CONFLICT
    (
        profile_id,
        raw_field_name
    )
    DO UPDATE
    SET
        logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;


    -- ------------------------------------------------------------------------
    -- 6. Vbat -> DEVICE_BATTERY_VOLTAGE.
    -- ------------------------------------------------------------------------

    INSERT INTO config.profile_field_mapping
    (
        profile_id,
        raw_field_name,
        logical_point_id,
        json_path,
        transform_expression,
        is_required,
        display_order
    )
    SELECT
        v_profile_id,
        'Vbat',
        lp.id,
        NULL,
        NULL,
        FALSE,
        50
    FROM metadata.logical_points lp
    WHERE lp.name = 'DEVICE_BATTERY_VOLTAGE'

    ON CONFLICT
    (
        profile_id,
        raw_field_name
    )
    DO UPDATE
    SET
        logical_point_id = EXCLUDED.logical_point_id,
        json_path = EXCLUDED.json_path,
        transform_expression = EXCLUDED.transform_expression,
        is_required = FALSE,
        display_order = EXCLUDED.display_order;


    -- ------------------------------------------------------------------------
    -- 7. Validate the canonical optional field mappings.
    -- ------------------------------------------------------------------------

    IF
    (
        SELECT COUNT(*)
        FROM config.profile_field_mapping pfm
        WHERE pfm.profile_id = v_profile_id
          AND pfm.raw_field_name IN
          (
              'T1',
              'RH',
              'LL',
              'PIR',
              'Vbat'
          )
          AND pfm.is_required = FALSE
    ) <> 5
    THEN
        RAISE EXCEPTION
            'Expected 5 optional environment field mappings';
    END IF;
END;
$$;
