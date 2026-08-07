-- ============================================================================
-- File: 78_device_model_category.sql
-- Purpose:
--   Replace uncontrolled metadata.device_models.device_type text with a
--   governed foreign-key relationship to config.device_categories.
--
-- Compatibility:
--   - device_type remains temporarily available for older code.
--   - device_category_id becomes the authoritative category reference.
--   - existing device-type values are preserved and reconciled.
--
-- Production guarantees:
--   1. Existing device models are retained.
--   2. Existing free-text categories are inserted into the controlled catalog
--      when they do not already exist.
--   3. Every device model receives a valid device_category_id.
--   4. Duplicate vendor/model definitions are prevented case-insensitively.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. ADD THE CONTROLLED CATEGORY REFERENCE
-- ============================================================================

ALTER TABLE metadata.device_models
    ADD COLUMN IF NOT EXISTS device_category_id UUID;


-- ============================================================================
-- 2. PRESERVE ANY EXISTING FREE-TEXT DEVICE TYPES
-- ============================================================================
--
-- Existing device_type values may include categories created before the
-- controlled catalog was enforced. Insert them into config.device_categories
-- before backfilling the foreign key.

INSERT INTO config.device_categories
(
    name,
    description
)
SELECT DISTINCT
    btrim(dm.device_type) AS name,
    'Migrated from metadata.device_models.device_type'
FROM metadata.device_models dm
WHERE NULLIF(btrim(dm.device_type), '') IS NOT NULL
ON CONFLICT (name)
DO NOTHING;


-- ============================================================================
-- 3. BACKFILL DEVICE CATEGORY IDS
-- ============================================================================

UPDATE metadata.device_models dm
SET device_category_id = dc.id
FROM config.device_categories dc
WHERE dm.device_category_id IS NULL
  AND NULLIF(btrim(dm.device_type), '') IS NOT NULL
  AND lower(dc.name) = lower(btrim(dm.device_type));


-- ============================================================================
-- 4. REFUSE TO CONTINUE IF ANY MODEL CANNOT BE CLASSIFIED
-- ============================================================================

DO $$
DECLARE
    v_unclassified_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_unclassified_count
    FROM metadata.device_models
    WHERE device_category_id IS NULL;

    IF v_unclassified_count > 0 THEN
        RAISE EXCEPTION
            'Cannot enforce device categories: % device models remain unclassified.',
            v_unclassified_count;
    END IF;
END;
$$;


-- ============================================================================
-- 5. ENFORCE THE FOREIGN KEY AND REQUIRED CATEGORY
-- ============================================================================

DO $$
BEGIN
    IF NOT EXISTS
    (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'device_models_device_category_id_fkey'
          AND conrelid = 'metadata.device_models'::regclass
    )
    THEN
        ALTER TABLE metadata.device_models
            ADD CONSTRAINT device_models_device_category_id_fkey
            FOREIGN KEY (device_category_id)
            REFERENCES config.device_categories(id);
    END IF;
END;
$$;


ALTER TABLE metadata.device_models
    ALTER COLUMN device_category_id SET NOT NULL;


-- ============================================================================
-- 6. SYNCHRONIZE THE LEGACY TEXT COLUMN
-- ============================================================================
--
-- device_type remains temporarily for compatibility. Its value is normalized
-- to the canonical category name so old readers receive consistent data.

UPDATE metadata.device_models dm
SET device_type = dc.name
FROM config.device_categories dc
WHERE dc.id = dm.device_category_id
  AND dm.device_type IS DISTINCT FROM dc.name;


-- ============================================================================
-- 7. PREVENT DUPLICATE DEVICE MODELS
-- ============================================================================
--
-- Vendor may be null, so COALESCE is used to create one stable uniqueness
-- boundary for vendor/model combinations.

CREATE UNIQUE INDEX IF NOT EXISTS device_models_vendor_model_ci_uq
    ON metadata.device_models
    (
        lower(COALESCE(vendor, '')),
        lower(model)
    );


COMMIT;
