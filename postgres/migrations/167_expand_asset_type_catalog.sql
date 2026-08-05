BEGIN;

-- Add controlled EMS asset types requested for cross-sector use.
-- Idempotent and case-insensitive: existing rows are preserved.

WITH requested_asset_types(name, description) AS (
    VALUES
        ('Motor', 'Electric motor or motor-driven equipment'),
        ('Generator', 'On-site electrical generation equipment'),
        ('Solar plant', 'Solar photovoltaic generation plant or system'),
        ('Refrigeration system', 'Refrigeration plant, system, or packaged equipment'),
        ('Production line', 'Integrated manufacturing or production line'),
        ('Compressed air', 'Compressed-air generation, treatment, storage, or distribution system'),
        ('Water system', 'Water supply, treatment, storage, pumping, or distribution system'),
        ('Indoor environment', 'Indoor environmental condition or occupied-space monitoring scope')
)
INSERT INTO metadata.asset_types (name, description)
SELECT requested.name, requested.description
FROM requested_asset_types AS requested
WHERE NOT EXISTS (
    SELECT 1
    FROM metadata.asset_types AS existing
    WHERE lower(existing.name) = lower(requested.name)
);

COMMIT;
