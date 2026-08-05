\echo '=== CREATE DEVICE FUNCTION CONTRACT ==='
SELECT
  position('recommend_available_identifier' in pg_get_functiondef(p.oid)) > 0 AS resolves_external_id_conflicts,
  position('This device identifier is already assigned' in pg_get_functiondef(p.oid)) > 0 AS preserves_physical_uid_conflict
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='admin' AND p.proname='create_device'
ORDER BY p.oid DESC
LIMIT 1;

\echo '=== DEVICE IDENTIFIER DUPLICATES ==='
SELECT identifier_type, lower(identifier_value) AS identifier_value, count(*)
FROM metadata.device_identifiers
GROUP BY identifier_type, lower(identifier_value)
HAVING count(*) > 1;
