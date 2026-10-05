-- ============================================================================
-- File:
--   scripts/test/assert_canonical_measurement_groups.sql
--
-- Purpose:
--   Regression test for migration 254 (ADR-018 Amendment 2 correction, v3
--   design: config.canonical_measurement_groups, config.parameters.
--   measurement_group_id, the ACTIVE_POWER/REACTIVE_POWER_TOTAL/
--   APPARENT_POWER_TOTAL/APPARENT_ENERGY_TOTAL coverage backfill).
--
--   This test proves, as five separate concerns:
--     1. GROUP MEMBERSHIP -- every approved parameter resolves to exactly
--        the approved group (positive spot-checks, including the two
--        cases that prove this is NOT a single generic "one device per
--        family" rule: Energy's three independent groups, and the
--        CURRENT_THD carve-out into Power Quality rather than Current).
--     2. UNGOVERNED PARAMETERS -- parameters never named by the approved
--        v3 mapping remain measurement_group_id IS NULL. This is the
--        expected, correct state, not something to patch.
--     3. LOGICAL POINT COVERAGE -- the four points that previously had no
--        (or incomplete) config.parameters mapping now resolve correctly.
--     4. DISPLAY CATEGORIES UNTOUCHED -- config.point_categories /
--        parameter_category_id are unaffected by this migration.
--     5. REGRESSION -- measurement_group_id remains nullable (no
--        completeness constraint was introduced), and pre-existing
--        config.parameters rows/columns are unaffected.
--
--   All changes made inside this test run inside one transaction that is
--   rolled back at the end; nothing persists.
-- ============================================================================

BEGIN;


-- ------------------------------------------------------------------
-- 1a. Group membership -- every approved parameter resolves to its
--     approved group.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_bad_mappings TEXT;
BEGIN
    SELECT string_agg(expected.parameter_code || ' -> expected group ' || expected.group_code || ', got ' || COALESCE(g.code, 'NULL'), '; ')
    INTO v_bad_mappings
    FROM (VALUES
        ('ENERGY_IMPORT',        'ENERGY_IMPORT'),
        ('ENERGY_EXPORT',        'ENERGY_EXPORT'),
        ('APPARENT_ENERGY',      'ENERGY_APPARENT'),
        ('ACTIVE_POWER',         'POWER'),
        ('REACTIVE_POWER',       'POWER'),
        ('APPARENT_POWER',       'POWER'),
        ('POWER_FACTOR',         'POWER_QUALITY'),
        ('FREQUENCY',            'POWER_QUALITY'),
        ('PHASE_ANGLE',          'POWER_QUALITY'),
        ('CURRENT_THD',          'POWER_QUALITY'),
        ('VOLTAGE_LINE_NEUTRAL', 'VOLTAGE'),
        ('VOLTAGE_LINE_LINE',    'VOLTAGE'),
        ('CURRENT',              'CURRENT')
    ) AS expected(parameter_code, group_code)
    LEFT JOIN config.parameters p ON p.code = expected.parameter_code
    LEFT JOIN config.canonical_measurement_groups g ON g.id = p.measurement_group_id
    WHERE g.code IS DISTINCT FROM expected.group_code;

    IF v_bad_mappings IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: parameter->group mapping(s) incorrect: %', v_bad_mappings;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1b. Not a single generic rule -- Energy resolves to THREE DISTINCT
--     groups (Import/Export/Apparent), proving Energy sources are
--     independently governed, not collapsed into one "Energy" bucket
--     the way Power/PQ/Voltage/Current each collapse into one.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_distinct_energy_groups INTEGER;
BEGIN
    SELECT count(DISTINCT p.measurement_group_id) INTO v_distinct_energy_groups
    FROM config.parameters p
    WHERE p.code IN ('ENERGY_IMPORT', 'ENERGY_EXPORT', 'APPARENT_ENERGY');

    IF v_distinct_energy_groups <> 3 THEN
        RAISE EXCEPTION 'TEST FAILURE: expected Energy Import/Export/Apparent to resolve to 3 distinct measurement groups, found %', v_distinct_energy_groups;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1c. Not a single generic rule -- Power's three parameters (Active/
