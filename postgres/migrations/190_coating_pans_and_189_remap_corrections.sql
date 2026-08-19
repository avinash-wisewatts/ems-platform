-- ============================================================================
-- Migration 190
-- Two corrections found while verifying migration 189 against live data at
-- Meenaxy Pharma / Unit 2:
--
--   1. Migration 189's best-effort remap heuristic only recognized
--      '%pump%'/'%conveyor%'/'%sort%' in an asset's name and defaulted
--      everything else to 'Electric Motors (Standalone)'. That default
--      swallowed real equipment the new catalog has dedicated types for:
--        - 'Heater-P1-01/02/03' -> should be 'Heaters (Air/Duct/Space)',
--          the type migration 189 itself introduced but never matched
--          against.
--        - 'Shifter (P1-VST-01)' / 'Shifter (P2-VST-01)' -> 'Shifter' here
--          is read as 'Sifter' (vibro-sifter, a common pharma-floor
--          abbreviation/typo; 'VST' matches vibro-sifter tagging elsewhere
--          in this site's asset names) -> 'Sifters / Screeners'.
--      Only assets still sitting on the 'Electric Motors (Standalone)'
--      fallback are touched, so this can never override a classification a
--      human has since set deliberately.
--   2. 'Coating Pan (P1-CPN-01/02)' / 'Coating Pan (P2-CPN-01/02)' are
--      pharma tablet/sugar coating pans -- distinct, common pharma-floor
--      equipment that was never part of the original catalog-split scope
--      and had no dedicated type to land on (the previous default of
--      'Electric Motors (Standalone)' is defensible -- a coating pan is
--      motor-driven rotating-drum equipment -- but not a proper category).
--      Adds 'Coating Pans (Tablet/Sugar)' to the catalog, mapped to the same
--      pharma manufacturing sub-sectors as 'Fluid Bed Processors/Dryers'
--      (R&D Laboratories, Manufacturing Plants (Bulk/API/FDF)), and remaps
--      the 4 existing coating-pan assets onto it.
--
-- Idempotent: safe to run more than once against the same database.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- STEP A: add 'Coating Pans (Tablet/Sugar)' to the catalog (idempotent).
-- ----------------------------------------------------------------------------

INSERT INTO metadata.asset_types (name, description)
SELECT 'Coating Pans (Tablet/Sugar)', 'Rotating pan used for tablet or sugar coating in pharmaceutical manufacturing'
WHERE NOT EXISTS (
    SELECT 1 FROM metadata.asset_types existing
    WHERE lower(existing.name) = lower('Coating Pans (Tablet/Sugar)')
);

-- ----------------------------------------------------------------------------
-- STEP B: correct assets still on the 'Electric Motors (Standalone)'
-- fallback whose name identifies a more specific, cataloged type.
-- ----------------------------------------------------------------------------

WITH target_types AS (
    SELECT
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Electric Motors (Standalone)')) AS motor_id,
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Heaters (Air/Duct/Space)')) AS heater_id,
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Sifters / Screeners')) AS sifter_id,
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Coating Pans (Tablet/Sugar)')) AS coating_pan_id
)
UPDATE metadata.assets a
SET asset_type_id = CASE
        WHEN a.name ILIKE '%coating pan%' THEN target_types.coating_pan_id
        WHEN a.name ILIKE '%heater%' THEN target_types.heater_id
        WHEN a.name ILIKE '%shifter%' OR a.name ILIKE '%sifter%' THEN target_types.sifter_id
    END,
    updated_at = clock_timestamp()
FROM target_types
WHERE a.asset_type_id = target_types.motor_id
    AND (
        a.name ILIKE '%coating pan%'
        OR a.name ILIKE '%heater%'
        OR a.name ILIKE '%shifter%'
        OR a.name ILIKE '%sifter%'
    );

-- ----------------------------------------------------------------------------
-- STEP C: map 'Coating Pans (Tablet/Sugar)' to pharma manufacturing
-- sub-sectors, mirroring 'Fluid Bed Processors/Dryers' from migration 187.
-- ----------------------------------------------------------------------------

INSERT INTO metadata.sub_sector_asset_mapping (sub_sector_id, asset_type_id)
SELECT ss.id, at.id
FROM (VALUES
    ('Coating Pans (Tablet/Sugar)', 'R&D Laboratories'),
    ('Coating Pans (Tablet/Sugar)', 'Manufacturing Plants (Bulk/API/FDF)')
) AS requested(asset_type_name, sub_sector_name)
JOIN metadata.asset_types at ON lower(at.name) = lower(requested.asset_type_name)
JOIN metadata.sub_sectors ss ON lower(ss.name) = lower(requested.sub_sector_name)
ON CONFLICT DO NOTHING;

COMMIT;
