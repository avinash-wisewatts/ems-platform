-- ============================================================================
-- Migration 320
-- Alerts (ADR-024 §17-§20): retire the MVP-7 Energy Attention alerts.
--
-- The customer-configurable alert rules (migrations 321-326) replace MVP-7
-- Basic Alerts entirely. This migration, which runs first in that release:
--
--   1. classifies every existing analytics.alerts and
--      analytics.alert_evaluation_candidates row as a legacy Energy
--      Attention row -- and ABORTS, changing nothing, if any row is not;
--   2. retires the legacy evaluator BEFORE deleting anything, so nothing can
--      recreate the records: removes every TimescaleDB job whose procedure
--      is analytics.run_alert_evaluation_job (located by name; zero jobs is
--      not an error -- the job was registered manually and its id differs
--      per environment), waits for an in-flight run (table lock), and drops
--      analytics.run_alert_evaluation_job, analytics.evaluate_alerts and
--      analytics.evaluate_energy_attention_materiality, plus the legacy
--      read functions analytics.get_portal_site_alerts /
--      analytics.get_portal_alert_detail (migration 324 recreates them for
--      rule-based alerts);
--   3. deletes the legacy rows (candidates first, then alerts);
--   4. records per-table / per-state counts and the removed job ids in
--      admin.migration_outcomes (new) and as NOTICE lines for the
--      deployment log;
--   5. verifies that no legacy row and no legacy job remains.
--
-- Legacy predicate (alerts): condition_key LIKE 'ENERGY_ATTENTION:%' AND
-- metric = 'ENERGY_CONSUMPTION' AND asset_id IS NULL AND space_id IS NULL.
-- (candidates): condition_key LIKE 'ENERGY_ATTENTION:%'. Before this
-- release no other kind of row can exist; migration 321 then adds the
-- guards (rule reference NOT NULL, condition_key LIKE 'RULE:%') that keep
-- legacy-shaped rows from reappearing.
--
-- The ADR-010 Energy Attention DISPLAY (Site Overview, Main Dashboard, Site
-- Performance Report) is computed in the browser and is not affected.
--
-- Scope: explicitly staging|production|test
-- (postgres/migration_environment_scope.csv). Runs in one transaction with
-- its ledger insert (scripts/apply_migrations.sh): all or nothing.
-- Idempotent body (IF EXISTS / zero-row deletes) in addition to the ledger.
--
-- IRREVERSIBLE: deleted legacy alert records cannot be restored by this
-- repository. Rollback of the schema part only: re-apply migrations
-- 239-242's function bodies; the data is gone.
-- ============================================================================

SET LOCAL lock_timeout = '30s';

DO $pre$
BEGIN
    IF to_regclass('analytics.alerts') IS NULL
       OR to_regclass('analytics.alert_evaluation_candidates') IS NULL THEN
        RAISE EXCEPTION 'Migration 320 precondition failed: analytics.alerts / analytics.alert_evaluation_candidates (migration 238) are missing.';
    END IF;
END;
$pre$;


-- ----------------------------------------------------------------------------
-- 1. Outcome record (durable; admin.write_audit_event needs a real portal
--    user, so a migration cannot record itself there).
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS admin.migration_outcomes
(
    outcome_id   BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    migration_id TEXT        NOT NULL,
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    outcome      JSONB       NOT NULL,
    CONSTRAINT migration_outcomes_object_chk CHECK (jsonb_typeof(outcome) = 'object')
);
ALTER TABLE admin.migration_outcomes OWNER TO ems_admin;
REVOKE ALL ON admin.migration_outcomes FROM PUBLIC;
COMMENT ON TABLE admin.migration_outcomes IS
'Migration 320: durable outcome records written by data-changing migrations (e.g. migration 320''s legacy alert deletion counts). Read by operators; written only by migrations.';


-- ----------------------------------------------------------------------------
-- 2-5. Classify, retire, delete, record, verify.
-- ----------------------------------------------------------------------------

DO $retire$
DECLARE
    v_unclassified_alerts     BIGINT;
    v_unclassified_candidates BIGINT;
    v_alerts_by_state         JSONB;
    v_candidates_by_state     JSONB;
    v_job_ids                 INTEGER[] := ARRAY[]::INTEGER[];
    v_job_id                  INTEGER;
    v_deleted_candidates      BIGINT;
    v_deleted_alerts          BIGINT;
    v_remaining_alerts        BIGINT;
    v_remaining_candidates    BIGINT;
    v_remaining_jobs          BIGINT;
