-- ============================================================================
-- Migration 212
-- Phase 2 Foundation, Phase 0 (completion): bounded normalization forward window
-- for job 1000 (N1).
--
-- Root cause (identical class to the 2026-08-26 incident, and to what migration
-- 207 fixed one hop downstream for the routing jobs):
--   telemetry.run_normalization_job calls
--       CALL telemetry.load_normalized_points_incremental(v_overlap);
--   with ONE argument, leaving p_max_window at its DEFAULT NULL. The loader then
--   computes its forward endpoint as max(telemetry.raw_messages.received_at)
--   with no cap and processes the entire forward window in ONE transaction. Once
--   the gap between the checkpoint and "now" grows wider than the job's
--   5-minute max_runtime, every retry faces an equal-or-wider window and can
--   make zero durable progress -- exactly the job-1000 stall of 2026-08-26.
--
-- Migration 205 already added the bounded-window mechanism to the loader:
--       telemetry.load_normalized_points_incremental(
--           IN p_overlap    interval DEFAULT '00:05:00',
--           IN p_max_window interval DEFAULT NULL)
--   with, when p_max_window IS NOT NULL and a previous checkpoint exists,
--       v_window_end := LEAST(v_window_end, v_previous_checkpoint + p_max_window);
--   NULL preserves the exact pre-205 behaviour; a one-argument or explicit-NULL
--   manual CALL still performs unrestricted forward catch-up.
--
-- This migration is the migration-207 wrapper pattern applied to job 1000:
--   1. telemetry.run_normalization_job -- CREATE OR REPLACE (arity unchanged,
--      no DROP). The deployed body is preserved verbatim except that it now
--      derives v_max_window from config.max_window (default INTERVAL '2 hours',
--      positive-only) and ALWAYS passes it to the loader as the second argument.
--      It never passes NULL. The wrapper does NOT duplicate the loader's
--      advisory lock / pipeline_state / RUNNING-SUCCESS-NO_SOURCE_DATA-
--      SKIPPED_LOCKED-FAILED handling / single-transaction / EXCEPTION->RAISE
--      rollback / dynamic overlap / 48h bounded first run -- all of that stays
--      exactly where it already lives, in the loader.
--   2. job 1000's live config gains "max_window": "2 hours" via alter_job
--      (idempotent, guarded; preserves the existing "overlap": "15 minutes"
--      and any other key).
--
-- The 2-hour default is PROVISIONAL pending a staging job-1000 runtime read
-- (job_stats / job_history per-run duration distribution). It is overridable
-- through config.max_window with no code change (alter_job). If staging
-- evidence later shows 2h is too large for the 5-minute max_runtime, the
-- correct remedy is an alter_job to 1 hour -- NOT a code change.
--
-- NOT touched by this migration:
--   telemetry.load_normalized_points_incremental (already has p_max_window);
--   the loader's lock/state/transaction/rollback/overlap/first-run logic;
--   normalization calculation semantics; telemetry.normalized_points /
--   telemetry.raw_messages / telemetry.capture_bucket_samples schemas;
--   job 1000's schedule_interval (1 minute), max_runtime (5 minutes),
--   max_retries (3), retry_period (1 minute), scheduled flag;
--   postgres/jobs/42_normalization_background_job.sql (canonical file --
--   migration 207 set the precedent of not touching the canonical jobs/*.sql
--   when a migration redefines a wrapper);
--   postgres/maintenance/45_rebuild_normalized_history.sql (the manual
--   unrestricted rebuild path -- a bare / explicit-NULL loader CALL remains
--   unrestricted);
--   the routing jobs (1001/1012), energy consumption, demand, environment_daily,
--   any CAGG or its policies, Grafana, application/API code;
--   ownership / SECURITY / search_path / ACL of any object (CREATE OR REPLACE
--   preserves them; migration 207 did not re-issue them for the sibling
--   wrappers).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. telemetry.run_normalization_job -- bounded forward window via
--    config.max_window (default 2 hours). Deployed body preserved verbatim
--    except the max_window derivation, its positive-only validation, the
--    RAISE NOTICE text, and the second CALL argument.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.run_normalization_job(IN job_id integer, IN config jsonb)
 LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_overlap    INTERVAL := INTERVAL '15 minutes';
    v_max_window INTERVAL := INTERVAL '2 hours';
BEGIN
    -- Allow the overlap window to be changed declaratively through the
    -- TimescaleDB job configuration.
    IF config IS NOT NULL
       AND config ? 'overlap'
       AND NULLIF(BTRIM(config ->> 'overlap'), '') IS NOT NULL
    THEN
        v_overlap := (config ->> 'overlap')::INTERVAL;
    END IF;

    -- Migration 212: bounded catch-up. The scheduled action ALWAYS passes a
    -- positive p_max_window so an unattended multi-hour raw_messages backlog
    -- self-drains over successive 1-minute runs rather than being attempted as
    -- one unbounded transaction that can make no durable progress once the gap
    -- exceeds max_runtime. Tunable via config.max_window (alter_job, no code
    -- change); it is never cleared to NULL through this wrapper. Unrestricted
    -- catch-up remains available by CALLing
    -- telemetry.load_normalized_points_incremental(...) directly (e.g.
    -- postgres/maintenance/45_rebuild_normalized_history.sql).
    IF config IS NOT NULL
       AND config ? 'max_window'
       AND NULLIF(BTRIM(config ->> 'max_window'), '') IS NOT NULL
    THEN
        v_max_window := (config ->> 'max_window')::INTERVAL;
    END IF;


    IF v_overlap < INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Normalization job overlap cannot be negative: %',
            v_overlap;
    END IF;

    IF v_max_window IS NULL OR v_max_window <= INTERVAL '0 seconds' THEN
        RAISE EXCEPTION
            'Normalization job max_window must be a positive interval: %',
            v_max_window;
    END IF;


    RAISE NOTICE
        'Starting normalization job %, overlap=%, max_window=%',
        job_id,
        v_overlap,
        v_max_window;


    CALL telemetry.load_normalized_points_incremental(v_overlap, v_max_window);


    RAISE NOTICE
        'Completed normalization job %',
        job_id;
END;
$procedure$;

COMMENT ON PROCEDURE telemetry.run_normalization_job(integer, jsonb) IS
'TimescaleDB background action that executes the incremental normalized telemetry loader. Migration 212: always passes a bounded p_max_window (default INTERVAL ''2 hours'', overridable via config.max_window with no code change) to telemetry.load_normalized_points_incremental(), so an unattended multi-hour telemetry.raw_messages backlog self-drains over successive 1-minute runs instead of being attempted as one unbounded transaction. Never passes NULL. Unrestricted forward catch-up remains available by CALLing the loader directly (postgres/maintenance/45_rebuild_normalized_history.sql). The advisory lock, telemetry.pipeline_state RUNNING/SUCCESS/NO_SOURCE_DATA/SKIPPED_LOCKED/FAILED handling, single-transaction boundary, EXCEPTION->FAILED->RAISE rollback, dynamic overlap and 48h bounded first run all remain in the loader and are unchanged. The 2-hour default is provisional pending a staging job-1000 runtime measurement; the remedy for a too-large default is an alter_job to 1 hour, not a code change.';

-- ----------------------------------------------------------------------------
-- 2. Record the bound in the live job config (idempotent, order-independent).
--    Merges the max_window key into whatever config the job already carries,
--    preserving config.overlap and any other key. Skips silently if the job is
--    not registered (e.g. a migration-only apply before postgres/jobs/* has
--    run). Mirrors migration 207 section 4 exactly.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT job_id, config
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry'
          AND proc_name = 'run_normalization_job'
    LOOP
        IF NOT (COALESCE(r.config, '{}'::jsonb) ? 'max_window') THEN
            PERFORM alter_job(
                r.job_id,
                config => COALESCE(r.config, '{}'::jsonb)
                          || jsonb_build_object('max_window', '2 hours')
            );
            RAISE NOTICE 'Migration 212: added config.max_window=''2 hours'' to job %', r.job_id;
        END IF;
    END LOOP;
END $$;

COMMIT;
