-- ============================================================================
-- File: 77_asset_and_device_catalog_cleanup.sql
-- Purpose:
--   Correct the separation between operational asset types and telemetry
--   device categories.
--
-- Production guarantees:
--   1. Existing asset references are preserved.
--   2. Duplicate asset types are consolidated before deletion.
--   3. Instrumentation types are removed only when no assets reference them.
--   4. Future duplicate asset-type names are prevented case-insensitively.
--   5. Device categories are expanded idempotently.
-- ============================================================================

BEGIN;


-- ============================================================================
-- 1. BLOCK UNSAFE REMOVAL OF DEVICE-LIKE ASSET TYPES
-- ============================================================================
--
-- These entries represent telemetry devices, not operational assets.
-- The migration intentionally refuses to continue if any asset currently
-- references one of them. This prevents accidental reclassification.

DO $$
DECLARE
    v_referenced_count BIGINT;
BEGIN
    SELECT COUNT(*)
    INTO v_referenced_count
    FROM metadata.assets a
    JOIN metadata.asset_types at
      ON at.id = a.asset_type_id
    WHERE lower(at.name) IN
    (
        'energy meter',
        'flow meter',
        'pressure sensor',
        'temperature sensor'
    );

    IF v_referenced_count > 0 THEN
        RAISE EXCEPTION
            'Cannot remove device-like asset types: % assets still reference them.',
            v_referenced_count;
    END IF;
END;
$$;


-- ============================================================================
-- 2. CONSOLIDATE DUPLICATE OPERATIONAL ASSET TYPES
-- ============================================================================
--
-- Canonical-row selection:
--   1. Prefer the row referenced by the greatest number of assets.
--   2. Use UUID ordering as a deterministic tie-breaker.
--
-- Every asset is first redirected to the canonical row. Duplicate rows are
-- deleted only after all references have been moved.

CREATE TEMP TABLE asset_type_canonical_map
ON COMMIT DROP
AS
WITH usage_counts AS
(
    SELECT
        at.id,
        at.name,
        lower(at.name) AS normalized_name,
        COUNT(a.id) AS asset_count
    FROM metadata.asset_types at
    LEFT JOIN metadata.assets a
      ON a.asset_type_id = at.id
    GROUP BY
        at.id,
        at.name
),
ranked AS
(
    SELECT
        id,
        normalized_name,
        asset_count,
        FIRST_VALUE(id) OVER
        (
            PARTITION BY normalized_name
            ORDER BY
                asset_count DESC,
                id
        ) AS canonical_id
    FROM usage_counts
)
SELECT
    id AS duplicate_id,
    canonical_id
FROM ranked
WHERE id <> canonical_id;


UPDATE metadata.assets a
SET
    asset_type_id = m.canonical_id,
    updated_at = now()
FROM asset_type_canonical_map m
WHERE a.asset_type_id = m.duplicate_id;


DELETE FROM metadata.asset_types at
USING asset_type_canonical_map m
WHERE at.id = m.duplicate_id;


-- ============================================================================
-- 3. REMOVE DEVICE-LIKE ENTRIES FROM ASSET TYPES
-- ============================================================================
--
-- Asset types represent monitored operational equipment such as chillers,
-- pumps, AHUs, boilers, and cooling towers.
--
-- Meters and sensors belong in config.device_categories.

DELETE FROM metadata.asset_types
WHERE lower(name) IN
(
    'energy meter',
    'flow meter',
    'pressure sensor',
    'temperature sensor'
);


-- ============================================================================
-- 4. PREVENT FUTURE DUPLICATE ASSET TYPES
-- ============================================================================
--
-- The functional unique index prevents duplicates that differ only by case,
-- for example "Chiller", "CHILLER", or "chiller".

CREATE UNIQUE INDEX IF NOT EXISTS asset_types_name_ci_uq
    ON metadata.asset_types (lower(name));


-- ============================================================================
-- 5. EXPAND THE DEVICE CATEGORY CATALOG
-- ============================================================================
--
-- These categories describe physical telemetry-producing devices.

INSERT INTO config.device_categories
(
    name,
    description
)
VALUES
(
    'Flow Meter',
    'Fluid flow measurement device'
),
(
    'Pressure Sensor',
    'Pressure measurement device'
),
(
    'Temperature Sensor',
    'Dedicated temperature measurement device'
)
ON CONFLICT (name)
DO UPDATE
SET description = EXCLUDED.description;


COMMIT;
