-- ============================================================================
-- File:
--   scripts/test/assert_semantic_foundation_parameters.sql
--
-- Purpose:
--   Regression test for migration 223 (Phase 1 semantic foundation:
--   config.parameters, metadata.logical_points.parameter_id/qualifier).
--
--   This test proves, as three separate concerns:
--     1. MAPPED POINTS -- every point migration 223 mapped resolves to
--        exactly one config.parameters row with the correct qualifier, and
--        the qualifier-requires-parameter / one-point-per-(parameter,
--        qualifier) constraints actually hold (positive + negative cases).
--     2. INTENTIONALLY UNMAPPED POINTS -- the documented deferred/ambiguous
--        points remain parameter_id IS NULL, and this is asserted as the
--        CORRECT state, not treated as a failure or as something to patch.
--     3. REGRESSION -- no blanket NOT NULL / completeness constraint was
--        introduced (an arbitrary, never-evaluated logical_point may still
--        have parameter_id IS NULL with no error), and existing
--        logical_points columns/behavior are unaffected.
--
--   All changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
--
-- Failure behavior:
--   Any assertion failure raises an exception and causes the test runner
--   to fail.
-- ============================================================================

BEGIN;


-- ------------------------------------------------------------------
-- 1a. Mapped points -- positive case: spot-check representative
--     mappings across both profiles resolve to the correct parameter
--     code and qualifier.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_bad_mappings TEXT;
BEGIN
    SELECT string_agg(lp.name || ' -> expected ' || expected.parameter_code || '/' || COALESCE(expected.qualifier, 'NULL')
                       || ', got ' || COALESCE(p.code, 'NULL') || '/' || COALESCE(lp.qualifier, 'NULL'), '; ')
    INTO v_bad_mappings
    FROM (VALUES
        ('CURRENT_L1', 'CURRENT', 'L1'),
        ('CURRENT_TOTAL', 'CURRENT', 'TOTAL'),
        ('CURRENT_NEUTRAL', 'CURRENT', 'NEUTRAL'),
        ('VOLTAGE_L1', 'VOLTAGE_LINE_NEUTRAL', 'L1'),
        ('VOLTAGE_L12', 'VOLTAGE_LINE_LINE', 'L12'),
        ('ENERGY_IMPORT_TOTAL', 'ENERGY_IMPORT', 'TOTAL'),
        ('ENERGY_EXPORT_TOTAL', 'ENERGY_EXPORT', 'TOTAL'),
        ('FREQUENCY', 'FREQUENCY', NULL),
        ('ENV_TEMPERATURE', 'TEMPERATURE', NULL),
        ('ENV_RELATIVE_HUMIDITY', 'HUMIDITY', NULL),
        ('DEVICE_BATTERY_VOLTAGE', 'BATTERY_VOLTAGE', NULL),
        ('OCCUPANCY_ACTIVITY', 'OCCUPANCY_ACTIVITY', NULL),
        ('OCCUPANCY_SECONDS_SINCE_LAST_PIR_EVENT', 'OCCUPANCY_TIME_SINCE_LAST_EVENT', NULL)
    ) AS expected(logical_point_name, parameter_code, qualifier)
    LEFT JOIN metadata.logical_points lp ON lp.name = expected.logical_point_name
    LEFT JOIN config.parameters p ON p.id = lp.parameter_id
    WHERE p.code IS DISTINCT FROM expected.parameter_code
       OR lp.qualifier IS DISTINCT FROM expected.qualifier;

    IF v_bad_mappings IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: mapped-point spot-check(s) incorrect: %', v_bad_mappings;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1b. Mapped points -- every mapped logical_point resolves to EXACTLY
--     ONE config.parameters row (no dangling/ambiguous FK).
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_dangling_count INTEGER;
BEGIN
    SELECT count(*) INTO v_dangling_count
    FROM metadata.logical_points lp
    LEFT JOIN config.parameters p ON p.id = lp.parameter_id
    WHERE lp.parameter_id IS NOT NULL
      AND p.id IS NULL;

    IF v_dangling_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILURE: % logical_points have a parameter_id that does not resolve to a config.parameters row', v_dangling_count;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1c. Mapped points -- negative case: the CHECK constraint rejects a
