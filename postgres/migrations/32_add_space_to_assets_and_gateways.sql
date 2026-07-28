-- ============================================================================
-- Migration: Add optional physical-space placement
-- Purpose:
--   Link assets and gateways to metadata.spaces without duplicating
--   building_id and floor_id. Building and floor are derived through:
--
--       space -> floor -> building -> site
--
-- Notes:
--   - space_id is nullable because some assets and gateways may be outdoors,
--     site-wide, mobile, or onboarded before detailed location mapping.
--   - Devices inherit operational context from their gateway and/or linked asset.
-- ============================================================================

BEGIN;

ALTER TABLE metadata.assets
    ADD COLUMN IF NOT EXISTS space_id UUID;

ALTER TABLE metadata.gateways
    ADD COLUMN IF NOT EXISTS space_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'assets_space_id_fkey'
          AND conrelid = 'metadata.assets'::regclass
    ) THEN
        ALTER TABLE metadata.assets
            ADD CONSTRAINT assets_space_id_fkey
            FOREIGN KEY (space_id)
            REFERENCES metadata.spaces(id)
            ON DELETE SET NULL;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'gateways_space_id_fkey'
          AND conrelid = 'metadata.gateways'::regclass
    ) THEN
        ALTER TABLE metadata.gateways
            ADD CONSTRAINT gateways_space_id_fkey
            FOREIGN KEY (space_id)
            REFERENCES metadata.spaces(id)
            ON DELETE SET NULL;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_assets_space_id
    ON metadata.assets (space_id);

CREATE INDEX IF NOT EXISTS idx_gateways_space_id
    ON metadata.gateways (space_id);

COMMIT;