--     Reactive/Apparent) resolve to the SAME single group, proving they
--     ARE collapsed into one enforcement unit (opposite of Energy).
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_distinct_power_groups INTEGER;
BEGIN
    SELECT count(DISTINCT p.measurement_group_id) INTO v_distinct_power_groups
    FROM config.parameters p
    WHERE p.code IN ('ACTIVE_POWER', 'REACTIVE_POWER', 'APPARENT_POWER');

    IF v_distinct_power_groups <> 1 THEN
        RAISE EXCEPTION 'TEST FAILURE: expected Active/Reactive/Apparent Power to resolve to exactly 1 shared measurement group, found %', v_distinct_power_groups;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 1d. CURRENT_THD carve-out -- belongs to Power Quality, NOT Current,
--     despite its display category still reading 'Current'.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_current_thd_group TEXT;
    v_current_group      TEXT;
BEGIN
    SELECT g.code INTO v_current_thd_group
    FROM config.parameters p
    JOIN config.canonical_measurement_groups g ON g.id = p.measurement_group_id
    WHERE p.code = 'CURRENT_THD';

    SELECT g.code INTO v_current_group
    FROM config.parameters p
    JOIN config.canonical_measurement_groups g ON g.id = p.measurement_group_id
    WHERE p.code = 'CURRENT';

    IF v_current_thd_group IS DISTINCT FROM 'POWER_QUALITY' THEN
        RAISE EXCEPTION 'TEST FAILURE: expected CURRENT_THD measurement group POWER_QUALITY, got %', v_current_thd_group;
    END IF;
    IF v_current_thd_group = v_current_group THEN
        RAISE EXCEPTION 'TEST FAILURE: CURRENT_THD must NOT share a measurement group with CURRENT';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 2. Ungoverned parameters remain measurement_group_id IS NULL -- the
--    expected, correct state, not a failure to be patched.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_unexpectedly_grouped TEXT;
BEGIN
    SELECT string_agg(p.code, ', ') INTO v_unexpectedly_grouped
    FROM config.parameters p
    WHERE p.code IN (
        'TEMPERATURE', 'HUMIDITY', 'ILLUMINANCE', 'BATTERY_VOLTAGE',
        'OCCUPANCY_ACTIVITY', 'OCCUPANCY_TIME_SINCE_LAST_EVENT'
    )
    AND p.measurement_group_id IS NOT NULL;

    IF v_unexpectedly_grouped IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: ungoverned parameter(s) unexpectedly have a measurement_group_id: %', v_unexpectedly_grouped;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3. Logical point coverage -- the four previously-unmapped/
--    incompletely-mapped points now resolve to the correct parameter
--    and qualifier.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_bad_point_mappings TEXT;
BEGIN
    SELECT string_agg(expected.logical_point_name || ' -> expected ' || expected.parameter_code || '/' || expected.qualifier || ', got ' || COALESCE(p.code, 'NULL') || '/' || COALESCE(lp.qualifier, 'NULL'), '; ')
    INTO v_bad_point_mappings
    FROM (VALUES
        ('ACTIVE_POWER_L1',      'ACTIVE_POWER',    'L1'),
        ('ACTIVE_POWER_L2',      'ACTIVE_POWER',    'L2'),
        ('ACTIVE_POWER_L3',      'ACTIVE_POWER',    'L3'),
        ('ACTIVE_POWER_TOTAL',   'ACTIVE_POWER',    'TOTAL'),
        ('REACTIVE_POWER_TOTAL', 'REACTIVE_POWER',  'TOTAL'),
        ('APPARENT_POWER_TOTAL', 'APPARENT_POWER',  'TOTAL'),
        ('APPARENT_ENERGY_TOTAL','APPARENT_ENERGY', 'TOTAL')
    ) AS expected(logical_point_name, parameter_code, qualifier)
    LEFT JOIN metadata.logical_points lp ON lp.name = expected.logical_point_name
    LEFT JOIN config.parameters p ON p.id = lp.parameter_id
    WHERE p.code IS DISTINCT FROM expected.parameter_code
       OR lp.qualifier IS DISTINCT FROM expected.qualifier;

    IF v_bad_point_mappings IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: logical_point mapping(s) incorrect: %', v_bad_point_mappings;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 4. Display categories untouched -- CURRENT_THD, FREQUENCY, etc. keep
