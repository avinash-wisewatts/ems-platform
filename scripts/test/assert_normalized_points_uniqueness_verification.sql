-- ============================================================================
-- File:
--   scripts/test/assert_normalized_points_uniqueness_verification.sql
--
-- Purpose:
--   Regression test for the 2026-08-25 verification-timeout incident: the
--   duplicate-key check in scripts/verify/verify_pipeline.sh used an
--   unbounded GROUP BY over the entire telemetry.normalized_points
--   hypertable, which does not scale against production's real volume
--   (34M+ rows, compressed after 1 day) -- a real production deployment's
--   post_deploy_verify.sh hung on this exact query for 12+ minutes before
--   the SSH command timeout fired, even though the deployment itself had
--   already succeeded.
--
--   telemetry.uq_normalized_points_identity (postgres/ddl/40_normalized_
--   points_uniqueness.sql) is a UNIQUE INDEX on exactly (event_time,
--   device_id, logical_point_id) that has structurally prevented any
--   duplicate on that triplet since shortly after the table was created --
--   PostgreSQL rejects a violating INSERT at write time. The replacement
--   check verifies that enforcing index is present/unique/ready/valid (a
--   constant-time catalog lookup, not a data scan) plus a small
--   recent-window content check as defense-in-depth against the one thing
--   the catalog check can't see: the index having been dropped or bypassed
--   out-of-band.
--
--   This test exercises the EXACT SQL now embedded in verify_pipeline.sh
--   (kept in sync with that file -- if the queries there change, update
--   the copies below) against real fixture data in the canonical test
--   database, proving:
--     A. The check queries the actual canonical index name.
--     B/C. A healthy database (real index, no recent duplicates) passes
--        both checks.
--     D. A missing/invalid uniqueness mechanism is correctly treated as a
--        failure condition (index dropped for the remainder of this
--        script -- see below).
--     E. A recent duplicate is correctly treated as a failure condition
--        (constructed once the index above is gone, since the index is
--        the only thing that would otherwise reject the duplicate INSERT).
--
--   Everything here runs inside one transaction that is rolled back at the
--   very end -- the dropped index and inserted rows never persist. Tests
--   D/E deliberately run AFTER A/B/C and drop the index for the rest of
--   this script (there is nothing to restore mid-script: the outer
--   ROLLBACK is the only cleanup this needs, and it undoes the DROP INDEX
--   exactly as it undoes the INSERTs).
-- ============================================================================

BEGIN;

DO $test$
DECLARE
    v_org UUID := gen_random_uuid();
    v_device UUID := gen_random_uuid();
    v_lp UUID := gen_random_uuid();
    v_structural_ok TEXT;
    v_recent_dupes BIGINT;
BEGIN
    -- ==================================================================
    -- Fixture: a couple of real, non-duplicate recent rows so the
    -- healthy case exercises actual data, not just an empty table.
    -- ==================================================================

    INSERT INTO telemetry.normalized_points (
        event_time, organization_id, device_id, logical_point_id,
        numeric_value, quality_code
    ) VALUES
        (now() - interval '5 minutes', v_org, v_device, v_lp, 100.0, 'VALID'),
        (now() - interval '4 minutes', v_org, v_device, v_lp, 101.0, 'VALID');

    -- ==================================================================
    -- TEST A -- the structural check queries the actual canonical index.
    -- ==================================================================

    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'telemetry'
          AND tablename = 'normalized_points'
          AND indexname = 'uq_normalized_points_identity'
    ) THEN
        RAISE EXCEPTION 'TEST A FAILED: telemetry.uq_normalized_points_identity does not exist on the canonical database';
    END IF;

    RAISE NOTICE 'TEST A passed: the canonical index telemetry.uq_normalized_points_identity exists.';

    -- ==================================================================
    -- TEST B (healthy path) -- structural check passes.
    -- ==================================================================

    v_structural_ok := (
        SELECT (indisvalid AND indisready AND indisunique)::text
        FROM pg_index
        WHERE indexrelid = to_regclass('telemetry.uq_normalized_points_identity')
    );

    IF v_structural_ok IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'TEST B FAILED: structural check did not report true against a healthy index, got %', v_structural_ok;
    END IF;

    RAISE NOTICE 'TEST B passed: structural check reports true for a valid, ready, unique index.';

    -- ==================================================================
    -- TEST C (healthy path) -- no recent duplicates: recent-window
    -- check passes (count = 0).
    -- ==================================================================

    v_recent_dupes := (
        SELECT COUNT(*) FROM (
            SELECT event_time, device_id, logical_point_id
            FROM telemetry.normalized_points
            WHERE event_time > now() - interval '1 hour'
            GROUP BY event_time, device_id, logical_point_id
            HAVING COUNT(*) > 1
        ) recent_duplicates
    );

    IF v_recent_dupes <> 0 THEN
        RAISE EXCEPTION 'TEST C FAILED: expected zero recent duplicates against clean fixture data, got %', v_recent_dupes;
    END IF;

    RAISE NOTICE 'TEST C passed: recent-window check reports zero duplicates against clean fixture data.';
