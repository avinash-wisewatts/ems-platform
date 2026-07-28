-- ============================================================================
-- Asset metering requirement contract
--
-- Purpose:
--   Declares how each operational asset is expected to obtain energy-meter
--   coverage.
--
-- Allowed policies:
--
--   DIRECT_METER_REQUIRED
--       The asset itself must have a PRIMARY_METER relationship.
--
--   DESCENDANT_COVERAGE_ALLOWED
--       The asset may be covered by meters attached to assets below it in the
--       functional asset hierarchy.
--
--   NOT_REQUIRED
--       The asset is intentionally excluded from energy-meter coverage.
--
-- Design decisions:
--   1. The field is mandatory.
--   2. No database default is retained.
--   3. New asset creation must choose a policy explicitly.
--   4. Existing pre-production/test rows are assigned NOT_REQUIRED only as a
--      one-time migration compatibility action.
-- ============================================================================

BEGIN;

ALTER TABLE metadata.assets
    ADD COLUMN IF NOT EXISTS metering_requirement TEXT;

-- Existing rows predate the production metering policy. Assigning
-- NOT_REQUIRED here prevents the migration from guessing that dummy or legacy
-- assets require direct or descendant metering.
UPDATE metadata.assets
SET metering_requirement = 'NOT_REQUIRED'
WHERE metering_requirement IS NULL;

ALTER TABLE metadata.assets
    ALTER COLUMN metering_requirement SET NOT NULL;

ALTER TABLE metadata.assets
    DROP CONSTRAINT IF EXISTS assets_metering_requirement_ck;

ALTER TABLE metadata.assets
    ADD CONSTRAINT assets_metering_requirement_ck
    CHECK
    (
        metering_requirement IN
        (
            'DIRECT_METER_REQUIRED',
            'DESCENDANT_COVERAGE_ALLOWED',
            'NOT_REQUIRED'
        )
    );

COMMENT ON COLUMN metadata.assets.metering_requirement IS
'Defines required energy-meter coverage: DIRECT_METER_REQUIRED, '
'DESCENDANT_COVERAGE_ALLOWED, or NOT_REQUIRED. New assets must select the '
'value explicitly; there is no persistent database default.';

COMMIT;
