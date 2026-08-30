-- ============================================================================
-- Migration 219
-- Make the Best Energy "Air Sense" environmental sensor onboardable against
-- the pre-existing ENVIRONMENT_SENSOR_AIRSENSE_V1 telemetry profile.
--
-- Root cause (staging read-only investigation, 2026-08-29)
-- -------------------------------------------------------------------------
-- The telemetry payload profile ENVIRONMENT_SENSOR_AIRSENSE_V1 ALREADY
-- EXISTS and is complete on staging:
--   * config.device_profiles row present, is_active = TRUE
--     (profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1',
--      manufacturer 'Generic', model 'Environment Sensor', firmware '1.0')
--   * 12 optional config.profile_field_mapping rows
--     (T1, RH, LL, PIR, PIR_t, dis1, ain1..ain4, Vbat, Stat)
-- It is NOT missing and must NOT be recreated or altered.
--
-- Two pieces of canonical *reference data* were never seeded for it, so the
-- Admin "Add device" wizard can never surface it for an Environmental
-- Sensor:
--
--   1. config.device_profile_categories has NO row linking
--      ENVIRONMENT_SENSOR_AIRSENSE_V1 to the "Environmental Sensor" device
--      category. admin.v_active_device_profiles therefore returns the
--      profile with device_category_ids = {}, and the onboarding UI
--      (app/src/static/js/onboarding-device.js -> filterProfiles()) hides
--      every profile whose data-category-ids does not contain the chosen
--      category id -- so the "Compatible telemetry profile" selector is
--      empty for Environmental Sensor. The same missing row makes
--      admin.create_device() raise "Device profile is not compatible with
--      the selected category." On staging this join table holds exactly
--      one row today (ENERGY_METER_ENISCOPE_V1 <-> Energy Meter, added out
--      of band 2026-08-24); no repository seed populates it at all -- see
--      docs/platform-manual/23-known-issues-and-drift.md item 7.
--
--   2. metadata.device_models has NO "Best Energy / Air Sense" row (it
--      holds one row today: Best Energy / Eniscope Energy Meter). So the
--      "Device model" selector offers nothing for the Environmental Sensor
--      category and admin.create_device() raises "Device model does not
--      match the selected category."
--
-- Both tables are declarative platform reference data: no tenant data, no
-- per-device telemetry mapping. This migration inserts exactly the two
-- rows the Air Sense model needs, resolving every foreign key by natural
-- key (profile_code / category name / vendor+model), idempotently.
--
-- Explicitly NOT changed
-- -------------------------------------------------------------------------
--   * config.device_profiles -- the ENVIRONMENT_SENSOR_AIRSENSE_V1 row and
--     every column on it (manufacturer, model, firmware_version,
--     description, is_active) is preserved exactly. The profile is correct.
--   * config.profile_field_mapping -- the 12 existing Air Sense field
--     mappings are untouched; no logical-point / normalization semantics
--     change.
--   * config.device_profile_required_fields -- deliberately left with no
--     row for this profile, so admin.commission_device()'s migration-199
--     completeness gate stays a vacuous no-op for Air Sense devices (the
--     environment fields are all optional by design, per seed
--     postgres/seeds/reference/65_environment_sensor_profile.sql).
--   * No application code, view, trigger, or function is modified. The
--     onboarding view, the JS category filter, and the admin.create_device
--     compatibility gates are already correct and generic -- they simply
--     had no reference row to act on.
-- ============================================================================

DO
$$
DECLARE
    v_profile_id      UUID;
    v_env_category_id UUID;
    v_model_id        UUID;
