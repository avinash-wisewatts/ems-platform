-- ============================================================================
-- 28_01_eniscope_energy_profile.sql
--
-- Purpose:
--   Ensure the canonical reusable Eniscope energy-meter payload profile exists
--   on clean database deployments.
--
-- The detailed logical-point mappings and register semantics are completed by
-- the later Eniscope profile contract.
-- ============================================================================

DO
$$
DECLARE
    v_protocol_id UUID;
    v_profile_id UUID;
BEGIN
    SELECT id
    INTO v_protocol_id
    FROM config.protocols
    WHERE name = 'MQTT';

    IF v_protocol_id IS NULL THEN
        RAISE EXCEPTION
            'Cannot create ENERGY_METER_ENISCOPE_V1: canonical MQTT protocol was not found';
    END IF;

    SELECT id
    INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code IN (
        'ENERGY_METER_ENISCOPE_V1',
        'ENISCOPE_V4'
    )
    ORDER BY
        CASE
            WHEN profile_code = 'ENERGY_METER_ENISCOPE_V1' THEN 1
            ELSE 2
        END
    LIMIT 1;

    IF v_profile_id IS NULL THEN
        INSERT INTO config.device_profiles (
            protocol_id,
            profile_code,
            manufacturer,
            model,
            firmware_version,
            profile_name,
            description,
            is_active
        )
        VALUES (
            v_protocol_id,
            'ENERGY_METER_ENISCOPE_V1',
            'Eniscope',
            'Virtual Gateway Energy Meter',
            '1.0',
            'Eniscope Energy Meter Payload V1',
            'Reusable Eniscope electrical telemetry payload profile.',
            TRUE
        )
        RETURNING id INTO v_profile_id;
    ELSE
        UPDATE config.device_profiles
        SET
            protocol_id = v_protocol_id,
            profile_code = 'ENERGY_METER_ENISCOPE_V1',
            manufacturer = 'Eniscope',
            model = 'Virtual Gateway Energy Meter',
            profile_name = 'Eniscope Energy Meter Payload V1',
            description =
                'Reusable Eniscope electrical telemetry payload profile.',
            is_active = TRUE,
            updated_at = now()
        WHERE id = v_profile_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.device_profiles
        WHERE id = v_profile_id
          AND profile_code = 'ENERGY_METER_ENISCOPE_V1'
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Canonical Eniscope energy profile creation failed';
    END IF;
END;
$$;
