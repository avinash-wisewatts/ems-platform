-- ============================================================================
-- File:
--   scripts/test/assert_asset_relationship_foundation.sql
--
-- Purpose:
--   Regression test for migration 225 (Phase 2 Slice 2B-i/2B-ii: Asset
--   relationship-type foundation + metadata.asset_relationships). Proves
--   exactly the sixteen approved contracts:
--
--     1.  Valid COMPONENT_OF relationship succeeds.
--     2.  Valid PART_OF relationship succeeds.
--     3.  Valid DRIVEN_BY relationship succeeds.
--     4.  Valid SUPPLIED_BY relationship succeeds.
--     5.  Invalid relationship type is rejected.
--     6.  Cross-tenant relationship is rejected.
--     7.  Invalid asset FK is rejected.
--     8.  Historical DRIVEN_BY replacement with non-overlapping ranges succeeds.
--     9.  Overlapping DRIVEN_BY relationships for the same driven asset rejected.
--     10. COMPONENT_OF cycle is rejected.
--     11. An unrelated relationship type does not falsely trigger the cycle rule.
--     12. Existing assets.parent_asset_id behavior remains unchanged.
--     13. Existing assets.space_id remains unchanged.
--     14. No LOCATED_IN relationship infrastructure is introduced.
--     15. Many-to-many relationships are allowed where appropriate.
--     16. Energy subsystem regression/safety checks pass.
--     17. organization_id mismatched against the owning assets' actual
--         organization is rejected on INSERT (tenant-isolation fix).
--     18. UPDATE of organization_id to a different tenant is rejected.
--     19. UPDATE of from_asset_id to a cross-tenant asset is rejected.
--     20. UPDATE of to_asset_id to a cross-tenant asset is rejected.
--
--   All fixture data (organizations/sites/assets) is created inside this
--   test's own transaction and rolled back at the end; nothing persists.
--
-- Failure behavior:
--   Any assertion failure raises an exception and causes the test runner
--   to fail.
-- ============================================================================

BEGIN;


-- ------------------------------------------------------------------
-- Shared fixtures: two organizations (one for cross-tenant testing),
-- one site each, and a small set of assets covering every contract.
-- ------------------------------------------------------------------

DO $$
DECLARE
    org_1    UUID := 'd1000000-0000-0000-0000-000000000001';
    org_2    UUID := 'd1000000-0000-0000-0000-000000000002';
    site_1   UUID := 'd2000000-0000-0000-0000-000000000001';
    site_2   UUID := 'd2000000-0000-0000-0000-000000000002';
BEGIN
    INSERT INTO metadata.organizations (id, name, code)
    VALUES
        (org_1, 'Phase 2 Slice 2B Test Org 1', 'PH2B_ORG_1'),
        (org_2, 'Phase 2 Slice 2B Test Org 2', 'PH2B_ORG_2');

    INSERT INTO metadata.sites (id, organization_id, name, code)
    VALUES
        (site_1, org_1, 'Phase 2 Slice 2B Test Site 1', 'PH2B_SITE_1'),
        (site_2, org_2, 'Phase 2 Slice 2B Test Site 2', 'PH2B_SITE_2');

    INSERT INTO metadata.assets (id, organization_id, site_id, name, metering_requirement)
    VALUES
        ('d6000000-0000-0000-0000-000000000001', org_1, site_1, 'Fan',              'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000002', org_1, site_1, 'Motor 1',          'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000003', org_1, site_1, 'Motor 2',          'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000004', org_1, site_1, 'Bearing',          'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000005', org_1, site_1, 'AHU',              'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000006', org_1, site_1, 'Electrical Panel', 'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000007', org_1, site_1, 'Part',             'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000008', org_1, site_1, 'Whole',            'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000009', org_1, site_1, 'Cycle A',          'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000010', org_1, site_1, 'Cycle B',          'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000011', org_1, site_1, 'Shared Motor',     'NOT_REQUIRED'),
        ('d6000000-0000-0000-0000-000000000012', org_1, site_1, 'Fan B',            'NOT_REQUIRED');

    INSERT INTO metadata.assets (id, organization_id, site_id, name, metering_requirement)
    VALUES ('d6000000-0000-0000-0000-000000000099', org_2, site_2, 'Other-Org Asset', 'NOT_REQUIRED');
END;
$$;


