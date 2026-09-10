-- ============================================================================
-- Rollback for migration 230 (Phase 6 -- persisted SPACE_DEW_POINT tier).
--
-- Controlled, dependency-checked reversal. NOT run as part of any migration.
-- No CASCADE. Reverses only what migration 230 created / changed:
--   * both TimescaleDB jobs (run_derived_space_dew_point_1min_job,
--     reconcile_derived_space_dew_point_1min)
--   * analytics.reconcile_derived_space_dew_point_1min   (procedure)
--   * telemetry.run_derived_space_dew_point_1min_job     (procedure)
--   * analytics.refresh_derived_space_dew_point_1min     (function)
--   * analytics.derived_parameter_values + its retention / compression
--     policies                                           (table)
--   * telemetry.pipeline_state row 'derived_space_dew_point_1min'
--   * config.parameter_calculations.materialization_strategy CHECK
--     (PERSISTED -> VIEW only) and the SPACE_DEW_POINT row (PERSISTED -> VIEW)
--   * analytics.pipeline_reconciliation_log_tier_chk (drop the new tier value)
--
-- There is NO stored derived state that matters (nothing downstream depends
-- on analytics.derived_parameter_values yet -- Phase 7 has not run). Refuses
-- to run if: a later config.parameter_calculations row exists; another
-- calculation row is already PERSISTED; an object outside migration 230
-- depends on analytics.derived_parameter_values; or a
-- pipeline_reconciliation_log row for the new tier exists.
--
-- Run manually, inside a single transaction:
--   docker compose exec -T <db> psql -X -v ON_ERROR_STOP=1 -U ems_admin -d <db> \
--     -f postgres/maintenance/230_persisted_space_dew_point_rollback.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0. Order-independent safety guards.
-- ----------------------------------------------------------------------------
DO $rollback_guard$
DECLARE
    v_rows BIGINT;
    v_dep  TEXT;
BEGIN
    -- Nothing to do if the whole slice is already absent.
    IF to_regclass('analytics.derived_parameter_values') IS NULL
       AND to_regprocedure('analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)') IS NULL THEN
        RAISE NOTICE 'Rollback 230: nothing to do (table + function already absent).';
        RETURN;
    END IF;

    -- A later calculation row would make the narrow-CHECK restore unsafe.
    IF to_regclass('config.parameter_calculations') IS NOT NULL THEN
        SELECT count(*) INTO v_rows FROM config.parameter_calculations;
        IF v_rows > 1 THEN
            RAISE EXCEPTION 'Rollback 230 aborted: config.parameter_calculations holds % rows; a later calculation was added -- resolve before rolling back.', v_rows;
        END IF;
        IF EXISTS (
            SELECT 1 FROM config.parameter_calculations pc
            JOIN config.parameters op ON op.id = pc.output_parameter_id
            WHERE pc.materialization_strategy = 'PERSISTED' AND op.code <> 'DEW_POINT'
        ) THEN
            RAISE EXCEPTION 'Rollback 230 aborted: another calculation row is materialization_strategy=PERSISTED -- narrowing the CHECK would fail.';
        END IF;
    END IF;

    -- Anything outside migration 230 depending on the persisted table.
    IF to_regclass('analytics.derived_parameter_values') IS NOT NULL THEN
        SELECT string_agg(DISTINCT obj, ', ') INTO v_dep
        FROM (
            SELECT rw.ev_class::regclass::text AS obj
            FROM pg_depend d
            JOIN pg_rewrite rw ON rw.oid = d.objid AND d.classid = 'pg_rewrite'::regclass
            WHERE d.refobjid = 'analytics.derived_parameter_values'::regclass
              AND d.deptype NOT IN ('a','i')
            UNION
            SELECT p.oid::regprocedure::text
            FROM pg_depend d
            JOIN pg_proc p ON p.oid = d.objid AND d.classid = 'pg_proc'::regclass
            WHERE d.refobjid = 'analytics.derived_parameter_values'::regclass
              AND d.deptype NOT IN ('a','i')
              AND p.proname NOT IN ('refresh_derived_space_dew_point_1min',
                                    'run_derived_space_dew_point_1min_job',
                                    'reconcile_derived_space_dew_point_1min')
        ) s
        WHERE obj IS NOT NULL;
        IF v_dep IS NOT NULL AND v_dep <> '' THEN
            RAISE EXCEPTION 'Rollback 230 aborted: objects outside migration 230 depend on analytics.derived_parameter_values: %', v_dep;
        END IF;
    END IF;

    -- A reconciliation-log row for the new tier blocks the CHECK restore.
    IF to_regclass('analytics.pipeline_reconciliation_log') IS NOT NULL THEN
        SELECT count(*) INTO v_rows FROM analytics.pipeline_reconciliation_log
        WHERE tier = 'derived_space_dew_point_1min';
        IF v_rows > 0 THEN
            RAISE EXCEPTION 'Rollback 230 aborted: analytics.pipeline_reconciliation_log holds % row(s) for tier derived_space_dew_point_1min -- restoring the narrow tier CHECK would fail. Prune those rows first if you really intend to roll back.', v_rows;
        END IF;
    END IF;
