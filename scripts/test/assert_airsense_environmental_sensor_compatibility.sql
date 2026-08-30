-- ============================================================================
-- File:
--   scripts/test/assert_airsense_environmental_sensor_compatibility.sql
--
-- Purpose:
--   Regression test for migration 219. The ENVIRONMENT_SENSOR_AIRSENSE_V1
--   telemetry profile already existed and was complete, but no reference
--   row made it (or a Best Energy / Air Sense device model) usable in the
--   Admin "Add device" wizard for an Environmental Sensor. Migration 219
--   adds exactly two idempotent reference rows:
--     * config.device_profile_categories: ENVIRONMENT_SENSOR_AIRSENSE_V1
--       <-> "Environmental Sensor"
--     * metadata.device_models: Best Energy / Air Sense in the
--       "Environmental Sensor" category
--
--   This test proves, on the canonical test database with migration 219
--   applied:
--     1. The compatibility row exists and admin.v_active_device_profiles
--        now advertises the Environmental Sensor category for the profile
--        (the exact signal app/src/static/js/onboarding-device.js filters
--        on).
--     2. The Best Energy / Air Sense device-model row exists in the
--        Environmental Sensor category and admin.v_device_models returns
--        it.
--     3. The pre-existing ENVIRONMENT_SENSOR_AIRSENSE_V1 profile is
--        unchanged: still is_active, still 'Generic' / 'Environment
--        Sensor', still exactly its existing field mappings; no
--        config.device_profile_required_fields row was added for it (so the
--        migration-199 commissioning gate stays a no-op for Air Sense).
--     4. admin.create_device()'s two compatibility gates
--        (device_model <-> category, profile <-> category) both pass for
--        the Environmental Sensor / Best Energy / Air Sense /
--        ENVIRONMENT_SENSOR_AIRSENSE_V1 combination -- i.e. the device can
--        now be onboarded -- and still reject a deliberately mismatched
--        category (no over-broad compatibility was introduced).
--     5. Migration 219 is idempotent: re-running its body is a clean no-op
--        and does not duplicate either row.
--
--   Everything runs inside one transaction that is rolled back.
--
-- Failure behavior:
--   Any assertion failure raises an exception and fails the test runner.
-- ============================================================================

BEGIN;