END;
$test$;

-- ----------------------------------------------------------------------------
-- TEST D -- missing/invalid uniqueness mechanism is treated as failure.
-- Drop the index for the rest of this script (undone only by the final
-- ROLLBACK). The structural query must then return no row (to_regclass ->
-- NULL), which verify_pipeline.sh treats as FAIL, not PASS (requirement 6).
-- ----------------------------------------------------------------------------

DROP INDEX telemetry.uq_normalized_points_identity;

DO $test$
DECLARE
    v_structural_ok TEXT;
BEGIN
    v_structural_ok := (
        SELECT (indisvalid AND indisready AND indisunique)::text
        FROM pg_index
        WHERE indexrelid = to_regclass('telemetry.uq_normalized_points_identity')
    );

    IF v_structural_ok IS NOT NULL THEN
        RAISE EXCEPTION 'TEST D FAILED: structural check returned a row (%) after the index was dropped -- expected no row', v_structural_ok;
    END IF;

    RAISE NOTICE 'TEST D passed: structural check correctly returns no row when the uniqueness index is missing.';
END;
$test$;

-- ----------------------------------------------------------------------------
-- TEST E -- a recent duplicate is treated as a failure condition. Only
-- possible now that the index (the only thing preventing it) is gone.
-- Both rows come from a single INSERT statement, so PostgreSQL evaluates
-- now() once for the whole statement and both rows get an identical
-- event_time -- a genuine duplicate on (event_time, device_id,
-- logical_point_id).
-- ----------------------------------------------------------------------------

DO $test$
DECLARE
    v_org UUID := gen_random_uuid();
    v_device UUID := gen_random_uuid();
    v_lp UUID := gen_random_uuid();
    v_recent_dupes BIGINT;
BEGIN
    INSERT INTO telemetry.normalized_points (
        event_time, organization_id, device_id, logical_point_id,
        numeric_value, quality_code
    ) VALUES
        (now() - interval '2 minutes', v_org, v_device, v_lp, 200.0, 'VALID'),
        (now() - interval '2 minutes', v_org, v_device, v_lp, 200.0, 'VALID');

    v_recent_dupes := (
        SELECT COUNT(*) FROM (
            SELECT event_time, device_id, logical_point_id
            FROM telemetry.normalized_points
            WHERE event_time > now() - interval '1 hour'
            GROUP BY event_time, device_id, logical_point_id
            HAVING COUNT(*) > 1
        ) recent_duplicates
    );

    IF v_recent_dupes = 0 THEN
        RAISE EXCEPTION 'TEST E FAILED: expected the recent-window check to detect the deliberately-inserted duplicate, got zero';
    END IF;

    RAISE NOTICE 'TEST E passed: recent-window check correctly detects a real duplicate (count=%).', v_recent_dupes;
END;
$test$;

ROLLBACK;

SELECT
    'Normalized-points uniqueness verification assertions passed.'
    AS result;
