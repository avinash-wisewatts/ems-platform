-- ============================================================================
-- Post-migration-320 checks for assert_alert_legacy_retirement.sh (phase B).
-- Runs in the same transaction as the setup and the real migration file;
-- the caller rolls everything back.
-- ============================================================================

\set ON_ERROR_STOP on

DO $checks$
DECLARE
    v_outcome JSONB;
BEGIN
    IF EXISTS (SELECT 1 FROM analytics.alerts) THEN
        RAISE EXCEPTION 'FAIL: analytics.alerts still has rows after migration 320';
    END IF;
    IF EXISTS (SELECT 1 FROM analytics.alert_evaluation_candidates) THEN
        RAISE EXCEPTION 'FAIL: analytics.alert_evaluation_candidates still has rows after migration 320';
    END IF;
    IF EXISTS (SELECT 1 FROM timescaledb_information.jobs
               WHERE proc_schema = 'analytics' AND proc_name = 'run_alert_evaluation_job') THEN
        RAISE EXCEPTION 'FAIL: the legacy alert job still exists after migration 320';
    END IF;
    IF to_regprocedure('analytics.run_alert_evaluation_job(integer, jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: the legacy job procedure still exists after migration 320';
    END IF;

    SELECT outcome INTO v_outcome
    FROM admin.migration_outcomes
    WHERE migration_id = '320_alert_legacy_retirement'
    ORDER BY outcome_id DESC
    LIMIT 1;

    IF v_outcome IS NULL THEN
        RAISE EXCEPTION 'FAIL: no admin.migration_outcomes row for migration 320';
    END IF;
    IF (v_outcome ->> 'alerts_deleted')::INT <> 4
       OR (v_outcome ->> 'candidates_deleted')::INT <> 1
       OR (v_outcome -> 'alerts_before_by_state' ->> 'ACTIVE')::INT <> 1
       OR (v_outcome -> 'alerts_before_by_state' ->> 'RESOLVED')::INT <> 1
       OR (v_outcome -> 'alerts_before_by_state' ->> 'ENDED')::INT <> 2
       OR (v_outcome -> 'candidates_before_by_watch_state' ->> 'WATCHING_CLEAR')::INT <> 1
       OR jsonb_array_length(v_outcome -> 'removed_job_ids') <> 1
       OR (v_outcome ->> 'alerts_remaining')::INT <> 0 THEN
        RAISE EXCEPTION 'FAIL: unexpected migration 320 outcome %', v_outcome;
    END IF;

    RAISE NOTICE 'PASS: migration 320 deleted 4 legacy alerts (1 ACTIVE, 1 RESOLVED, 2 ENDED) and 1 candidate, removed 1 legacy job, recorded %', v_outcome;
END;
$checks$;

-- Idempotent body: a second execution changes nothing and still succeeds.
