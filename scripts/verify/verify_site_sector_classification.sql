\set ON_ERROR_STOP on
SELECT CASE WHEN count(*)=9 THEN 'PASS' ELSE 'FAIL' END AS sector_catalog, count(*) AS sector_count FROM config.site_sectors WHERE is_active;
SELECT CASE WHEN EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='metadata' AND table_name='sites' AND column_name='sector_code' AND is_nullable='NO') THEN 'PASS' ELSE 'FAIL' END AS site_sector_column;
SELECT code,display_name,display_order FROM config.site_sectors WHERE is_active ORDER BY display_order;
SELECT sector_code,count(*) AS site_count FROM metadata.sites GROUP BY sector_code ORDER BY sector_code;
