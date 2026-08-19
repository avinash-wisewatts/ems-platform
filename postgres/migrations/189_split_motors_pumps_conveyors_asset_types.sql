-- ============================================================================
-- Migration 189
-- Split the generic 'Motors/Pumps/Conveyors' asset type (introduced in
-- migration 187) into three discrete, independently-trackable asset types,
-- and add two new asset types to the catalog:
--
--   Replacing 'Motors/Pumps/Conveyors' with:
--     1. Electric Motors (Standalone)
--     2. Pumps (Water/Utility/Process)
--     3. Conveyors & Sorting Lines
--
--   Newly added to the catalog:
--     4. Heaters (Air/Duct/Space)
--     5. Sifters / Screeners
--
-- STEP A: insert the 5 new asset types (idempotent, by case-insensitive
--   name, same pattern as migration 187).
-- STEP B: remap metadata.assets off of 'Motors/Pumps/Conveyors' before it is
--   deleted. There is no reliable structured signal (no separate
--   motor/pump/conveyor sub-type column) to split existing rows by, so this
--   uses a best-effort heuristic on the asset name:
--     name ILIKE '%conveyor%' or '%sort%'  -> Conveyors & Sorting Lines
--     name ILIKE '%pump%'                  -> Pumps (Water/Utility/Process)
--     everything else (including '%motor%')
--       and any remaining unmatched row     -> Electric Motors (Standalone)
--   'Electric Motors (Standalone)' is the fallback because, per the asset
--   census recorded in migration 187, every asset that had fed into this
--   bucket from the pre-187 catalog was a motor (18 of 20) or pump (2 of
--   20) -- never a conveyor -- so motors is the safer default for anything
--   ambiguous. This is a reviewable best-effort remap, not a guarantee of
--   perfect classification; sites should confirm the specific type on any
--   asset that lands here as "Electric Motors (Standalone)" by heuristic
--   fallback rather than an explicit name match.
-- STEP C: drop mapping rows and delete 'Motors/Pumps/Conveyors' itself once
--   nothing references it (belt-and-braces, mirrors migration 187 STEP C --
--   the DELETE fails loudly instead of orphaning data if anything was
--   missed in STEP B).
-- STEP D: map the 5 new asset types to relevant sub-sectors using the
--   metadata.sectors / metadata.sub_sectors taxonomy from migration 187:
--     Electric Motors, Pumps, Heaters -> every sub-sector (cross-sector base
--       equipment, same blanket coverage the legacy 'Motors/Pumps/Conveyors'
--       type had). An earlier draft of this migration scoped these three to
--       only Industrial / Manufacturing, Commercial Real Estate, and
--       Healthcare; live-database verification against a real site on
--       "Manufacturing Plants (Bulk/API/FDF)" (Pharmaceuticals & Life
--       Sciences sector) showed that would silently drop Electric Motors and
--       Pumps from that site's asset-type picker post-migration -- a
--       regression, since pharma plants plainly have motors and pumps. Kept
--       cross-sector to match prior behavior and avoid that class of bug for
--       every sub-sector, not just the one caught in testing.
--     Conveyors & Sorting Lines -> Heavy/Light Manufacturing, Food &
--       Beverage Processing, Distribution & Fulfillment Centers, Cold
--       Storage Warehouses, and Airports.
--     Sifters / Screeners -> Food & Beverage Processing, Chemical
--       Processing, and Manufacturing Plants (Bulk/API/FDF) (pharma
--       manufacturing).
--
-- Idempotent: safe to run more than once against the same database.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- STEP A: insert the 5 new asset types (idempotent).
-- ----------------------------------------------------------------------------

CREATE TEMP TABLE new_split_asset_type_catalog (
    name TEXT PRIMARY KEY,
    description TEXT
) ON COMMIT DROP;

INSERT INTO new_split_asset_type_catalog (name, description) VALUES
    ('Electric Motors (Standalone)', 'Standalone electric motor not part of a packaged pump or conveyor assembly'),
    ('Pumps (Water/Utility/Process)', 'Water, utility, or process pump'),
    ('Conveyors & Sorting Lines', 'Conveyor or automated sorting line equipment'),
    ('Heaters (Air/Duct/Space)', 'Air, duct, or space heating equipment'),
    ('Sifters / Screeners', 'Sifting or screening equipment used in material processing')
ON CONFLICT (name) DO NOTHING;

