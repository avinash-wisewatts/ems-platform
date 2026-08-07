-- ============================================================================
-- File:
--   44_split_eniscope_devices.sql
--
-- Purpose:
--   Correct the temporary proof-of-concept identity model in which five
--   independent Eniscope endpoints were assigned to one metadata device.
--
-- Result:
--
--   80:34:28:16:09:eb:00:01 -> Eniscope Energy Meter 001
--   80:34:28:16:09:eb:00:02 -> Eniscope Energy Meter 002
--   80:34:28:16:09:eb:00:03 -> Eniscope Energy Meter 003
--   80:34:28:16:09:eb:05:01 -> Eniscope Air Sense 001
--   80:34:28:16:09:eb:05:02 -> Eniscope Digital I/O 001
--
-- Profile assignment:
--
--   The three 00:* devices use ENERGY_METER_ENISCOPE_V1 because the current profile maps
--   energy telemetry.
--
--   The Air Sense and Digital I/O devices intentionally remain unprofiled.
--   Separate profiles will be created for those payload types later.
--
-- Idempotency:
--
--   Devices are located using external_id. Existing rows are updated rather
--   than duplicated, and MQTT identifiers are reassigned transactionally.
-- ============================================================================

DO
$$
DECLARE
    v_existing_device_id UUID :=
        '009c7759-3b65-46e7-8e87-3738df287ee4';

    v_organization_id UUID;
    v_gateway_id UUID;
    v_energy_profile_id UUID;

    v_energy_001_id UUID;
    v_energy_002_id UUID;
    v_energy_003_id UUID;
    v_air_sense_001_id UUID;
    v_digital_001_id UUID;
