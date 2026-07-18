-- ============================================================================
-- Canonical device-profile assignment
--
-- Purpose:
--   Associates each physical device with the device profile used to interpret
--   its raw telemetry fields.
--
-- Canonical versus migration:
--   This file defines the final schema required by a fresh deployment.
--   postgres/migrations/29_device_profile_assignment.sql remains a legacy
--   upgrade migration for databases created before this relationship existed.
--
-- Ordering:
--   metadata.devices must already exist.
--   config.device_profiles must already exist.
-- ============================================================================

ALTER TABLE metadata.devices
    ADD COLUMN IF NOT EXISTS profile_id UUID;

-- PostgreSQL does not support ADD CONSTRAINT IF NOT EXISTS, so use a guarded
-- block to keep repeated canonical deployments idempotent.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'devices_profile_id_fkey'
          AND conrelid = 'metadata.devices'::regclass
    ) THEN
        ALTER TABLE metadata.devices
            ADD CONSTRAINT devices_profile_id_fkey
            FOREIGN KEY (profile_id)
            REFERENCES config.device_profiles(id);
    END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_devices_profile
    ON metadata.devices(profile_id);

COMMENT ON COLUMN metadata.devices.profile_id IS
'Reference to the device profile used to interpret telemetry from this device.';
