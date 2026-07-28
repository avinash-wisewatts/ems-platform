-- ============================================================================
-- 33_device_identifiers.sql
--
-- Device Identity Resolution Layer
--
-- Purpose:
--     Store external identifiers received from field devices.
--
-- Examples:
--     MQTT UID
--     Serial Number
--     MAC Address
--     Vendor Device ID
--
-- A physical device may have multiple identifiers.
--
-- ============================================================================


CREATE TABLE IF NOT EXISTS metadata.device_identifiers
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    device_id UUID NOT NULL,

    identifier_type TEXT NOT NULL,

    identifier_value TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT fk_device_identifier_device
        FOREIGN KEY (device_id)
        REFERENCES metadata.devices(id)
        ON DELETE CASCADE,

    CONSTRAINT uq_device_identifier
        UNIQUE (
            identifier_type,
            identifier_value
        )
);


CREATE INDEX IF NOT EXISTS idx_device_identifiers_device
ON metadata.device_identifiers(device_id);


CREATE INDEX IF NOT EXISTS idx_device_identifiers_lookup
ON metadata.device_identifiers(
    identifier_type,
    identifier_value
);


COMMENT ON TABLE metadata.device_identifiers IS
'External identifiers used to resolve incoming telemetry devices.';


COMMENT ON COLUMN metadata.device_identifiers.identifier_type IS
'Identifier namespace such as MQTT_UID, SERIAL_NUMBER, MAC_ADDRESS.';