END;
$rollback_guard$;


-- ----------------------------------------------------------------------------
-- 1. Deregister both jobs (id looked up by proc name).
-- ----------------------------------------------------------------------------
DO $drop_jobs$
DECLARE
    v_job_id INTEGER;
BEGIN
    FOR v_job_id IN
        SELECT job_id FROM timescaledb_information.jobs
        WHERE (proc_schema, proc_name) IN
            (('telemetry','run_derived_space_dew_point_1min_job'),
             ('analytics','reconcile_derived_space_dew_point_1min'))
    LOOP
        PERFORM delete_job(v_job_id);
        RAISE NOTICE 'Rollback 230: deleted job %', v_job_id;
    END LOOP;
END;
$drop_jobs$;


-- ----------------------------------------------------------------------------
-- 2. Drop the procedures and the calculation function.
-- ----------------------------------------------------------------------------
DROP PROCEDURE IF EXISTS analytics.reconcile_derived_space_dew_point_1min(integer, jsonb);
DROP PROCEDURE IF EXISTS telemetry.run_derived_space_dew_point_1min_job(integer, jsonb);
DROP FUNCTION  IF EXISTS analytics.refresh_derived_space_dew_point_1min(timestamptz, timestamptz);


-- ----------------------------------------------------------------------------
-- 3. Drop the persisted tier's policies, then the table (no CASCADE).
-- ----------------------------------------------------------------------------
DO $drop_policies$
BEGIN
    IF to_regclass('analytics.derived_parameter_values') IS NOT NULL THEN
        PERFORM remove_retention_policy('analytics.derived_parameter_values', if_exists => TRUE);
        PERFORM remove_compression_policy('analytics.derived_parameter_values', if_exists => TRUE);
    END IF;
END;
$drop_policies$;

DROP TABLE IF EXISTS analytics.derived_parameter_values;


-- ----------------------------------------------------------------------------
-- 4. Restore config.parameter_calculations: SPACE_DEW_POINT PERSISTED -> VIEW,
--    then narrow the CHECK back to IN ('VIEW').
-- ----------------------------------------------------------------------------
UPDATE config.parameter_calculations pc
SET materialization_strategy = 'VIEW',
    updated_at               = now()
FROM config.parameters op
WHERE op.id = pc.output_parameter_id
  AND op.code = 'DEW_POINT'
  AND pc.materialization_strategy = 'PERSISTED';

ALTER TABLE config.parameter_calculations
    DROP CONSTRAINT IF EXISTS parameter_calculations_materialization_strategy_check;

ALTER TABLE config.parameter_calculations
    ADD CONSTRAINT parameter_calculations_materialization_strategy_check
    CHECK (materialization_strategy IN ('VIEW'));


