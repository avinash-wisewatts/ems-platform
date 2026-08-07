-- ============================================================================
-- File:
--   73_payload_profile_catalog_cleanup.sql
--
-- Purpose:
--   Rename payload profiles using a scalable domain/vendor/version convention.
--
-- Renames:
--
--   ENISCOPE_V4
--       -> ENERGY_METER_ENISCOPE_V1
--
--   ENVIRONMENT_SENSOR_V1
--       -> ENVIRONMENT_SENSOR_AIRSENSE_V1
--
-- Design:
--
--   Profiles describe vendor-specific payload contracts.
--   Logical points remain vendor-neutral.
--
--   Device assignments are preserved because metadata.devices references the
--   profile UUID, which is not changed.
--
--   All existing field mappings remain attached to the same profile UUID.
--
-- Naming convention:
--
--   <DOMAIN>_<DEVICE_CLASS>_<VENDOR_OR_MODEL>_<VERSION>
--
-- Examples:
--
--   ENERGY_METER_ENISCOPE_V1
--   ENERGY_METER_SCHNEIDER_V1
--   ENVIRONMENT_SENSOR_AIRSENSE_V1
--   WATER_METER_KROHNE_V1
-- ============================================================================


DO
$$
DECLARE
    v_energy_profile_id UUID;
    v_environment_profile_id UUID;
BEGIN
    -- ------------------------------------------------------------------------
    -- 1. Resolve the energy profile using either the old or final code.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_energy_profile_id
    FROM config.device_profiles
    WHERE profile_code IN
    (
        'ENISCOPE_V4',
        'ENERGY_METER_ENISCOPE_V1'
    )
    ORDER BY
        CASE
            WHEN profile_code = 'ENERGY_METER_ENISCOPE_V1' THEN 1
            ELSE 2
        END
    LIMIT 1;

    IF v_energy_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Energy payload profile was not found';
    END IF;


    -- ------------------------------------------------------------------------
    -- 2. Rename and clarify the energy payload profile.
    -- ------------------------------------------------------------------------

    UPDATE config.device_profiles
    SET
        profile_code =
            'ENERGY_METER_ENISCOPE_V1',

        profile_name =
            'Eniscope Energy Meter Payload V1',

        manufacturer =
            'Eniscope',

        model =
            'Virtual Gateway Energy Meter',

        description =
            'Eniscope energy-meter payload mapping into the vendor-neutral EMS electrical logical-point catalog.',

        is_active =
            TRUE,

        updated_at =
            now()

    WHERE id = v_energy_profile_id;


    -- ------------------------------------------------------------------------
    -- 3. Energy payload fields are optional.
    --
    -- A specific Eniscope payload may omit supported points. Present mapped
    -- points continue through normalization; absent points remain NULL in the
    -- energy measurement contract.
    -- ------------------------------------------------------------------------

    UPDATE config.profile_field_mapping
    SET is_required = FALSE
    WHERE profile_id = v_energy_profile_id;


    -- ------------------------------------------------------------------------
    -- 4. Resolve the environment profile using either old or final code.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_environment_profile_id
    FROM config.device_profiles
    WHERE profile_code IN
    (
        'ENVIRONMENT_SENSOR_V1',
        'ENVIRONMENT_SENSOR_AIRSENSE_V1'
    )
    ORDER BY
        CASE
            WHEN profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1' THEN 1
            ELSE 2
        END
    LIMIT 1;

    IF v_environment_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Environment payload profile was not found';
    END IF;


    -- ------------------------------------------------------------------------
    -- 5. Rename and clarify the Air Sense payload profile.
    -- ------------------------------------------------------------------------

    UPDATE config.device_profiles
    SET
        profile_code =
            'ENVIRONMENT_SENSOR_AIRSENSE_V1',

        profile_name =
            'Eniscope Air Sense Payload V1',

        manufacturer =
            'Eniscope',

        model =
            'Air Sense',

        description =
            'Eniscope Air Sense payload mapping for temperature, humidity, illuminance, PIR activity, and battery voltage.',

        is_active =
            TRUE,

        updated_at =
            now()

    WHERE id = v_environment_profile_id;


    -- ------------------------------------------------------------------------
    -- 6. Air Sense payload fields remain optional.
    -- ------------------------------------------------------------------------

    UPDATE config.profile_field_mapping
    SET is_required = FALSE
    WHERE profile_id = v_environment_profile_id;


    -- ------------------------------------------------------------------------
    -- 7. Validate final profile identities.
    -- ------------------------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM config.device_profiles
        WHERE id = v_energy_profile_id
          AND profile_code = 'ENERGY_METER_ENISCOPE_V1'
          AND is_active = TRUE
    )
    THEN
        RAISE EXCEPTION
            'Energy payload profile rename failed';
    END IF;


    IF NOT EXISTS
    (
        SELECT 1
        FROM config.device_profiles
        WHERE id = v_environment_profile_id
          AND profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
          AND is_active = TRUE
    )
    THEN
        RAISE EXCEPTION
            'Environment payload profile rename failed';
    END IF;


    -- ------------------------------------------------------------------------
    -- 8. Ensure no required mappings remain.
    -- ------------------------------------------------------------------------

    IF EXISTS
    (
        SELECT 1
        FROM config.profile_field_mapping
        WHERE profile_id IN
        (
            v_energy_profile_id,
            v_environment_profile_id
        )
          AND is_required = TRUE
    )
    THEN
        RAISE EXCEPTION
            'Required mappings remain after payload-profile cleanup';
    END IF;
END;
$$;


-- ----------------------------------------------------------------------------
-- 9. Update existing PostgreSQL views that hard-code either old profile code.
--
-- This retains each view object and its dependencies while replacing only the
-- profile-code literals in its definition.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_view RECORD;
    v_new_definition TEXT;
BEGIN
    FOR v_view IN
        SELECT
            schemaname,
            viewname,
            definition
        FROM pg_views
        WHERE definition LIKE '%ENISCOPE_V4%'
           OR definition LIKE '%ENVIRONMENT_SENSOR_V1%'
    LOOP
        v_new_definition :=
            replace
            (
                v_view.definition,
                '''ENISCOPE_V4''',
                '''ENERGY_METER_ENISCOPE_V1'''
            );

        v_new_definition :=
            replace
            (
                v_new_definition,
                '''ENVIRONMENT_SENSOR_V1''',
                '''ENVIRONMENT_SENSOR_AIRSENSE_V1'''
            );

        EXECUTE format
        (
            'CREATE OR REPLACE VIEW %I.%I AS %s',
            v_view.schemaname,
            v_view.viewname,
            v_new_definition
        );

        RAISE NOTICE
            'Updated profile-code references in %.%',
            v_view.schemaname,
            v_view.viewname;
    END LOOP;
END;
$$;


-- ----------------------------------------------------------------------------
-- 10. Final database-level stale-reference check.
-- ----------------------------------------------------------------------------

DO
$$
DECLARE
    v_stale_view_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_stale_view_count
    FROM pg_views
    WHERE definition LIKE '%ENISCOPE_V4%'
       OR definition LIKE '%ENVIRONMENT_SENSOR_V1%';

    IF v_stale_view_count <> 0 THEN
        RAISE EXCEPTION
            'Found % database views containing old profile codes',
            v_stale_view_count;
    END IF;
END;
$$;