INSERT INTO metadata.asset_types (name, description)
SELECT c.name, c.description
FROM new_split_asset_type_catalog c
WHERE NOT EXISTS (
    SELECT 1 FROM metadata.asset_types existing
    WHERE lower(existing.name) = lower(c.name)
);

-- ----------------------------------------------------------------------------
-- STEP B: remap existing assets off of 'Motors/Pumps/Conveyors' before it is
-- removed from the catalog. Best-effort split by asset name (see header);
-- falls back to 'Electric Motors (Standalone)' for anything not confidently
-- identifiable as a pump or a conveyor.
-- ----------------------------------------------------------------------------

WITH legacy_type AS (
    SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Motors/Pumps/Conveyors')
),
target_types AS (
    SELECT
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Electric Motors (Standalone)')) AS motor_id,
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Pumps (Water/Utility/Process)')) AS pump_id,
        (SELECT id FROM metadata.asset_types WHERE lower(name) = lower('Conveyors & Sorting Lines')) AS conveyor_id
)
UPDATE metadata.assets a
SET asset_type_id = CASE
        WHEN a.name ILIKE '%conveyor%' OR a.name ILIKE '%sort%' THEN target_types.conveyor_id
        WHEN a.name ILIKE '%pump%' THEN target_types.pump_id
        ELSE target_types.motor_id
    END,
    updated_at = clock_timestamp()
FROM legacy_type, target_types
WHERE a.asset_type_id = legacy_type.id;

-- ----------------------------------------------------------------------------
-- STEP C: drop stale sub-sector mappings and the now-unreferenced legacy
-- asset type. The DELETE is belt-and-braces: metadata.assets.asset_type_id
-- has a plain (non-cascading) foreign key to metadata.asset_types, so a
-- leftover reference (STEP B missed a row) makes this fail loudly instead
-- of orphaning data.
-- ----------------------------------------------------------------------------

DELETE FROM metadata.sub_sector_asset_mapping m
USING metadata.asset_types legacy
WHERE m.asset_type_id = legacy.id
    AND lower(legacy.name) = lower('Motors/Pumps/Conveyors');

DELETE FROM metadata.asset_types legacy
WHERE lower(legacy.name) = lower('Motors/Pumps/Conveyors')
    AND NOT EXISTS (
        SELECT 1 FROM metadata.assets a
        WHERE a.asset_type_id = legacy.id
    );

-- ----------------------------------------------------------------------------
-- STEP D: map the 5 new asset types to relevant sub-sectors.
-- ----------------------------------------------------------------------------

-- Electric Motors, Pumps, and Heaters: cross-sector base building / process
-- equipment, mapped to every sub-sector (see STEP D note above).
INSERT INTO metadata.sub_sector_asset_mapping (sub_sector_id, asset_type_id)
SELECT ss.id, at.id
FROM metadata.sub_sectors ss
CROSS JOIN metadata.asset_types at
WHERE at.name IN (
    'Electric Motors (Standalone)',
    'Pumps (Water/Utility/Process)',
    'Heaters (Air/Duct/Space)'
)
ON CONFLICT DO NOTHING;

-- Conveyors & Sorting Lines and Sifters / Screeners: targeted process/
-- material-handling sub-sectors.
INSERT INTO metadata.sub_sector_asset_mapping (sub_sector_id, asset_type_id)
SELECT ss.id, at.id
FROM (VALUES
    ('Conveyors & Sorting Lines', 'Heavy Manufacturing'),
    ('Conveyors & Sorting Lines', 'Light Manufacturing'),
    ('Conveyors & Sorting Lines', 'Food & Beverage Processing'),
    ('Conveyors & Sorting Lines', 'Distribution & Fulfillment Centers'),
    ('Conveyors & Sorting Lines', 'Cold Storage Warehouses'),
    ('Conveyors & Sorting Lines', 'Airports'),

    ('Sifters / Screeners', 'Food & Beverage Processing'),
    ('Sifters / Screeners', 'Chemical Processing'),
    ('Sifters / Screeners', 'Manufacturing Plants (Bulk/API/FDF)')
) AS requested(asset_type_name, sub_sector_name)
JOIN metadata.asset_types at ON lower(at.name) = lower(requested.asset_type_name)
JOIN metadata.sub_sectors ss ON lower(ss.name) = lower(requested.sub_sector_name)
ON CONFLICT DO NOTHING;

COMMIT;