-- ------------------------------------------------------------------
-- 1. Valid COMPONENT_OF relationship succeeds.
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000004', 'd6000000-0000-0000-0000-000000000002', 'COMPONENT_OF', '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000004'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000002'
          AND relationship_type = 'COMPONENT_OF'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: valid COMPONENT_OF relationship did not persist';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 2. Valid PART_OF relationship succeeds.
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000007', 'd6000000-0000-0000-0000-000000000008', 'PART_OF', '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000007'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000008'
          AND relationship_type = 'PART_OF'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: valid PART_OF relationship did not persist';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3. Valid DRIVEN_BY relationship succeeds. (Fan DRIVEN_BY Motor 1)
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000002', 'DRIVEN_BY', '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000001'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000002'
          AND relationship_type = 'DRIVEN_BY'
          AND effective_to IS NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: valid DRIVEN_BY relationship did not persist';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 4. Valid SUPPLIED_BY relationship succeeds. (AHU SUPPLIED_BY Panel)
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000005', 'd6000000-0000-0000-0000-000000000006', 'SUPPLIED_BY', '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000005'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000006'
          AND relationship_type = 'SUPPLIED_BY'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: valid SUPPLIED_BY relationship did not persist';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 5. Invalid relationship type is rejected.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
        VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000009', 'd6000000-0000-0000-0000-000000000010', 'NOT_A_REAL_TYPE', '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: invalid relationship_type was accepted';
    EXCEPTION
        WHEN foreign_key_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST FAILURE: expected foreign_key_violation for invalid relationship_type, got SQLSTATE % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected a foreign-key violation on relationship_type, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 6. Cross-tenant relationship is rejected.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
        VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000099', 'DRIVEN_BY', '2026-03-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: cross-tenant relationship was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%same organization%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the tenant-safety trigger message, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the cross-tenant relationship to be rejected, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 7. Invalid asset FK is rejected.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
        VALUES ('d1000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'd6000000-0000-0000-0000-000000000002', 'DRIVEN_BY', '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: non-existent from_asset_id was accepted';
    EXCEPTION
        WHEN foreign_key_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST FAILURE: expected foreign_key_violation for invalid asset FK, got SQLSTATE % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected a foreign-key violation on from_asset_id, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 8. Historical DRIVEN_BY replacement with non-overlapping effective
--    ranges succeeds: close Fan's binding to Motor 1, open a new one
--    to Motor 2 starting exactly where the old one ended.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_driver_before UUID;
    v_driver_after  UUID;
BEGIN
    UPDATE metadata.asset_relationships
    SET effective_to = '2026-02-01T00:00:00Z'
    WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000001'
      AND relationship_type = 'DRIVEN_BY'
      AND effective_to IS NULL;

    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000003', 'DRIVEN_BY', '2026-02-01T00:00:00Z');

    SELECT to_asset_id INTO v_driver_before FROM metadata.asset_relationships
    WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000001' AND relationship_type = 'DRIVEN_BY'
      AND effective_range @> '2026-01-15T00:00:00Z'::TIMESTAMPTZ;

    SELECT to_asset_id INTO v_driver_after FROM metadata.asset_relationships
    WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000001' AND relationship_type = 'DRIVEN_BY'
      AND effective_range @> '2026-03-01T00:00:00Z'::TIMESTAMPTZ;

    IF v_driver_before IS DISTINCT FROM 'd6000000-0000-0000-0000-000000000002'::UUID THEN
        RAISE EXCEPTION 'TEST FAILURE: driver before the historical replacement should be Motor 1, got %', v_driver_before;
    END IF;
    IF v_driver_after IS DISTINCT FROM 'd6000000-0000-0000-0000-000000000003'::UUID THEN
        RAISE EXCEPTION 'TEST FAILURE: driver after the historical replacement should be Motor 2, got %', v_driver_after;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 9. Overlapping DRIVEN_BY relationships for the same driven asset
--    are rejected.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        -- Overlaps Fan's current [2026-02-01, infinity) -> Motor 2 binding.
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from, effective_to)
        VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000011', 'DRIVEN_BY', '2026-02-15T00:00:00Z', '2026-02-20T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: overlapping DRIVEN_BY relationship was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLSTATE <> '23P01' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected exclusion_violation (23P01), got SQLSTATE % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected ex_asset_relationships_driven_by_exclusive to raise, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 10. COMPONENT_OF cycle is rejected. (Cycle A -> Cycle B, then
--     attempt Cycle B -> Cycle A, same type)
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000009', 'd6000000-0000-0000-0000-000000000010', 'COMPONENT_OF', '2026-01-01T00:00:00Z');

    BEGIN
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
        VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000010', 'd6000000-0000-0000-0000-000000000009', 'COMPONENT_OF', '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: a COMPONENT_OF cycle was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%would create a cycle%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the cycle-prevention trigger message, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the COMPONENT_OF cycle to be rejected, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 11. An unrelated relationship type does not falsely trigger the
