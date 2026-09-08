-- ============================================================================
-- Controlled rollback for migration 224 (Phase 2 Slice 2A: asset_points
-- effective-dating retrofit, metadata.space_points).
--
-- This is NOT a bare `DROP TABLE ... CASCADE`. It:
--   1. Verifies nothing references the new asset_points columns or
--      metadata.space_points beyond what migration 224 itself created, and
--      refuses to proceed if anything else does.
--   2. Verifies metadata.asset_points and metadata.space_points still have
--      zero rows (both were empty when 224 was applied and nothing in this
--      slice populates them). If either is non-empty, the rollback refuses
--      -- dropping columns/a table with real data in them is not something
--      this script will do silently.
--   3. Only if both checks pass, removes exactly what migration 224 added:
--      the exclusion/check constraints and the three new columns on
--      asset_points, and the space_points table itself (DROP TABLE with NO
--      CASCADE -- if step 1 somehow missed a dependency, this fails loudly
--      instead of cascading).
--
-- Run manually (`psql -f`), inside a transaction, only with explicit
-- authorization. Not invoked by any migration, job, or CI step.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_foreign_dep_count INTEGER;
    v_foreign_dep_names TEXT;
    v_asset_points_rows INTEGER;
    v_space_points_rows INTEGER;
BEGIN
    -- ------------------------------------------------------------------
    -- 1. Refuse if anything other than this migration's own objects
    --    depends on metadata.space_points.
    -- ------------------------------------------------------------------
    SELECT count(*),
           string_agg(format('%I.%I', dependent_ns.nspname, dependent.relname), ', ')
    INTO v_foreign_dep_count, v_foreign_dep_names
    FROM pg_depend dep
    JOIN pg_rewrite rw ON rw.oid = dep.objid
    JOIN pg_class dependent ON dependent.oid = rw.ev_class
    JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent.relnamespace
    JOIN pg_class ref ON ref.oid = dep.refobjid
    WHERE dep.deptype = 'n'
      AND ref.relname = 'space_points'
      AND ref.relnamespace = 'metadata'::regnamespace
      AND dependent.relname <> 'space_points';

    IF v_foreign_dep_count > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: % object(s) depend on metadata.space_points (%). Resolve those dependencies first -- this script will not cascade.',
            v_foreign_dep_count, v_foreign_dep_names;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Refuse if either table now has data. Both were empty when 224
    --    was applied; a non-zero count means something else has built on
    --    this foundation since, and dropping would destroy it silently.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_asset_points_rows FROM metadata.asset_points;
    SELECT count(*) INTO v_space_points_rows FROM metadata.space_points;

    IF v_asset_points_rows > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: metadata.asset_points has % row(s). It was empty when migration 224 was applied; refusing to drop columns that may hold real ownership data.',
            v_asset_points_rows;
    END IF;

    IF v_space_points_rows > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: metadata.space_points has % row(s). Refusing to drop a table with real data in it.',
            v_space_points_rows;
    END IF;

    RAISE NOTICE 'Rollback preconditions satisfied: no foreign dependencies on space_points, both tables empty. Proceeding.';
END;
$$;

-- Only reached if the DO block above did not raise.
ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS ex_asset_points_no_overlap;

ALTER TABLE metadata.asset_points
    DROP CONSTRAINT IF EXISTS ck_asset_points_effective_window;

DROP INDEX IF EXISTS metadata.idx_asset_points_point_effective;

ALTER TABLE metadata.asset_points
    DROP COLUMN IF EXISTS effective_range,
    DROP COLUMN IF EXISTS effective_to,
    DROP COLUMN IF EXISTS effective_from;

DROP TABLE metadata.space_points;  -- intentionally no CASCADE

COMMIT;

SELECT 'Migration 224 rolled back: metadata.asset_points effective-dating columns/constraints and metadata.space_points removed.' AS result;