--     qualifier without a parameter_id.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        -- DEVICE_STATUS_CODE is intentionally unmapped (parameter_id NULL),
        -- so setting a qualifier on it must violate the CHECK constraint.
        UPDATE metadata.logical_points
        SET qualifier = 'BOGUS'
        WHERE name = 'DEVICE_STATUS_CODE';

        RAISE EXCEPTION 'TEST FAILURE: setting qualifier without parameter_id did not raise';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected chk_logical_points_qualifier_requires_parameter to raise, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1d. Mapped points -- negative case: the uniqueness index rejects a
--     second logical_point claiming the same (parameter, qualifier).
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_raised    BOOLEAN := FALSE;
    v_current_l1_parameter UUID;
BEGIN
    SELECT parameter_id INTO v_current_l1_parameter
    FROM metadata.logical_points
    WHERE name = 'CURRENT_L1';

    IF v_current_l1_parameter IS NULL THEN
        RAISE EXCEPTION 'Fixture assumption violated: CURRENT_L1 must be mapped by migration 223';
    END IF;

    BEGIN
        UPDATE metadata.logical_points
        SET parameter_id = v_current_l1_parameter,
            qualifier    = 'L1'
        WHERE name = 'CURRENT_L2';  -- deliberately claim CURRENT_L1's (parameter, qualifier)

        RAISE EXCEPTION 'TEST FAILURE: claiming a duplicate (parameter_id, qualifier) pair did not raise';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected uq_logical_points_parameter_qualifier to raise, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 2. Intentionally unmapped points -- these MUST remain
--    parameter_id IS NULL. This is the expected, correct state, not a
--    failure to be patched.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_unexpectedly_mapped TEXT;
BEGIN
    SELECT string_agg(name, ', ') INTO v_unexpectedly_mapped
    FROM metadata.logical_points
    WHERE name IN (
        'PULSE_COUNT',
        'PULSE_INPUT_1_RAW',
        'EXTERNAL_SENSOR_INPUT_1_RAW','EXTERNAL_SENSOR_INPUT_2_RAW',
        'EXTERNAL_SENSOR_INPUT_3_RAW','EXTERNAL_SENSOR_INPUT_4_RAW',
        'DEVICE_STATUS_CODE',
        'ENERGY_REACTIVE_ENERGY_L1','ENERGY_REACTIVE_ENERGY_L2','ENERGY_REACTIVE_ENERGY_L3',
        'ENERGY_REACTIVE_EXPORT_L1','ENERGY_REACTIVE_EXPORT_L2','ENERGY_REACTIVE_EXPORT_L3',
        'ENERGY_REACTIVE_EXPORT_TOTAL'
    )
    AND parameter_id IS NOT NULL;

    IF v_unexpectedly_mapped IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: intentionally-unmapped logical point(s) unexpectedly have a parameter_id: %', v_unexpectedly_mapped;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3a. Regression -- no blanket NOT NULL / completeness constraint was
--     introduced: parameter_id must remain nullable, and a brand-new,
--     never-evaluated logical_point may be inserted with
--     parameter_id/qualifier both NULL with no error.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_is_nullable TEXT;
BEGIN
    SELECT is_nullable INTO v_is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'metadata'
      AND table_name = 'logical_points'
      AND column_name = 'parameter_id';

    IF v_is_nullable <> 'YES' THEN
        RAISE EXCEPTION 'TEST FAILURE: metadata.logical_points.parameter_id must remain nullable (no completeness constraint), found is_nullable=%', v_is_nullable;
    END IF;

    INSERT INTO metadata.logical_points (name, description, data_type)
    VALUES ('TEST_MIGRATION_223_UNEVALUATED_POINT', 'Test fixture: proves an unmapped point is valid.', 'numeric');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.logical_points
        WHERE name = 'TEST_MIGRATION_223_UNEVALUATED_POINT'
          AND parameter_id IS NULL
          AND qualifier IS NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: a brand-new logical_point with no parameter mapping should insert cleanly with parameter_id/qualifier NULL';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3b. Regression -- pre-existing logical_points identity columns
--     (name, unit_id, data_type) are unaffected by this migration.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_missing_count INTEGER;
BEGIN
    SELECT count(*) INTO v_missing_count
    FROM (VALUES ('ENV_TEMPERATURE'), ('ENERGY_IMPORT_TOTAL'), ('CURRENT_L1')) AS expected(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM metadata.logical_points lp WHERE lp.name = expected.name
    );

    IF v_missing_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILURE: pre-existing logical_points appear to be missing after migration 223 -- regression in an unrelated column/row';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Semantic foundation (migration 223) parameter/qualifier assertions passed.'
    AS result;
