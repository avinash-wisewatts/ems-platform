-- ============================================================================
-- Controlled rollback for migration 225 (Phase 2 Slice 2B-i/2B-ii: Asset
-- relationship-type foundation + metadata.asset_relationships).
--
-- This is NOT a bare `DROP TABLE ... CASCADE`. It:
--   1. Verifies nothing references metadata.asset_relationships or
--      config.asset_relationship_types beyond what migration 225 itself
--      created, and refuses to proceed if anything else does.
--   2. Verifies metadata.asset_relationships still has zero rows (it was
--      empty when 225 was applied, and nothing in this slice populates
--      it). If non-empty, the rollback refuses -- dropping a table with
--      real relationship data is not something this script will do
--      silently.
--   3. Only if both checks pass, removes exactly what migration 225 added:
--      the trigger, the trigger function, metadata.asset_relationships
--      (with its constraints/indexes), and config.asset_relationship_types
--      (DROP TABLE with NO CASCADE on both -- if step 1 somehow missed a
--      dependency, this fails loudly instead of cascading).
--
-- Run manually (`psql -f`), inside a transaction, only with explicit
-- authorization. Not invoked by any migration, job, or CI step.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_foreign_dep_count INTEGER;
    v_foreign_dep_names TEXT;
    v_relationship_rows INTEGER;
BEGIN
    -- ------------------------------------------------------------------
    -- 1. Refuse if anything other than this migration's own objects
    --    depends on metadata.asset_relationships or
    --    config.asset_relationship_types.
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
      AND ref.relname IN ('asset_relationships', 'asset_relationship_types')
      AND ref.relnamespace IN ('metadata'::regnamespace, 'config'::regnamespace)
      AND dependent.relname NOT IN ('asset_relationships', 'asset_relationship_types');

    IF v_foreign_dep_count > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: % object(s) depend on metadata.asset_relationships or config.asset_relationship_types (%). Resolve those dependencies first -- this script will not cascade.',
            v_foreign_dep_count, v_foreign_dep_names;
    END IF;

    -- ------------------------------------------------------------------
    -- 2. Refuse if metadata.asset_relationships now has data. It was
    --    empty when 225 was applied; a non-zero count means something
    --    else has built on this foundation since, and dropping would
    --    destroy it silently.
    -- ------------------------------------------------------------------
    SELECT count(*) INTO v_relationship_rows FROM metadata.asset_relationships;

    IF v_relationship_rows > 0 THEN
        RAISE EXCEPTION
            'Rollback refused: metadata.asset_relationships has % row(s). It was empty when migration 225 was applied; refusing to drop a table that may hold real relationship data.',
            v_relationship_rows;
    END IF;

    RAISE NOTICE 'Rollback preconditions satisfied: no foreign dependencies, asset_relationships is empty. Proceeding.';
END;
$$;

-- Only reached if the DO block above did not raise.
DROP TRIGGER IF EXISTS trg_validate_asset_relationship ON metadata.asset_relationships;
DROP FUNCTION IF EXISTS metadata.validate_asset_relationship();

DROP TABLE metadata.asset_relationships;       -- intentionally no CASCADE
DROP TABLE config.asset_relationship_types;    -- intentionally no CASCADE

COMMIT;

SELECT 'Migration 225 rolled back: metadata.asset_relationships, config.asset_relationship_types, and their trigger/function removed.' AS result;
