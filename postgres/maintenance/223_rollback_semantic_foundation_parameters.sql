-- ============================================================================
-- Controlled rollback for migration 223 (Phase 1 semantic foundation:
-- config.parameters, metadata.logical_points.parameter_id/qualifier).
--
-- This is NOT a bare `DROP TABLE config.parameters CASCADE`. It:
--   1. Verifies nothing other than metadata.logical_points.parameter_id
--      (the one FK migration 223 itself created) references
--      config.parameters, and refuses to proceed if anything else does.
--   2. Verifies the number of mapped logical_points matches exactly what
--      migration 223 created (48). If it does not -- e.g. a later phase
--      mapped more points on top of this foundation -- the rollback
--      refuses, since silently dropping those columns would destroy work
--      this script did not create and cannot know is safe to lose.
--   3. Only if both checks pass, removes exactly the objects migration 223
--      added: the two new columns + their constraint/index on
--      metadata.logical_points, and the config.parameters table itself
--      (DROP TABLE with NO CASCADE -- if step 1's check somehow missed a
--      dependency, this fails loudly instead of cascading).
--
-- Deliberately NOT removed: the reference-data rows migration 223 added
-- (config.engineering_units 'VAR'/'VA'/'kVAh', config.point_categories
-- 'Illuminance'/'Occupancy'). These are harmless dormant lookup rows in
-- exactly the same state config.point_categories itself was in before this
-- migration (defined, unreferenced) -- deleting them is unnecessary risk
-- for no benefit, and something else may have started using them.
--
-- Run manually (`psql -f`), inside a transaction, only with explicit
-- authorization. Not invoked by any migration, job, or CI step.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_foreign_fk_count INTEGER;
    v_foreign_fk_names TEXT;
    v_mapped_count     INTEGER;
BEGIN
    -- ------------------------------------------------------------------
    -- 1. Refuse if anything other than metadata.logical_points.parameter_id
    --    has a foreign key into config.parameters.
    -- ------------------------------------------------------------------
    SELECT count(*),
           string_agg(format('%I.%I.%I', tc.table_schema, tc.table_name, kcu.column_name), ', ')
    INTO v_foreign_fk_count, v_foreign_fk_names
    FROM information_schema.table_constraints tc
    JOIN information_schema.constraint_column_usage ccu
      ON ccu.constraint_name = tc.constraint_name
     AND ccu.constraint_schema = tc.constraint_schema
    JOIN information_schema.key_column_usage kcu
      ON kcu.constraint_name = tc.constraint_name
     AND kcu.constraint_schema = tc.constraint_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_schema = 'config'
      AND ccu.table_name = 'parameters'
      AND NOT (tc.table_schema = 'metadata' AND tc.table_name = 'logical_points' AND kcu.column_name = 'parameter_id');

    IF v_foreign_fk_count > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: % other foreign key(s) reference config.parameters (%). Resolve those dependencies first -- this script will not cascade.',
            v_foreign_fk_count, v_foreign_fk_names;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Refuse if mapped-point coverage has grown beyond what migration
    --    223 itself created (48). A different count means something else
    --    has built on this foundation since; dropping the columns would
    --    destroy that work silently.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_mapped_count
    FROM metadata.logical_points
    WHERE parameter_id IS NOT NULL;

    IF v_mapped_count <> 48 THEN
        RAISE EXCEPTION
            'Rollback refused: % logical_points currently have parameter_id set; migration 223 mapped exactly 48. Investigate what changed this before rolling back -- refusing to drop columns that may hold data this script did not create.',
            v_mapped_count;
    END IF;

    RAISE NOTICE 'Rollback preconditions satisfied: no foreign dependencies on config.parameters, mapped-point count matches migration 223 exactly (48). Proceeding.';
END;
$$;

-- Only reached if the DO block above did not raise.
ALTER TABLE metadata.logical_points
    DROP CONSTRAINT IF EXISTS chk_logical_points_qualifier_requires_parameter;

DROP INDEX IF EXISTS metadata.uq_logical_points_parameter_qualifier;

ALTER TABLE metadata.logical_points
    DROP COLUMN IF EXISTS qualifier,
    DROP COLUMN IF EXISTS parameter_id;

DROP TABLE config.parameters;  -- intentionally no CASCADE

COMMIT;

SELECT 'Migration 223 rolled back: config.parameters and metadata.logical_points.parameter_id/qualifier removed. Reference-data rows (VAR/VA/kVAh units, Illuminance/Occupancy categories) intentionally left in place.' AS result;