BEGIN
    -- Retire the evaluator first: no job may run between classification and
    -- deletion. delete_job() is transactional; it takes effect at COMMIT.
    FOR v_job_id IN
        SELECT j.job_id
        FROM timescaledb_information.jobs AS j
        WHERE j.proc_schema = 'analytics'
          AND j.proc_name = 'run_alert_evaluation_job'
        ORDER BY j.job_id
    LOOP
        PERFORM delete_job(v_job_id);
        v_job_ids := v_job_ids || v_job_id;
    END LOOP;

    -- Waits (lock_timeout 30 s) for an in-flight legacy run to finish, and
    -- keeps every other writer out until COMMIT.
    LOCK TABLE analytics.alerts, analytics.alert_evaluation_candidates IN ACCESS EXCLUSIVE MODE;

    -- Classify. Any row that is not a legacy Energy Attention row aborts the
    -- whole migration with nothing changed.
    SELECT count(*) INTO v_unclassified_alerts
    FROM analytics.alerts AS a
    WHERE NOT (
        a.condition_key LIKE 'ENERGY_ATTENTION:%'
        AND a.metric = 'ENERGY_CONSUMPTION'
        AND a.asset_id IS NULL
        AND a.space_id IS NULL
    );
    SELECT count(*) INTO v_unclassified_candidates
    FROM analytics.alert_evaluation_candidates AS c
    WHERE c.condition_key NOT LIKE 'ENERGY_ATTENTION:%';

    IF v_unclassified_alerts > 0 OR v_unclassified_candidates > 0 THEN
        RAISE EXCEPTION 'Migration 320 aborted: % analytics.alerts row(s) and % analytics.alert_evaluation_candidates row(s) are not legacy Energy Attention rows; nothing was changed.',
            v_unclassified_alerts, v_unclassified_candidates;
    END IF;

    SELECT COALESCE(jsonb_object_agg(s.state, s.n), '{}'::jsonb) INTO v_alerts_by_state
    FROM (SELECT state, count(*) AS n FROM analytics.alerts GROUP BY state) AS s;
    SELECT COALESCE(jsonb_object_agg(s.watch_state, s.n), '{}'::jsonb) INTO v_candidates_by_state
    FROM (SELECT watch_state, count(*) AS n FROM analytics.alert_evaluation_candidates GROUP BY watch_state) AS s;

    -- Drop the legacy evaluator and read functions (no caller remains).
    DROP PROCEDURE IF EXISTS analytics.run_alert_evaluation_job(INTEGER, JSONB);
    DROP PROCEDURE IF EXISTS analytics.evaluate_alerts();
    DROP FUNCTION IF EXISTS analytics.evaluate_energy_attention_materiality(UUID, TIMESTAMPTZ);
    DROP FUNCTION IF EXISTS analytics.get_portal_site_alerts(BIGINT, UUID, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INT, TIMESTAMPTZ);
    DROP FUNCTION IF EXISTS analytics.get_portal_alert_detail(BIGINT, UUID);

    -- Delete legacy rows only (candidates reference alerts).
    DELETE FROM analytics.alert_evaluation_candidates AS c
    WHERE c.condition_key LIKE 'ENERGY_ATTENTION:%';
    GET DIAGNOSTICS v_deleted_candidates = ROW_COUNT;

    DELETE FROM analytics.alerts AS a
    WHERE a.condition_key LIKE 'ENERGY_ATTENTION:%'
      AND a.metric = 'ENERGY_CONSUMPTION'
      AND a.asset_id IS NULL
      AND a.space_id IS NULL;
    GET DIAGNOSTICS v_deleted_alerts = ROW_COUNT;

    -- Post-check.
    SELECT count(*) INTO v_remaining_alerts FROM analytics.alerts;
    SELECT count(*) INTO v_remaining_candidates FROM analytics.alert_evaluation_candidates;
    SELECT count(*) INTO v_remaining_jobs
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_alert_evaluation_job';

    IF v_remaining_alerts <> 0 OR v_remaining_candidates <> 0 OR v_remaining_jobs <> 0 THEN
        RAISE EXCEPTION 'Migration 320 postcondition failed: % alert row(s), % candidate row(s), % legacy job(s) remain.',
            v_remaining_alerts, v_remaining_candidates, v_remaining_jobs;
    END IF;
    IF to_regprocedure('analytics.evaluate_alerts()') IS NOT NULL
       OR to_regprocedure('analytics.run_alert_evaluation_job(integer, jsonb)') IS NOT NULL
       OR to_regprocedure('analytics.evaluate_energy_attention_materiality(uuid, timestamptz)') IS NOT NULL THEN
        RAISE EXCEPTION 'Migration 320 postcondition failed: a legacy evaluator routine still exists.';
    END IF;

    INSERT INTO admin.migration_outcomes (migration_id, outcome)
    VALUES (
        '320_alert_legacy_retirement',
        jsonb_build_object(
            'database', current_database(),
            'removed_job_ids', to_jsonb(v_job_ids),
            'alerts_before_by_state', v_alerts_by_state,
            'candidates_before_by_watch_state', v_candidates_by_state,
            'alerts_deleted', v_deleted_alerts,
            'candidates_deleted', v_deleted_candidates,
            'alerts_remaining', v_remaining_alerts,
            'candidates_remaining', v_remaining_candidates
        )
    );

    RAISE NOTICE 'Migration 320: removed legacy alert job(s) %', v_job_ids;
    RAISE NOTICE 'Migration 320: analytics.alerts before by state %; deleted %', v_alerts_by_state, v_deleted_alerts;
    RAISE NOTICE 'Migration 320: analytics.alert_evaluation_candidates before by watch state %; deleted %', v_candidates_by_state, v_deleted_candidates;
END;
$retire$;
