\set ON_ERROR_STOP on

WITH expected(name) AS (
    VALUES
        ('Motor'),
        ('Generator'),
        ('Solar plant'),
        ('Refrigeration system'),
        ('Production line'),
        ('Compressed air'),
        ('Water system'),
        ('Indoor environment')
),
missing AS (
    SELECT expected.name
    FROM expected
    WHERE NOT EXISTS (
        SELECT 1
        FROM metadata.asset_types AS actual
        WHERE lower(actual.name) = lower(expected.name)
    )
)
SELECT
    CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS asset_type_catalog,
    count(*) AS missing_count
FROM missing;

SELECT id, name, description
FROM metadata.asset_types
WHERE lower(name) IN (
    'motor',
    'generator',
    'solar plant',
    'refrigeration system',
    'production line',
    'compressed air',
    'water system',
    'indoor environment'
)
ORDER BY name;
