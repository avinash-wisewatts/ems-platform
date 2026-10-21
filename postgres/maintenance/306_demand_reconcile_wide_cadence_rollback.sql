-- ============================================================================
-- Rollback for migration 306 (demand reconciler wide-pass cadence).
-- Forward-only system: run this as a reviewed, approved maintenance script,
-- never automatically.
--
-- Re-issues the migration-213 body of analytics.reconcile_demand_intervals
-- (and its 213 COMMENT) and returns the job config to the migration-305 state:
-- reconcile_window 48 hours, wide_window / wide_every removed, check_config
-- config.assert_reconciliation_job_config; every other key, the schedule and
-- the job id unchanged. Drops config.assert_demand_reconciliation_job_config. Refuses unless the deployed body
-- is exactly the migration-306 body. Changes no data.
-- ============================================================================
\set ON_ERROR_STOP on

BEGIN;

DO $pre$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure)
       IS DISTINCT FROM '4b9820743f6ecddcbb89051269faf6e0' THEN
        RAISE EXCEPTION '306 rollback refused: the deployed reconcile_demand_intervals is not the migration-306 body.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals') <> 1 THEN
        RAISE EXCEPTION '306 rollback refused: expected exactly one analytics.reconcile_demand_intervals job.';
    END IF;
END
$pre$;

CREATE OR REPLACE PROCEDURE analytics.reconcile_demand_intervals(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'analytics', 'config', 'metadata'
AS $procedure$
DECLARE
    v_pipeline  CONSTANT text := 'demand_intervals';
    v_fwd_lock  CONSTANT text := 'analytics.run_demand_calculation_job';
    v_rw        INTERVAL := INTERVAL '6 hours';
    v_lookback  INTERVAL := INTERVAL '3 hours';
    v_run       uuid := gen_random_uuid();
    v_started   timestamptz := clock_timestamp();
    v_cp        timestamptz;
    v_ws        timestamptz;
    v_repaired  bigint  := 0;
    v_errs      integer := 0;
    v_sqlstate  text;
    v_errmsg    text;
    v_outcome   text;
BEGIN
    IF config ? 'reconcile_window' THEN v_rw       := (config ->> 'reconcile_window')::INTERVAL; END IF;
    IF config ? 'lookback'         THEN v_lookback := (config ->> 'lookback')::INTERVAL; END IF;

    IF NOT pg_try_advisory_xact_lock(hashtextextended(v_fwd_lock, 0)) THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'SKIPPED_LOCKED', NULL, NULL);
        RETURN;
    END IF;

    SELECT last_received_at INTO v_cp
    FROM telemetry.pipeline_state WHERE pipeline_name = v_pipeline;

    IF v_cp IS NULL THEN
        PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
            NULL, NULL, NULL, NULL, NULL, 0, 0, 'NO_CHECKPOINT', NULL, NULL);
        RETURN;
    END IF;

    v_ws := v_cp - v_rw;

    -- p_now = clock_timestamp() keeps the live analytics.demand_state block
    -- current; p_finalize_from / p_finalize_to bound ONLY the historical
    -- finalisation loop -> a bounded re-finalisation over [v_ws, v_cp) that does
    -- NOT touch telemetry.pipeline_state('demand_intervals') and applies the
    -- 210 status guard (VALID rows frozen; scope-branched partial-index upsert).
    BEGIN
        CALL analytics.refresh_demand_analytics(clock_timestamp(), v_lookback, v_ws, v_cp);
    EXCEPTION WHEN OTHERS THEN
        v_errs := 1;
        v_sqlstate := SQLSTATE;
        v_errmsg   := left(SQLERRM, 1000);
    END;

    SELECT count(*)::bigint INTO v_repaired
    FROM analytics.demand_intervals
    WHERE interval_start >= v_ws
      AND interval_start <  v_cp
      AND finalized_at   >= v_started;

    v_outcome := CASE WHEN v_errs > 0 THEN 'FAILED'
                      WHEN v_repaired > 0 THEN 'REPAIRED'
                      ELSE 'HEALTHY' END;

    PERFORM analytics.record_reconciliation_run(v_run, v_pipeline, v_started,
        v_ws, v_cp, NULL, NULL, NULL, v_repaired, v_errs, v_outcome, v_sqlstate, v_errmsg);
END;
$procedure$;

COMMENT ON PROCEDURE analytics.reconcile_demand_intervals(integer, jsonb) IS
'Migration 213: bounded trailing reconciliation for analytics.demand_intervals. Demand has no source-count fingerprint; the repair IS the re-run: CALL analytics.refresh_demand_analytics(clock_timestamp(), lookback, p_finalize_from => checkpoint - reconcile_window, p_finalize_to => checkpoint). Applies the migration-210 status guard (VALID frozen; scope-branched SITE/ASSET partial-index upsert). The live demand_state block stays keyed to p_now. NEVER writes telemetry.pipeline_state.last_received_at. reconcile_window default 6 hours (the audit''s 12h recommendation is conditional on an unperformed staging cost read; raise via alter_job, not a migration). demand max_catchup_window is unchanged.';

DO $demand$
DECLARE
    v_job INTEGER;
    v_cfg JSONB;
BEGIN
    SELECT job_id, config INTO v_job, v_cfg FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals';
    PERFORM alter_job(v_job, config => (v_cfg - 'wide_window' - 'wide_every') || jsonb_build_object('reconcile_window', '48 hours'),
                      check_config => 'config.assert_reconciliation_job_config'::regproc);
    RAISE NOTICE '306 rollback: job % config % -> %', v_job, v_cfg,
        (v_cfg - 'wide_window' - 'wide_every') || jsonb_build_object('reconcile_window', '48 hours');
END
$demand$;

DROP FUNCTION config.assert_demand_reconciliation_job_config(jsonb);

DO $post$
BEGIN
    IF (SELECT md5(replace(prosrc, E'\r', '')) FROM pg_proc
        WHERE oid = 'analytics.reconcile_demand_intervals(integer,jsonb)'::regprocedure)
       IS DISTINCT FROM 'c2492b9d357c59aa0fa0cc97dd70f70e' THEN
        RAISE EXCEPTION '306 rollback postcondition failed: the restored body is not the migration-213 body.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND config ->> 'reconcile_window' = '48 hours'
          AND NOT (config ? 'wide_window') AND NOT (config ? 'wide_every')) <> 1 THEN
        RAISE EXCEPTION '306 rollback postcondition failed: the demand reconciler is not back at the migration-305 config.';
    END IF;
    IF (SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_demand_intervals'
          AND check_schema = 'config' AND check_name = 'assert_reconciliation_job_config') <> 1 THEN
        RAISE EXCEPTION '306 rollback postcondition failed: the demand reconciler check_config is not config.assert_reconciliation_job_config.';
    END IF;
    RAISE NOTICE '306 rollback: pre-306 state restored.';
END
$post$;

COMMIT;
