/*
===============================================================================
27_device_profiles.sql

Purpose
-------
Defines reusable device profiles shared across all tenants.

A Device Profile describes a family of devices having identical telemetry
structure.

Examples
--------
Eniscope V4
Schneider PM5560
Schneider EM6400NG+
Siemens PAC3200
ABB M4M
BACnet HVAC Controller

Physical devices reference a profile instead of storing duplicate field mappings.

===============================================================================
*/

CREATE TABLE IF NOT EXISTS config.device_profiles (

    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    protocol_id UUID NOT NULL
        REFERENCES config.protocols(id),

    profile_code TEXT NOT NULL,

    manufacturer TEXT NOT NULL,

    model TEXT NOT NULL,

    firmware_version TEXT,

    profile_name TEXT NOT NULL,

    description TEXT,

    is_active BOOLEAN NOT NULL DEFAULT TRUE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_device_profile
        UNIQUE (
            protocol_id,
            manufacturer,
            model,
            firmware_version
        ),

    CONSTRAINT uq_device_profile_code
        UNIQUE (profile_code)

);

COMMENT ON TABLE config.device_profiles IS
'Reusable telemetry profile shared by multiple physical devices.';

COMMENT ON COLUMN config.device_profiles.protocol_id IS
'Communication protocol used by this profile.';

COMMENT ON COLUMN config.device_profiles.firmware_version IS
'Firmware version if telemetry structure changes between releases.';

COMMENT ON COLUMN config.device_profiles.profile_name IS
'Human-readable profile name.';

CREATE INDEX IF NOT EXISTS idx_device_profiles_protocol
ON config.device_profiles(protocol_id);

CREATE INDEX IF NOT EXISTS idx_device_profiles_active
ON config.device_profiles(is_active);