BEGIN
    -- ------------------------------------------------------------------------
    -- Read tenant and gateway identity from the existing proof-of-concept
    -- device so the new devices remain in the same tenant and gateway.
    -- ------------------------------------------------------------------------

    SELECT
        organization_id,
        gateway_id
    INTO
        v_organization_id,
        v_gateway_id
    FROM metadata.devices
    WHERE id = v_existing_device_id;

    IF v_organization_id IS NULL THEN
        RAISE EXCEPTION
            'Existing Eniscope demo device % was not found',
            v_existing_device_id;
    END IF;


    SELECT id
    INTO v_energy_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'
      AND is_active = TRUE
    ORDER BY created_at
    LIMIT 1;

    IF v_energy_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Active device profile ENERGY_METER_ENISCOPE_V1 was not found';
    END IF;


    -- ------------------------------------------------------------------------
    -- 00:01 keeps the existing device UUID so references to the original demo
    -- device remain valid.
    -- ------------------------------------------------------------------------

    UPDATE metadata.devices
    SET
        name = 'Eniscope Energy Meter 001',
        external_id = 'ENI-ENERGY-001',
        serial_number = '80:34:28:16:09:eb:00:01',
        protocol = 'MQTT',
        profile_id = v_energy_profile_id,
        updated_at = now()
    WHERE id = v_existing_device_id;

    v_energy_001_id := v_existing_device_id;


    -- ------------------------------------------------------------------------
    -- Create or update Energy Meter 002.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_energy_002_id
    FROM metadata.devices
    WHERE organization_id = v_organization_id
      AND external_id = 'ENI-ENERGY-002'
    ORDER BY created_at
    LIMIT 1;

    IF v_energy_002_id IS NULL THEN
        INSERT INTO metadata.devices
        (
            organization_id,
            gateway_id,
            name,
            external_id,
            serial_number,
            protocol,
            profile_id
        )
        VALUES
        (
            v_organization_id,
            v_gateway_id,
            'Eniscope Energy Meter 002',
            'ENI-ENERGY-002',
            '80:34:28:16:09:eb:00:02',
            'MQTT',
            v_energy_profile_id
        )
        RETURNING id INTO v_energy_002_id;
    ELSE
        UPDATE metadata.devices
        SET
            gateway_id = v_gateway_id,
            name = 'Eniscope Energy Meter 002',
            serial_number = '80:34:28:16:09:eb:00:02',
            protocol = 'MQTT',
            profile_id = v_energy_profile_id,
            updated_at = now()
        WHERE id = v_energy_002_id;
    END IF;


    -- ------------------------------------------------------------------------
    -- Create or update Energy Meter 003.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_energy_003_id
    FROM metadata.devices
    WHERE organization_id = v_organization_id
      AND external_id = 'ENI-ENERGY-003'
    ORDER BY created_at
    LIMIT 1;

    IF v_energy_003_id IS NULL THEN
        INSERT INTO metadata.devices
        (
            organization_id,
            gateway_id,
            name,
            external_id,
            serial_number,
            protocol,
            profile_id
        )
        VALUES
        (
            v_organization_id,
            v_gateway_id,
            'Eniscope Energy Meter 003',
            'ENI-ENERGY-003',
            '80:34:28:16:09:eb:00:03',
            'MQTT',
            v_energy_profile_id
        )
        RETURNING id INTO v_energy_003_id;
    ELSE
        UPDATE metadata.devices
        SET
            gateway_id = v_gateway_id,
            name = 'Eniscope Energy Meter 003',
            serial_number = '80:34:28:16:09:eb:00:03',
            protocol = 'MQTT',
            profile_id = v_energy_profile_id,
            updated_at = now()
        WHERE id = v_energy_003_id;
    END IF;


    -- ------------------------------------------------------------------------
    -- Create or update Air Sense 001.
    --
    -- profile_id remains NULL until an environmental profile is defined.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_air_sense_001_id
    FROM metadata.devices
    WHERE organization_id = v_organization_id
      AND external_id = 'ENI-AIRSENSE-001'
    ORDER BY created_at
    LIMIT 1;

    IF v_air_sense_001_id IS NULL THEN
        INSERT INTO metadata.devices
        (
            organization_id,
            gateway_id,
            name,
            external_id,
            serial_number,
            protocol,
            profile_id
        )
        VALUES
        (
            v_organization_id,
            v_gateway_id,
            'Eniscope Air Sense 001',
            'ENI-AIRSENSE-001',
            '80:34:28:16:09:eb:05:01',
            'MQTT',
            NULL
        )
        RETURNING id INTO v_air_sense_001_id;
    ELSE
        UPDATE metadata.devices
        SET
            gateway_id = v_gateway_id,
            name = 'Eniscope Air Sense 001',
            serial_number = '80:34:28:16:09:eb:05:01',
            protocol = 'MQTT',
            profile_id = NULL,
            updated_at = now()
        WHERE id = v_air_sense_001_id;
    END IF;


    -- ------------------------------------------------------------------------
    -- Create or update Digital I/O 001.
    --
    -- profile_id remains NULL until a digital-I/O profile is defined.
    -- ------------------------------------------------------------------------

    SELECT id
    INTO v_digital_001_id
    FROM metadata.devices
    WHERE organization_id = v_organization_id
      AND external_id = 'ENI-DIGITAL-001'
    ORDER BY created_at
    LIMIT 1;

    IF v_digital_001_id IS NULL THEN
        INSERT INTO metadata.devices
        (
            organization_id,
            gateway_id,
            name,
            external_id,
            serial_number,
            protocol,
            profile_id
        )
        VALUES
        (
            v_organization_id,
            v_gateway_id,
            'Eniscope Digital I/O 001',
            'ENI-DIGITAL-001',
            '80:34:28:16:09:eb:05:02',
            'MQTT',
            NULL
        )
        RETURNING id INTO v_digital_001_id;
    ELSE
        UPDATE metadata.devices
        SET
            gateway_id = v_gateway_id,
            name = 'Eniscope Digital I/O 001',
            serial_number = '80:34:28:16:09:eb:05:02',
            protocol = 'MQTT',
            profile_id = NULL,
            updated_at = now()
        WHERE id = v_digital_001_id;
    END IF;


    -- ------------------------------------------------------------------------
    -- Move each MQTT UID to its correct metadata device.
    --
    -- The existing UNIQUE(identifier_type, identifier_value) constraint ensures
    -- that each MQTT endpoint can belong to only one metadata device.
    -- ------------------------------------------------------------------------

    UPDATE metadata.device_identifiers
    SET device_id = v_energy_001_id
    WHERE identifier_type = 'MQTT_UID'
      AND LOWER(identifier_value) =
          '80:34:28:16:09:eb:00:01';

    UPDATE metadata.device_identifiers
    SET device_id = v_energy_002_id
    WHERE identifier_type = 'MQTT_UID'
      AND LOWER(identifier_value) =
          '80:34:28:16:09:eb:00:02';

    UPDATE metadata.device_identifiers
    SET device_id = v_energy_003_id
    WHERE identifier_type = 'MQTT_UID'
      AND LOWER(identifier_value) =
          '80:34:28:16:09:eb:00:03';

    UPDATE metadata.device_identifiers
    SET device_id = v_air_sense_001_id
    WHERE identifier_type = 'MQTT_UID'
      AND LOWER(identifier_value) =
          '80:34:28:16:09:eb:05:01';

    UPDATE metadata.device_identifiers
    SET device_id = v_digital_001_id
    WHERE identifier_type = 'MQTT_UID'
      AND LOWER(identifier_value) =
          '80:34:28:16:09:eb:05:02';


    -- ------------------------------------------------------------------------
    -- Fail the transaction if any expected UID is missing.
    -- ------------------------------------------------------------------------

    IF
    (
        SELECT COUNT(*)
        FROM metadata.device_identifiers
        WHERE identifier_type = 'MQTT_UID'
          AND LOWER(identifier_value) IN
          (
              '80:34:28:16:09:eb:00:01',
              '80:34:28:16:09:eb:00:02',
              '80:34:28:16:09:eb:00:03',
              '80:34:28:16:09:eb:05:01',
              '80:34:28:16:09:eb:05:02'
          )
    ) <> 5
    THEN
        RAISE EXCEPTION
            'One or more expected Eniscope MQTT identifiers are missing';
    END IF;
END;
$$;
