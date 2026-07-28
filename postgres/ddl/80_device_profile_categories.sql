-- ============================================================================
-- File: 80_device_profile_categories.sql
-- Purpose:
--   Define the controlled many-to-many compatibility relationship between
--   telemetry payload profiles and physical device categories.
--
-- Design:
--   - One payload profile may support multiple device categories.
--   - One device category may use multiple payload profiles.
--   - Compatibility is explicit and declarative.
--   - Tenant-specific data is not stored in this table.
-- ============================================================================

CREATE TABLE IF NOT EXISTS config.device_profile_categories
(
    profile_id UUID NOT NULL
        REFERENCES config.device_profiles(id)
        ON DELETE CASCADE,

    device_category_id UUID NOT NULL
        REFERENCES config.device_categories(id)
        ON DELETE RESTRICT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT device_profile_categories_pkey
        PRIMARY KEY
        (
            profile_id,
            device_category_id
        )
);


COMMENT ON TABLE config.device_profile_categories IS
'Controlled compatibility mapping between telemetry payload profiles and physical device categories.';

COMMENT ON COLUMN config.device_profile_categories.profile_id IS
'Reusable telemetry payload profile.';

COMMENT ON COLUMN config.device_profile_categories.device_category_id IS
'Physical device category permitted to use the profile.';


CREATE INDEX IF NOT EXISTS idx_device_profile_categories_category
    ON config.device_profile_categories(device_category_id);
