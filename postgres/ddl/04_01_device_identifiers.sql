-- ============================================================================
-- File: 04_01_device_identifiers.sql
-- Purpose: Canonical external-identifier mapping for EMS devices.
--
-- Deployment requirements:
--   - Must run after 04_metadata.sql because this table references
--     metadata.devices(id).
--   - Must run before telemetry normalization views.
--
-- Architecture:
--   External identifiers such as MQTT UID, serial number, or MAC address are
--   mapped to the internal EMS device UUID.
--
-- Examples:
--   identifier_type  = 'MQTT_UID'
--   identifier_value = '80:34:28:16:09:eb:00:01'
-- ============================================================================

CREATE TABLE IF NOT EXISTS metadata.device_identifiers
(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    device_id UUID NOT NULL
        REFERENCES metadata.devices(id)
        ON DELETE CASCADE,

    identifier_type TEXT NOT NULL,

    identifier_value TEXT NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_device_identifier
        UNIQUE (identifier_type, identifier_value)
);


COMMENT ON TABLE metadata.device_identifiers IS
    'Maps external device identities such as MQTT UID, serial number and MAC address to internal EMS devices.';

COMMENT ON COLUMN metadata.device_identifiers.identifier_type IS
    'Identifier namespace such as MQTT_UID, SERIAL_NUMBER or MAC_ADDRESS.';


CREATE INDEX IF NOT EXISTS idx_device_identifiers_device
    ON metadata.device_identifiers (device_id);


-- The unique constraint already creates a supporting unique B-tree index for
-- (identifier_type, identifier_value), so a duplicate non-unique lookup index
-- is intentionally not created.