--     COMPONENT_OF cycle rule: Cycle A COMPONENT_OF Cycle B already
--     exists (from test 10); a SUPPLIED_BY from Cycle B back to
--     Cycle A must succeed (different type, no false cycle).
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000010', 'd6000000-0000-0000-0000-000000000009', 'SUPPLIED_BY', '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000010'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000009'
          AND relationship_type = 'SUPPLIED_BY'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: an unrelated relationship type was incorrectly rejected as a false cycle';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 12. Existing assets.parent_asset_id behavior remains unchanged:
--     the pre-existing trg_validate_asset_hierarchy trigger still
--     exists and still rejects a self-parent assignment.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'trg_validate_asset_hierarchy'
          AND tgrelid = 'metadata.assets'::regclass
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: trg_validate_asset_hierarchy is missing -- existing parent_asset_id behavior was altered';
    END IF;

    BEGIN
        UPDATE metadata.assets
        SET parent_asset_id = id
        WHERE id = 'd6000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'TEST FAILURE: self-parent assignment was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the existing self-parent guard to raise, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 13. Existing assets.space_id remains unchanged: the column still
--     exists, nullable, with its existing FK to metadata.spaces.
-- ------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'metadata' AND table_name = 'assets'
          AND column_name = 'space_id' AND is_nullable = 'YES'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: metadata.assets.space_id is missing or was made NOT NULL -- unexpected change';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 14. No LOCATED_IN relationship infrastructure is introduced.
-- ------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM config.asset_relationship_types WHERE code = 'LOCATED_IN'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: LOCATED_IN was unexpectedly seeded into config.asset_relationship_types';
    END IF;

    IF to_regclass('metadata.asset_space_relationships') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: metadata.asset_space_relationships was unexpectedly created -- out of scope for this slice';
    END IF;

    IF to_regclass('config.asset_relationship_type_compatibility') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: a relationship-type compatibility table was unexpectedly created -- deferred per approved design';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 15. Many-to-many relationships are allowed where appropriate:
--     two different assets both DRIVEN_BY the same motor (non-
--     exclusive from the "to" side), and one asset with two
--     different NON_EXCLUSIVE-type relationships to the same target.
-- ------------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000012', 'd6000000-0000-0000-0000-000000000011', 'DRIVEN_BY', '2026-01-01T00:00:00Z');

    -- Motor 1 (already a DRIVEN_BY target for the Fan historically, test 8)
    -- also becomes a SUPPLIED_BY target for the AHU's panel chain --
    -- proves the same asset can be the "to" side of multiple relationship
    -- types/rows without any blanket uniqueness interfering.
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000006', 'd6000000-0000-0000-0000-000000000002', 'SUPPLIED_BY', '2026-01-01T00:00:00Z');

    IF (SELECT count(*) FROM metadata.asset_relationships WHERE to_asset_id = 'd6000000-0000-0000-0000-000000000011' AND relationship_type = 'DRIVEN_BY') <> 1 THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the Shared Motor DRIVEN_BY binding to exist exactly once';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000006' AND to_asset_id = 'd6000000-0000-0000-0000-000000000002' AND relationship_type = 'SUPPLIED_BY'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: many-to-many NON_EXCLUSIVE relationship was unexpectedly rejected';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 16. Energy subsystem regression/safety checks pass: core energy
