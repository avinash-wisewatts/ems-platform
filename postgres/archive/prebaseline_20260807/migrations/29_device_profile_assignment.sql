/*
===============================================================================
29_device_profile_assignment.sql

Purpose
-------
Associates each physical device with a Device Profile.

A Device Profile defines how telemetry fields from that device are interpreted.
Multiple devices can reference the same profile.

===============================================================================
*/

ALTER TABLE metadata.devices
ADD COLUMN IF NOT EXISTS profile_id UUID;

ALTER TABLE metadata.devices
ADD CONSTRAINT devices_profile_id_fkey
FOREIGN KEY (profile_id)
REFERENCES config.device_profiles(id);

CREATE INDEX IF NOT EXISTS idx_devices_profile
ON metadata.devices(profile_id);

COMMENT ON COLUMN metadata.devices.profile_id IS
'Reference to the device profile used to interpret telemetry from this device.';
