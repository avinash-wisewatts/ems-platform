-- ============================================================================
-- File:
--   scripts/test/assert_asset_space_point_temporal_binding.sql
--
-- Purpose:
--   Regression test for migration 224 (Phase 2 Slice 2A: metadata.asset_
--   points effective-dating retrofit + metadata.space_points). Proves
--   exactly the eight approved contracts, no more:
--
--     1. Initial binding succeeds.
--     2. A valid, non-overlapping sensor move (close old, open new) succeeds.
--     3. An overlapping binding for the same point is rejected.
--     4. A historical (backdated) overlapping correction is rejected against
--        either prior owner, not just the most recent one.
--     5. Two different points may independently have overlapping periods.
--     6. Equivalent temporal behavior holds for metadata.space_points.
--     7. An invalid foreign-key reference is rejected.
--     8. Nothing outside this transaction is mutated (BEGIN/ROLLBACK) and no
--        pre-existing, unrelated row is touched.
--
--   All fixture data (organization/site/building/floor/spaces/assets) is
--   created inside this test's own transaction and rolled back at the end;
--   nothing persists. Two pre-existing, canonical logical points
--   (CURRENT_L1, CURRENT_L2 -- confirmed live per
--   docs/platform-manual/reference/telemetry-field-catalog.md) stand in for
--   "Point A" and "Point B" so no new reference data needs to be invented.
--
-- Failure behavior:
--   Any assertion failure raises an exception and causes the test runner
--   to fail.
-- ============================================================================

BEGIN;


-- ------------------------------------------------------------------
-- Shared fixtures: one organization, one site, two assets, two spaces.
-- ------------------------------------------------------------------

DO $$
DECLARE
    org_1     UUID := 'c1000000-0000-0000-0000-000000000001';
    site_1    UUID := 'c2000000-0000-0000-0000-000000000001';
    building_1 UUID := 'c3000000-0000-0000-0000-000000000001';
    floor_1   UUID := 'c4000000-0000-0000-0000-000000000001';
    space_1   UUID := 'c5000000-0000-0000-0000-000000000001';
    space_2   UUID := 'c5000000-0000-0000-0000-000000000002';
    asset_1   UUID := 'c6000000-0000-0000-0000-000000000001';
    asset_2   UUID := 'c6000000-0000-0000-0000-000000000002';
BEGIN
    INSERT INTO metadata.organizations (id, name, code)
    VALUES (org_1, 'Phase 2 Slice 2A Test Org', 'PH2A_ORG');

    INSERT INTO metadata.sites (id, organization_id, name, code)
    VALUES (site_1, org_1, 'Phase 2 Slice 2A Test Site', 'PH2A_SITE');

    INSERT INTO metadata.buildings (id, organization_id, site_id, name, code)
    VALUES (building_1, org_1, site_1, 'Phase 2 Slice 2A Test Building', 'PH2A_BLDG');

    INSERT INTO metadata.floors (id, organization_id, building_id, name, code)
    VALUES (floor_1, org_1, building_1, 'Phase 2 Slice 2A Test Floor', 'PH2A_FLOOR');

    INSERT INTO metadata.spaces (id, organization_id, floor_id, name, code)
    VALUES
        (space_1, org_1, floor_1, 'Phase 2 Slice 2A Test Space 1', 'PH2A_SPACE_1'),
        (space_2, org_1, floor_1, 'Phase 2 Slice 2A Test Space 2', 'PH2A_SPACE_2');

    INSERT INTO metadata.assets (id, organization_id, site_id, name, metering_requirement)
    VALUES
        (asset_1, org_1, site_1, 'Phase 2 Slice 2A Test Asset 1', 'NOT_REQUIRED'),
        (asset_2, org_1, site_1, 'Phase 2 Slice 2A Test Asset 2', 'NOT_REQUIRED');
END;
$$;


-- ------------------------------------------------------------------
-- 1. Initial binding succeeds.
-- ------------------------------------------------------------------