-- ----------------------------------------------------------------------------
-- 5. Restore analytics.pipeline_reconciliation_log_tier_chk to the pre-230
--    seven-tier set.
-- ----------------------------------------------------------------------------
ALTER TABLE analytics.pipeline_reconciliation_log
    DROP CONSTRAINT IF EXISTS pipeline_reconciliation_log_tier_chk;

ALTER TABLE analytics.pipeline_reconciliation_log
    ADD CONSTRAINT pipeline_reconciliation_log_tier_chk CHECK (tier IN (
        'energy_consumption_1min', 'energy_consumption_5min', 'energy_consumption_15min',
        'energy_consumption_hourly', 'energy_consumption_daily', 'demand_intervals',
        'environment_daily'));


-- ----------------------------------------------------------------------------
-- 6. Remove the pipeline_state row for the forward tier.
-- ----------------------------------------------------------------------------
DELETE FROM telemetry.pipeline_state WHERE pipeline_name = 'derived_space_dew_point_1min';


-- ----------------------------------------------------------------------------
-- 7. Postconditions.
-- ----------------------------------------------------------------------------
DO $rollback_post$
BEGIN
    IF to_regclass('analytics.derived_parameter_values') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: analytics.derived_parameter_values still exists.';
    END IF;
    IF to_regprocedure('analytics.refresh_derived_space_dew_point_1min(timestamptz,timestamptz)') IS NOT NULL
       OR to_regprocedure('telemetry.run_derived_space_dew_point_1min_job(integer,jsonb)') IS NOT NULL
       OR to_regprocedure('analytics.reconcile_derived_space_dew_point_1min(integer,jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: a Phase-6 procedure/function still exists.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE (proc_schema, proc_name) IN
            (('telemetry','run_derived_space_dew_point_1min_job'),
             ('analytics','reconcile_derived_space_dew_point_1min'))
    ) THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: a Phase-6 job is still registered.';
    END IF;
    IF EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = 'derived_space_dew_point_1min') THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: the pipeline_state row still exists.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM config.parameter_calculations pc
        JOIN config.parameters op ON op.id = pc.output_parameter_id
        WHERE op.code = 'DEW_POINT' AND pc.materialization_strategy <> 'VIEW'
    ) THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: SPACE_DEW_POINT is not back to materialization_strategy=VIEW.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'config.parameter_calculations'::regclass
          AND conname = 'parameter_calculations_materialization_strategy_check'
          AND pg_get_constraintdef(oid) NOT ILIKE '%PERSISTED%'
    ) THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: the materialization_strategy CHECK still permits PERSISTED.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'analytics.pipeline_reconciliation_log'::regclass
          AND conname = 'pipeline_reconciliation_log_tier_chk'
          AND pg_get_constraintdef(oid) LIKE '%derived_space_dew_point_1min%'
    ) THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: pipeline_reconciliation_log_tier_chk still lists the derived tier.';
    END IF;
    -- Pre-existing Phase 4/5 + energy objects intact.
    IF to_regclass('analytics.v_space_dew_point_1min') IS NULL THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: analytics.v_space_dew_point_1min was removed.';
    END IF;
    IF to_regclass('config.parameter_calculations') IS NULL
       OR (SELECT count(*) FROM config.parameter_calculations) <> 1 THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: config.parameter_calculations is missing or not exactly one row.';
    END IF;
    IF (SELECT count(*) FROM config.parameter_routing WHERE is_active AND destination_table = 'telemetry.environment_measurements') <> 12 THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: config.parameter_routing active AirSense rows != 12.';
    END IF;
    IF position('telemetry.energy_measurements' IN
                pg_get_functiondef('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure)) = 0 THEN
        RAISE EXCEPTION 'Rollback 230 postcondition failed: energy loader no longer targets telemetry.energy_measurements.';
    END IF;
END;
$rollback_post$;

COMMIT;