BEGIN
    -- ----------------------------------------------------------------------
    -- Resolve the existing canonical entities by natural key.
    -- ----------------------------------------------------------------------
    SELECT id
    INTO v_profile_id
    FROM config.device_profiles
    WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1';

    IF v_profile_id IS NULL THEN
        RAISE EXCEPTION
            'Migration 219: telemetry profile ENVIRONMENT_SENSOR_AIRSENSE_V1 was not found '
            '(expected from seed postgres/seeds/reference/65_environment_sensor_profile.sql). '
            'Refusing to fabricate a profile -- investigate the reference-data state first.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.device_profiles
        WHERE id = v_profile_id
          AND is_active
    ) THEN
        RAISE EXCEPTION
            'Migration 219: telemetry profile ENVIRONMENT_SENSOR_AIRSENSE_V1 exists but is not active; '
            'not activating it here -- investigate why it was deactivated.';
    END IF;

    SELECT id
    INTO v_env_category_id
    FROM config.device_categories
    WHERE name = 'Environmental Sensor';

    IF v_env_category_id IS NULL THEN
        RAISE EXCEPTION
            'Migration 219: device category "Environmental Sensor" was not found '
            '(expected from seed postgres/seeds/reference/05_lookup_tables.sql).';
    END IF;

    -- ----------------------------------------------------------------------
    -- 1. Profile <-> category compatibility row.
    --    PK is (profile_id, device_category_id) -- ON CONFLICT DO NOTHING
    --    makes a re-run a no-op.
    -- ----------------------------------------------------------------------
    INSERT INTO config.device_profile_categories (profile_id, device_category_id)
    VALUES (v_profile_id, v_env_category_id)
    ON CONFLICT (profile_id, device_category_id) DO NOTHING;

    -- ----------------------------------------------------------------------
    -- 2. Best Energy / Air Sense device-model catalogue row.
    --    Uniqueness is the case-insensitive expression index
    --    metadata.device_models_vendor_model_ci_uq
    --    (lower(coalesce(vendor,'')), lower(model)) -- guard on that shape.
    --    device_type mirrors the category name: the legacy compatibility
    --    column that admin.create_device / migration 193 keep synchronised.
    -- ----------------------------------------------------------------------
    SELECT id
    INTO v_model_id
    FROM metadata.device_models
    WHERE lower(coalesce(vendor, '')) = lower('Best Energy')
      AND lower(model) = lower('Air Sense');

    IF v_model_id IS NULL THEN
        INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id)
        VALUES ('Best Energy', 'Air Sense', 'Environmental Sensor', v_env_category_id)
        RETURNING id INTO v_model_id;
    ELSE
        -- An out-of-band row already exists: align it with the canonical
        -- intent without disturbing its identity or created_at.
        UPDATE metadata.device_models
        SET device_category_id = v_env_category_id,
            device_type        = 'Environmental Sensor'
        WHERE id = v_model_id
          AND (device_category_id IS DISTINCT FROM v_env_category_id
               OR device_type IS DISTINCT FROM 'Environmental Sensor');
    END IF;

    -- ----------------------------------------------------------------------
    -- 3. Postconditions -- the migration transaction rolls back if the
    --    intended end state was not reached (mirrors the migration 198/199
    --    "fail loudly on partial reference data" discipline).
    -- ----------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1
        FROM config.device_profiles dp
        JOIN config.device_profile_categories dpc ON dpc.profile_id = dp.id
        WHERE dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
          AND dp.is_active
          AND dpc.device_category_id = v_env_category_id
    ) THEN
        RAISE EXCEPTION
            'Migration 219 postcondition failed: ENVIRONMENT_SENSOR_AIRSENSE_V1 is still not '
            'compatible with the Environmental Sensor category.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM metadata.device_models dm
        WHERE dm.id = v_model_id
          AND dm.device_category_id = v_env_category_id
          AND lower(coalesce(dm.vendor, '')) = lower('Best Energy')
          AND lower(dm.model) = lower('Air Sense')
    ) THEN
        RAISE EXCEPTION
            'Migration 219 postcondition failed: the Best Energy / Air Sense device-model row is '
            'missing or not in the Environmental Sensor category.';
    END IF;

    -- The onboarding lookup view must now advertise the category so the
    -- Admin wizard can offer the profile for an Environmental Sensor.
    IF NOT EXISTS (
        SELECT 1
        FROM admin.v_active_device_profiles
        WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'
          AND v_env_category_id = ANY (device_category_ids)
    ) THEN
        RAISE EXCEPTION
            'Migration 219 postcondition failed: admin.v_active_device_profiles does not expose the '
            'Environmental Sensor category for ENVIRONMENT_SENSOR_AIRSENSE_V1.';
    END IF;

    -- The 12 existing Air Sense field mappings must be untouched.
    IF (
        SELECT count(*)
        FROM config.profile_field_mapping
        WHERE profile_id = v_profile_id
    ) < 12 THEN
        RAISE EXCEPTION
            'Migration 219 postcondition failed: expected the existing 12 ENVIRONMENT_SENSOR_AIRSENSE_V1 '
            'field mappings to remain intact.';
    END IF;
END;
$$;