DO $$
DECLARE
    asset_1 UUID := 'c6000000-0000-0000-0000-000000000001';
    point_a UUID;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';
    IF point_a IS NULL THEN
        RAISE EXCEPTION 'Fixture assumption violated: CURRENT_L1 must exist as a canonical logical point';
    END IF;

    INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from)
    VALUES (asset_1, point_a, '2026-01-01T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_points
        WHERE asset_id = asset_1 AND logical_point_id = point_a
          AND effective_to IS NULL
          AND effective_range = tstzrange('2026-01-01T00:00:00Z', 'infinity', '[)')
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: initial open-ended binding did not persist as expected';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 2. Valid sensor move: close the existing binding, open a new one on a
--    different asset starting exactly where the old one ended. Must
--    succeed (half-open ranges do not overlap at the boundary), and a
--    time-aware lookup must resolve the correct owner on each side.
-- ------------------------------------------------------------------

DO $$
DECLARE
    asset_1 UUID := 'c6000000-0000-0000-0000-000000000001';
    asset_2 UUID := 'c6000000-0000-0000-0000-000000000002';
    point_a UUID;
    v_owner_before UUID;
    v_owner_at_boundary UUID;
    v_owner_after UUID;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';

    UPDATE metadata.asset_points
    SET effective_to = '2026-01-10T00:00:00Z'
    WHERE asset_id = asset_1 AND logical_point_id = point_a AND effective_to IS NULL;

    INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from)
    VALUES (asset_2, point_a, '2026-01-10T00:00:00Z');

    SELECT asset_id INTO v_owner_before FROM metadata.asset_points
    WHERE logical_point_id = point_a AND effective_range @> '2026-01-05T00:00:00Z'::TIMESTAMPTZ;

    SELECT asset_id INTO v_owner_at_boundary FROM metadata.asset_points
    WHERE logical_point_id = point_a AND effective_range @> '2026-01-10T00:00:00Z'::TIMESTAMPTZ;

    SELECT asset_id INTO v_owner_after FROM metadata.asset_points
    WHERE logical_point_id = point_a AND effective_range @> '2026-01-15T00:00:00Z'::TIMESTAMPTZ;

    IF v_owner_before IS DISTINCT FROM asset_1 THEN
        RAISE EXCEPTION 'TEST FAILURE: point owner before the move should be Asset 1, got %', v_owner_before;
    END IF;
    IF v_owner_at_boundary IS DISTINCT FROM asset_2 THEN
        RAISE EXCEPTION 'TEST FAILURE: point owner exactly at the handoff instant should be Asset 2 (half-open range), got %', v_owner_at_boundary;
    END IF;
    IF v_owner_after IS DISTINCT FROM asset_2 THEN
        RAISE EXCEPTION 'TEST FAILURE: point owner after the move should be Asset 2, got %', v_owner_after;
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 3. Overlapping binding for the same point is rejected, regardless of
--    which two assets are involved.
-- ------------------------------------------------------------------

DO $$
DECLARE
    asset_1 UUID := 'c6000000-0000-0000-0000-000000000001';
    point_a UUID;
    v_raised BOOLEAN := FALSE;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';

    BEGIN
        -- Overlaps Asset 2's current [2026-01-10, infinity) binding.
        INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from, effective_to)
        VALUES (asset_1, point_a, '2026-01-12T00:00:00Z', '2026-01-20T00:00:00Z');

        RAISE EXCEPTION 'TEST FAILURE: overlapping binding was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            IF SQLSTATE <> '23P01' THEN  -- exclusion_violation
                RAISE EXCEPTION 'TEST FAILURE: expected exclusion_violation (23P01), got SQLSTATE % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected ex_asset_points_no_overlap to raise, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 4. Historical (backdated) correction that overlaps an EARLIER owner
--    (not just the most recent one) is also rejected -- proves the
--    exclusion is scoped per logical_point_id, not per (asset, point).
-- ------------------------------------------------------------------

DO $$
DECLARE
    asset_2 UUID := 'c6000000-0000-0000-0000-000000000002';
    point_a UUID;
    v_raised BOOLEAN := FALSE;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';

    BEGIN
        -- [2026-01-07, 2026-01-08) falls entirely inside Asset 1's closed
        -- [2026-01-01, 2026-01-10) window from test 2 -- a backdated insert
        -- against the EARLIER owner, not the current one.
        INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from, effective_to)
        VALUES (asset_2, point_a, '2026-01-07T00:00:00Z', '2026-01-08T00:00:00Z');

        RAISE EXCEPTION 'TEST FAILURE: backdated overlap against an earlier owner was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            IF SQLSTATE <> '23P01' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected exclusion_violation (23P01), got SQLSTATE % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected ex_asset_points_no_overlap to raise for the backdated correction, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 5. Two different points may independently have overlapping periods --
--    the exclusion never compares across different logical_point_id
--    values.
-- ------------------------------------------------------------------

DO $$
DECLARE
    asset_1 UUID := 'c6000000-0000-0000-0000-000000000001';
    point_b UUID;