--     objects are unaffected, and nothing in this migration created
--     a dependency from energy processing onto the new tables.
-- ------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('telemetry.energy_measurements') IS NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: telemetry.energy_measurements is missing -- energy subsystem regression';
    END IF;

    IF to_regprocedure('telemetry.load_energy_measurements_incremental(interval,interval)') IS NULL THEN
        RAISE EXCEPTION 'TEST FAILURE: telemetry.load_energy_measurements_incremental is missing -- energy subsystem regression';
    END IF;

    -- No energy object may reference the new relationship tables.
    IF EXISTS (
        SELECT 1
        FROM pg_depend dep
        JOIN pg_rewrite rw ON rw.oid = dep.objid
        JOIN pg_class dependent ON dependent.oid = rw.ev_class
        JOIN pg_namespace dependent_ns ON dependent_ns.oid = dependent.relnamespace
        JOIN pg_class ref ON ref.oid = dep.refobjid
        WHERE dep.deptype = 'n'
          AND ref.relname IN ('asset_relationships', 'asset_relationship_types')
          AND dependent_ns.nspname IN ('telemetry', 'analytics')
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: an energy/telemetry/analytics object unexpectedly depends on the new relationship tables';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 17. organization_id mismatched against the owning assets' actual
--     organization is rejected on INSERT, even though from_asset_id
--     and to_asset_id both belong to the same (other) organization as
--     each other. Proves the redundant organization_id column cannot
--     drift from the assets' real ownership. (Bearing PART_OF AHU,
--     both org_1, but organization_id claimed as org_2.)
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
        VALUES ('d1000000-0000-0000-0000-000000000002', 'd6000000-0000-0000-0000-000000000004', 'd6000000-0000-0000-0000-000000000005', 'PART_OF', '2026-01-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: a relationship with organization_id mismatched against its assets'' actual organization was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%does not match the owning organization%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the organization_id-mismatch trigger message, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the organization_id mismatch to be rejected, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 18. UPDATE of organization_id to a different tenant is rejected.
--     First establish a valid same-tenant relationship (Bearing
--     PART_OF AHU, org_1), then attempt to reassign it to org_2.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    INSERT INTO metadata.asset_relationships (organization_id, from_asset_id, to_asset_id, relationship_type, effective_from)
    VALUES ('d1000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000004', 'd6000000-0000-0000-0000-000000000005', 'PART_OF', '2026-01-01T00:00:00Z');

    BEGIN
        UPDATE metadata.asset_relationships
        SET organization_id = 'd1000000-0000-0000-0000-000000000002'
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000004'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000005'
          AND relationship_type = 'PART_OF';
        RAISE EXCEPTION 'TEST FAILURE: UPDATE of organization_id to a different tenant was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%does not match the owning organization%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the organization_id-mismatch trigger message on UPDATE, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the cross-tenant organization_id UPDATE to be rejected, none occurred';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_relationships
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000004'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000005'
          AND relationship_type = 'PART_OF'
          AND organization_id = 'd1000000-0000-0000-0000-000000000001'
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: the row''s organization_id was mutated despite the rejected UPDATE';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 19. UPDATE of from_asset_id to a cross-tenant asset is rejected.
--     Reuses the Bearing PART_OF AHU row from test 18.
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        UPDATE metadata.asset_relationships
        SET from_asset_id = 'd6000000-0000-0000-0000-000000000099'
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000004'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000005'
          AND relationship_type = 'PART_OF';
        RAISE EXCEPTION 'TEST FAILURE: UPDATE of from_asset_id to a cross-tenant asset was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%same organization%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the tenant-safety trigger message on from_asset_id UPDATE, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the cross-tenant from_asset_id UPDATE to be rejected, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 20. UPDATE of to_asset_id to a cross-tenant asset is rejected.
--     Reuses the same Bearing PART_OF AHU row (still intact, since
--     tests 18 and 19 were both rejected and rolled back).
-- ------------------------------------------------------------------
DO $$
DECLARE
    v_raised BOOLEAN := FALSE;
BEGIN
    BEGIN
        UPDATE metadata.asset_relationships
        SET to_asset_id = 'd6000000-0000-0000-0000-000000000099'
        WHERE from_asset_id = 'd6000000-0000-0000-0000-000000000004'
          AND to_asset_id = 'd6000000-0000-0000-0000-000000000005'
          AND relationship_type = 'PART_OF';
        RAISE EXCEPTION 'TEST FAILURE: UPDATE of to_asset_id to a cross-tenant asset was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            IF SQLERRM NOT LIKE '%same organization%' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected the tenant-safety trigger message on to_asset_id UPDATE, got: %', SQLERRM;
            END IF;
            v_raised := TRUE;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected the cross-tenant to_asset_id UPDATE to be rejected, none occurred';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Phase 2 Slice 2B (migration 225) asset relationship-foundation assertions passed.'
    AS result;