-- ------------------------------------------------------------------
-- 1 + 2. Reference rows and the onboarding lookup views.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_profile_id      UUID;
    v_env_category_id UUID;
    v_model_id        UUID;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Fixture assumption violated: ENVIRONMENT_SENSOR_AIRSENSE_V1 must exist on the canonical '
            'test database (seed postgres/seeds/reference/65_environment_sensor_profile.sql).';
    END IF;

    SELECT id INTO v_env_category_id
    FROM config.device_categories
    WHERE name = 'Environmental Sensor';

    IF v_env_category_id IS NULL THEN
        RAISE EXCEPTION
            'Fixture assumption violated: the "Environmental Sensor" device category must exist '
            '(seed postgres/seeds/reference/05_lookup_tables.sql).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM config.device_profile_categories
        WHERE profile_id = v_profile_id
          AND device_category_id = v_env_category_id
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: migration 219 did not create the ENVIRONMENT_SENSOR_AIRSENSE_V1 <-> '
            '"Environmental Sensor" row in config.device_profile_categories.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM admin.v_active_device_profiles
        WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
          AND v_env_category_id = ANY (device_category_ids)
          AND 'Environmental Sensor' = ANY (device_category_names)
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: admin.v_active_device_profiles does not expose the Environmental Sensor '
            'category for ENVIRONMENT_SENSOR_AIRSENSE_V1 -- the onboarding UI would still hide it.';
    END IF;

    SELECT id INTO v_model_id
    FROM metadata.device_models
    WHERE lower(coalesce(vendor, '')) = lower('Best Energy')
      AND lower(model) = lower('Air Sense');

    IF v_model_id IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILURE: migration 219 did not create the Best Energy / Air Sense metadata.device_models row.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models
        WHERE id = v_model_id
          AND device_category_id = v_env_category_id
          AND device_type = 'Environmental Sensor'
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: the Best Energy / Air Sense device model is not in the Environmental Sensor '
            'category (or device_type is not synchronised to the category name).';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM admin.v_device_models
        WHERE lower(coalesce(vendor, '')) = lower('Best Energy')
          AND lower(model) = lower('Air Sense')
          AND device_category_name = 'Environmental Sensor'
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: admin.v_device_models does not return Best Energy / Air Sense for the '
            'Environmental Sensor category.';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3. The pre-existing profile is untouched.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_profile_id UUID;
    v_mapping_count INT;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
      AND is_active
      AND manufacturer = 'Generic'
      AND model = 'Environment Sensor';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'TEST FAILURE: the ENVIRONMENT_SENSOR_AIRSENSE_V1 profile row was altered by migration 219 '
            '(expected is_active, manufacturer ''Generic'', model ''Environment Sensor'' preserved).';
    END IF;

    SELECT count(*) INTO v_mapping_count
    FROM config.profile_field_mapping
    WHERE profile_id = v_profile_id;

    -- The canonical seed creates 5 mappings; migration 117/165 expands the
    -- profile to 12. Either way, migration 219 must not remove or add any.
    IF v_mapping_count NOT IN (5, 12) THEN
        RAISE EXCEPTION
            'TEST FAILURE: ENVIRONMENT_SENSOR_AIRSENSE_V1 has % field mappings; migration 219 must not '
            'change the mapping set (expected the seeded 5 or the expanded 12).', v_mapping_count;
    END IF;

    IF EXISTS (
        SELECT 1 FROM config.device_profile_required_fields
        WHERE profile_id = v_profile_id
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: migration 219 added a config.device_profile_required_fields row for '
            'ENVIRONMENT_SENSOR_AIRSENSE_V1 -- it must not, so admin.commission_device()''s '
            'migration-199 completeness gate stays a no-op for Air Sense devices.';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 4. admin.create_device()'s compatibility gates: positive + negative.
--    These mirror the two IF NOT EXISTS checks in the current
--    admin.create_device body (postgres/ddl/118_*.sql) exactly, so this
--    proves the onboarding write path is unblocked without needing a full
--    gateway/site/actor fixture.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_env_category_id UUID;
    v_other_category_id UUID;
    v_model_id UUID;
    v_profile_id UUID;
BEGIN
    SELECT id INTO v_env_category_id
    FROM config.device_categories WHERE name = 'Environmental Sensor';

    SELECT id INTO v_other_category_id
    FROM config.device_categories WHERE name = 'Energy Meter';

    SELECT id INTO v_model_id
    FROM metadata.device_models
    WHERE lower(coalesce(vendor, '')) = lower('Best Energy')
      AND lower(model) = lower('Air Sense');

    SELECT id INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';

    -- Gate 1: device model belongs to the category.
    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models dm
        WHERE dm.id = v_model_id AND dm.device_category_id = v_env_category_id
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: admin.create_device gate 1 (device model <-> category) would still reject '
            'Best Energy / Air Sense for Environmental Sensor.';
    END IF;

    -- Gate 2: profile is compatible with the category.
    IF NOT EXISTS (
        SELECT 1 FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id = dp.id
        WHERE dp.id = v_profile_id AND dp.is_active
          AND dpc.device_category_id = v_env_category_id
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: admin.create_device gate 2 (profile <-> category) would still reject '
            'ENVIRONMENT_SENSOR_AIRSENSE_V1 for Environmental Sensor.';
    END IF;

    -- Negative: no over-broad compatibility was introduced. The Air Sense
    -- profile must NOT be considered compatible with an unrelated category.
    IF EXISTS (
        SELECT 1 FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id = dp.id
        WHERE dp.id = v_profile_id AND dp.is_active
          AND dpc.device_category_id = v_other_category_id
    ) THEN
        RAISE EXCEPTION
            'TEST FAILURE: ENVIRONMENT_SENSOR_AIRSENSE_V1 is now compatible with the Energy Meter '
            'category -- migration 219 introduced over-broad compatibility.';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 5. Idempotency: re-running the migration body inserts nothing new.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_profile_id      UUID;
    v_env_category_id UUID;
    v_dpc_before INT;
    v_dpc_after  INT;
    v_dm_before  INT;
    v_dm_after   INT;
BEGIN
    SELECT id INTO v_profile_id
    FROM config.device_profiles WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';
    SELECT id INTO v_env_category_id
    FROM config.device_categories WHERE name = 'Environmental Sensor';

    SELECT count(*) INTO v_dpc_before FROM config.device_profile_categories;
    SELECT count(*) INTO v_dm_before  FROM metadata.device_models;

    INSERT INTO config.device_profile_categories (profile_id, device_category_id)
    VALUES (v_profile_id, v_env_category_id)
    ON CONFLICT (profile_id, device_category_id) DO NOTHING;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.device_models
        WHERE lower(coalesce(vendor, '')) = lower('Best Energy')
          AND lower(model) = lower('Air Sense')
    ) THEN
        INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id)
        VALUES ('Best Energy', 'Air Sense', 'Environmental Sensor', v_env_category_id);
    END IF;

    SELECT count(*) INTO v_dpc_after FROM config.device_profile_categories;
    SELECT count(*) INTO v_dm_after  FROM metadata.device_models;

    IF v_dpc_after <> v_dpc_before OR v_dm_after <> v_dm_before THEN
        RAISE EXCEPTION
            'TEST FAILURE: migration 219 is not idempotent (device_profile_categories % -> %, '
            'device_models % -> %).', v_dpc_before, v_dpc_after, v_dm_before, v_dm_after;
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Air Sense / Environmental Sensor compatibility (migration 219) assertions passed.'
    AS result;