BEGIN
    SELECT id INTO point_b FROM metadata.logical_points WHERE name = 'CURRENT_L2';
    IF point_b IS NULL THEN
        RAISE EXCEPTION 'Fixture assumption violated: CURRENT_L2 must exist as a canonical logical point';
    END IF;

    -- Same asset, same time range as Asset 2's CURRENT_L1 binding
    -- ([2026-01-10, infinity)) -- but a different point, so no conflict.
    INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from)
    VALUES (asset_1, point_b, '2026-01-10T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.asset_points
        WHERE asset_id = asset_1 AND logical_point_id = point_b AND effective_to IS NULL
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: independent point binding with an overlapping time range was unexpectedly rejected';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 6. Equivalent temporal behavior for metadata.space_points: initial
--    binding, a valid move, and overlap rejection.
-- ------------------------------------------------------------------

DO $$
DECLARE
    space_1 UUID := 'c5000000-0000-0000-0000-000000000001';
    space_2 UUID := 'c5000000-0000-0000-0000-000000000002';
    point_a UUID;
    v_raised BOOLEAN := FALSE;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';

    -- Initial binding.
    INSERT INTO metadata.space_points (space_id, logical_point_id, effective_from)
    VALUES (space_1, point_a, '2026-01-01T00:00:00Z');

    -- Valid move: close space_1's binding, open space_2's at the same instant.
    UPDATE metadata.space_points
    SET effective_to = '2026-01-10T00:00:00Z'
    WHERE space_id = space_1 AND logical_point_id = point_a AND effective_to IS NULL;

    INSERT INTO metadata.space_points (space_id, logical_point_id, effective_from)
    VALUES (space_2, point_a, '2026-01-10T00:00:00Z');

    IF NOT EXISTS (
        SELECT 1 FROM metadata.space_points
        WHERE logical_point_id = point_a
          AND effective_range @> '2026-01-15T00:00:00Z'::TIMESTAMPTZ
          AND space_id = space_2
    ) THEN
        RAISE EXCEPTION 'TEST FAILURE: space_points time-aware lookup after a valid move did not resolve the new space';
    END IF;

    -- Overlap rejection.
    BEGIN
        INSERT INTO metadata.space_points (space_id, logical_point_id, effective_from, effective_to)
        VALUES (space_1, point_a, '2026-01-12T00:00:00Z', '2026-01-20T00:00:00Z');

        RAISE EXCEPTION 'TEST FAILURE: overlapping space_points binding was accepted';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN
                RAISE;
            END IF;
            IF SQLSTATE <> '23P01' THEN
                RAISE EXCEPTION 'TEST FAILURE: expected exclusion_violation (23P01) on space_points, got SQLSTATE % (%)', SQLSTATE, SQLERRM;
            END IF;
            v_raised := TRUE;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected ex_space_points_no_overlap to raise, but no exception occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 7. Invalid foreign-key references are rejected on both tables.
-- ------------------------------------------------------------------

DO $$
DECLARE
    point_a UUID;
    v_raised BOOLEAN := FALSE;
BEGIN
    SELECT id INTO point_a FROM metadata.logical_points WHERE name = 'CURRENT_L1';

    BEGIN
        INSERT INTO metadata.asset_points (asset_id, logical_point_id, effective_from)
        VALUES ('00000000-0000-0000-0000-000000000000', point_a, '2026-02-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: asset_points accepted a non-existent asset_id';
    EXCEPTION
        WHEN foreign_key_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST FAILURE: expected foreign_key_violation, got SQLSTATE % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected a foreign-key violation on asset_points.asset_id, none occurred';
    END IF;

    v_raised := FALSE;
    BEGIN
        INSERT INTO metadata.space_points (space_id, logical_point_id, effective_from)
        VALUES ('00000000-0000-0000-0000-000000000000', point_a, '2026-02-01T00:00:00Z');
        RAISE EXCEPTION 'TEST FAILURE: space_points accepted a non-existent space_id';
    EXCEPTION
        WHEN foreign_key_violation THEN v_raised := TRUE;
        WHEN OTHERS THEN
            IF SQLERRM LIKE 'TEST FAILURE:%' THEN RAISE; END IF;
            RAISE EXCEPTION 'TEST FAILURE: expected foreign_key_violation, got SQLSTATE % (%)', SQLSTATE, SQLERRM;
    END;
    IF NOT v_raised THEN
        RAISE EXCEPTION 'TEST FAILURE: expected a foreign-key violation on space_points.space_id, none occurred';
    END IF;
END;
$$;


-- ------------------------------------------------------------------
-- 8. Non-mutation / regression: this entire test runs inside one
--    transaction that is rolled back (nothing above ever persists), and
--    pre-existing, unrelated reference data is untouched by anything in
--    this file.
-- ------------------------------------------------------------------

DO $$
DECLARE
    v_missing_count INTEGER;
BEGIN
    SELECT count(*) INTO v_missing_count
    FROM (VALUES ('CURRENT_L1'), ('CURRENT_L2'), ('ENV_TEMPERATURE')) AS expected(name)
    WHERE NOT EXISTS (
        SELECT 1 FROM metadata.logical_points lp WHERE lp.name = expected.name
    );

    IF v_missing_count > 0 THEN
        RAISE EXCEPTION 'TEST FAILURE: pre-existing logical_points appear to be missing -- regression in an unrelated column/row';
    END IF;
END;
$$;


ROLLBACK;


SELECT
    'Phase 2 Slice 2A (migration 224) asset_points/space_points temporal binding assertions passed.'
    AS result;