--    exactly the parameter_category_id state migration 223 left them in
--    (migration 254 itself does not assign or alter any display
--    category). POWER_FACTOR is deliberately NOT asserted NULL here any
--    more: migration 262 (a later, separate, approved change) legitimately
--    assigned it to "Power Quality" -- that migration has its own
--    dedicated regression test
--    (assert_active_power_power_factor_display_category.sql). FREQUENCY
--    remains genuinely unassigned and untouched by both 254 and 262, so
--    it is used here instead to keep testing migration 254's own scope.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_current_thd_category TEXT;
    v_frequency_category TEXT;
BEGIN
    SELECT pc.name INTO v_current_thd_category
    FROM config.parameters p
    LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'CURRENT_THD';

    IF v_current_thd_category IS DISTINCT FROM 'Current' THEN
        RAISE EXCEPTION 'TEST FAILURE: CURRENT_THD parameter_category_id must remain unchanged (Current), got %', v_current_thd_category;
    END IF;

    SELECT pc.name INTO v_frequency_category
    FROM config.parameters p
    LEFT JOIN config.point_categories pc ON pc.id = p.parameter_category_id
    WHERE p.code = 'FREQUENCY';

    IF v_frequency_category IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: FREQUENCY parameter_category_id must remain NULL (display categorization still an open product decision), got %', v_frequency_category;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 5a. Regression -- measurement_group_id remains nullable; a brand-new,
--     never-classified parameter may be inserted with it NULL with no
--     error.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_is_nullable TEXT;
BEGIN
    SELECT is_nullable INTO v_is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'config'
      AND table_name = 'parameters'
      AND column_name = 'measurement_group_id';

    IF v_is_nullable <> 'YES' THEN
        RAISE EXCEPTION 'TEST FAILURE: config.parameters.measurement_group_id must remain nullable, found is_nullable=%', v_is_nullable;
    END IF;

    INSERT INTO config.parameters (code, name, description)
    VALUES ('TEST_MIGRATION_254_UNGROUPED_PARAMETER', 'Test fixture', 'Proves an ungrouped parameter is valid.');

    IF NOT EXISTS (
        SELECT 1 FROM config.parameters
        WHERE code = 'TEST_MIGRATION_254_UNGROUPED_PARAMETER'
          AND measurement_group_id IS NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: a brand-new parameter with no group assignment should insert cleanly with measurement_group_id NULL';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 5b. Regression -- exactly 7 canonical_measurement_groups exist (no
--     accidental extra/duplicate group), and pre-existing parameters
--     (ENERGY_IMPORT etc.) are still present after this migration.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_group_count INTEGER;
    v_missing_count INTEGER;
BEGIN
    SELECT count(*) INTO v_group_count FROM config.canonical_measurement_groups;
    IF v_group_count <> 7 THEN
        RAISE EXCEPTION 'TEST FAILURE: expected exactly 7 config.canonical_measurement_groups rows, found %', v_group_count;
    END IF;

    SELECT count(*) INTO v_missing_count
    FROM (VALUES ('ENERGY_IMPORT'), ('ENERGY_EXPORT'), ('CURRENT'), ('VOLTAGE_LINE_NEUTRAL')) AS expected(code)
    WHERE NOT EXISTS (
        SELECT 1 FROM config.parameters p WHERE p.code = expected.code
    );

    IF v_missing_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILURE: pre-existing config.parameters rows appear to be missing after migration 254 -- regression in an unrelated row';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Canonical measurement groups (migration 254) assertions passed.'
    AS result;
