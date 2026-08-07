/*
===============================================================================
30_device_profile_code.sql

Purpose
-------
Adds a stable machine-readable profile code to each device profile.

This migration is intentionally separate from 27_device_profiles.sql because
migration 27 has already been executed.
===============================================================================
*/

ALTER TABLE config.device_profiles
ADD COLUMN IF NOT EXISTS profile_code TEXT;

UPDATE config.device_profiles
SET profile_code = UPPER(REPLACE(profile_name, ' ', '_'))
WHERE profile_code IS NULL;

ALTER TABLE config.device_profiles
ALTER COLUMN profile_code SET NOT NULL;

ALTER TABLE config.device_profiles
ADD CONSTRAINT uq_device_profile_code
UNIQUE (profile_code);

COMMENT ON COLUMN config.device_profiles.profile_code IS
'Stable machine-readable identifier for the device profile.';
