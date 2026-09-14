-- ============================================================================
-- MVP-7 Basic Alerts -- live-execution integration test (migration 241).
--
-- Purpose: prove analytics.run_alert_evaluation_job(1, '{}'::jsonb) -- the
-- exact TimescaleDB job entrypoint, nesting a CALL to
-- analytics.evaluate_alerts() -- executes without error against a real
-- TimescaleDB instance. This is the coverage gap the original static
-- contract tests (app/tests/test_alert_evaluation_contract.py) explicitly
-- disclosed as untestable locally: they can verify COMMIT *placement* in
-- the source text, but not whether that COMMIT is *legal* at the procedure's
-- actual security-context/call depth. Before migration 241, this exact CALL
-- failed on staging 3/3 times with sqlerrcode 2D000 ("invalid transaction
-- termination") -- see docs/07-features/alerts/README.md.
--
-- Two paths are exercised:
--   1. A baseline CALL against whatever sites already exist at this point
--      in the integration suite (may be zero) -- the retention-DELETE +
--      final COMMIT (migration 239/241 line ~216) executes unconditionally
--      on every call regardless of site count, so this alone always
--      exercises that COMMIT.
--   2. A CALL with a guaranteed active site present -- exercises the
--      per-site COMMIT (line ~208) specifically, matching real staging
--      data (3 real sites) exactly.
--
-- IMPORTANT: analytics.evaluate_alerts() COMMITs internally. A procedure
-- that commits cannot be invoked from inside an explicit client transaction
-- block (a SEPARATE, correct PostgreSQL restriction, not the migration-241
-- defect) -- so unlike other seeded assertions in this suite, the fixture
-- site below is inserted and removed as plain top-level (autocommitting)
-- statements, never wrapped in BEGIN/ROLLBACK.
-- ============================================================================

\set ON_ERROR_STOP on

\echo '[mvp7-alert-job] Test 1: CALL analytics.run_alert_evaluation_job(1, ''{}''::jsonb) -- baseline (exercises the retention COMMIT unconditionally)'
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);
\echo '[mvp7-alert-job] Test 1 PASSED -- no exception (sqlerrcode 2D000 would have aborted this script)'

-- Fixture site -- plain top-level INSERTs (autocommit), not BEGIN/ROLLBACK
-- (see header note above). Deterministic IDs, deleted below.
INSERT INTO metadata.organizations (id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000241a1', 'MVP7 Job Execution Assert Org', 'MVP7_JOB_ASSERT_ORG');
INSERT INTO metadata.sites (id, organization_id, name, code) VALUES
  ('00000000-0000-0000-0000-0000000241a2', '00000000-0000-0000-0000-0000000241a1', 'MVP7 Job Execution Assert Site', 'MVP7_JOB_ASSERT_SITE');

\echo '[mvp7-alert-job] Test 2: CALL analytics.run_alert_evaluation_job(1, ''{}''::jsonb) -- with a guaranteed active site (exercises the per-site COMMIT)'
CALL analytics.run_alert_evaluation_job(1, '{}'::jsonb);
\echo '[mvp7-alert-job] Test 2 PASSED -- no exception with an active site present'

-- Cleanup -- plain top-level DELETEs, so this fixture does not affect any
-- assertion that runs later in the same integration-test sequence.
DELETE FROM analytics.alert_evaluation_candidates WHERE site_id = '00000000-0000-0000-0000-0000000241a2';
DELETE FROM analytics.alerts WHERE site_id = '00000000-0000-0000-0000-0000000241a2';
DELETE FROM metadata.sites WHERE id = '00000000-0000-0000-0000-0000000241a2';
DELETE FROM metadata.organizations WHERE id = '00000000-0000-0000-0000-0000000241a1';

DO $verify$
BEGIN
    IF EXISTS (SELECT 1 FROM metadata.sites WHERE id = '00000000-0000-0000-0000-0000000241a2') THEN
        RAISE EXCEPTION 'MVP7 JOB ASSERT FAIL: fixture site was not cleaned up.';
    END IF;
    RAISE NOTICE '[mvp7-alert-job] Cleanup verified -- fixture site/org removed.';
END;
$verify$;

\echo '==================================================================='
\echo 'assert_mvp7_alert_evaluation_job_executes.sql: ALL CONTRACTS PASSED'
\echo '==================================================================='
