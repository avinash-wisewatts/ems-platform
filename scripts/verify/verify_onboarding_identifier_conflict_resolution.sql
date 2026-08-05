\set ON_ERROR_STOP on
\echo '=== WRAPPER CONTRACT ==='
WITH f AS (
    SELECT pg_get_functiondef('admin.onboard_energy_asset(jsonb,text)'::regprocedure) AS definition
)
SELECT
    definition LIKE '%Gateway external IDs are system-generated%' AS gateway_auto_resolution_enabled,
    definition LIKE '%Device external IDs are system-generated%' AS device_auto_resolution_enabled,
    definition LIKE '%recommend_available_identifier(%''BUILDING''%' AS building_auto_resolution_enabled,
    definition NOT LIKE '%Gateway external ID % already exists. Choose Use existing gateway.%' AS gateway_rejection_removed,
    definition NOT LIKE '%Device external ID % already exists. Choose Use existing device.%' AS device_rejection_removed,
    definition LIKE '%Device identifier %:% already exists. Choose the existing device.%' AS telemetry_identifier_still_strict
FROM f;

\echo ''
\echo '=== CANONICAL WRITER AUTO-RESOLUTION ==='
WITH f AS (
    SELECT pg_get_functiondef('admin.onboard_energy_asset_legacy_upsert(jsonb,text)'::regprocedure) AS definition
)
SELECT
    definition LIKE '%''GATEWAY''%' AND definition LIKE '%recommend_available_identifier%' AS gateway_writer_recommends,
    definition LIKE '%''DEVICE''%' AND definition LIKE '%recommend_available_identifier%' AS device_writer_recommends,
    definition LIKE '%''ASSET''%' AND definition LIKE '%recommend_available_identifier%' AS asset_writer_recommends
FROM f;

\echo ''
\echo '=== FIELD-VALIDATION RECOMMENDATIONS ==='
WITH f AS (
    SELECT pg_get_functiondef('admin.validate_onboarding_field(bigint,uuid,text,text,text,jsonb)'::regprocedure) AS definition
)
SELECT
    definition LIKE '%''BUILDING''%' AND definition LIKE '%recommended_value%' AS building_recommendation_present,
    definition LIKE '%''FLOOR''%' AND definition LIKE '%recommended_value%' AS floor_recommendation_present,
    definition LIKE '%''SPACE''%' AND definition LIKE '%recommended_value%' AS space_recommendation_present,
    definition LIKE '%''GATEWAY''%' AND definition LIKE '%recommended_value%' AS gateway_recommendation_present,
    definition LIKE '%''DEVICE''%' AND definition LIKE '%recommended_value%' AS device_recommendation_present,
    definition LIKE '%''ASSET''%' AND definition LIKE '%recommended_value%' AS asset_recommendation_present
FROM f;

\echo ''
\echo '=== LIVE DEVICE RECOMMENDATION SAMPLE ==='
SELECT admin.recommend_available_identifier(
    'DEVICE',
    'LIFT_ENERGY_METER',
    'f91240fd-70ff-4237-b56d-6ba32a2fca58'::uuid,
    NULL,
    NULL,
    NULL,
    NULL
) AS recommended_device_external_id;
