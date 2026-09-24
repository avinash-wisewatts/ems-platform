-- ============================================================================
-- Migration 266
-- Analytical backbone M2 (stage 2 of 2): activate the analytics.point_telemetry_1h
-- jobs that migration 265 registered UNSCHEDULED.
--
-- Decision record: docs/00-governance/decisions/ADR-019-analytical-backbone-
-- time-basis-and-tiers.md (M2 two-stage rollout).
--
-- PRECONDITION (operational, not checkable here): the bounded 1h backfill has
-- been run and validated on the target environment. On staging this was done
-- 2026-09-24 for [2026-08-24 15:00, 2026-09-24 11:00) UTC.
--
-- WHAT
--   Sets scheduled = true on exactly the four jobs migration 265 created:
--     * policy_retention   on analytics.point_telemetry_1h (drop_after 1 year)
--     * policy_compression on analytics.point_telemetry_1h (compress_after 30 days)
--     * analytics.run_point_telemetry_1h_job   (forward, every 15 minutes)
--     * analytics.reconcile_point_telemetry_1h (reconcile, daily, 35 days, n_max 7)
--   Nothing else changes: schedule_interval, config, max_runtime, max_retries,
--   retry_period, fixed_schedule and initial_start are preserved exactly as
--   migration 265 set them, and verified before and after.
--
-- next_start
--   TimescaleDB, when re-scheduling a fixed-schedule job whose initial_start
--   is in the past, picks a next_start in the past, so the job fires the
--   moment it is activated. To keep migration 265's grid, each fixed-schedule
--   job's next_start is set explicitly to the first slot of its own grid
--   (initial_start + k * schedule_interval) that is not before now():
--     forward job   -> the next :07 / :22 / :37 / :52 UTC slot (15-minute grid)
--     reconcile job -> the next 22:30 UTC (one hour after the 15m late-data policy)
--   The retention and compression policies are not fixed-schedule; TimescaleDB
--   runs them shortly after activation and every schedule_interval after that.
--
-- IDEMPOTENT
--   A job that is already scheduled is left exactly as it is, including its
--   next_start. Re-running this file changes nothing.
--
-- NOT in this migration
--   No schema change, no data change, no backfill, no refresh call, no
--   telemetry.pipeline_state write (the forward job alone writes its
--   checkpoint, from its first run). M1, the legacy Explorer aggregates,
--   Energy, Demand, Power Quality, the dew-point tier and every other job keep
--   their scheduled state, verified below.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Preconditions: exactly the four migration-265 jobs, configured exactly as
--    migration 265 created them. Any drift stops the migration.
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    v_count INTEGER;
BEGIN
    IF to_regclass('analytics.point_telemetry_1h') IS NULL THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: analytics.point_telemetry_1h (migration 265) is missing.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM telemetry.pipeline_state WHERE pipeline_name = 'point_telemetry_1h') THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: pipeline_state row point_telemetry_1h is missing.';
    END IF;

    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE (proc_schema = 'analytics' AND proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
       OR (hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h');
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: expected exactly 4 point_telemetry_1h jobs, found %.', v_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'run_point_telemetry_1h_job'
          AND schedule_interval = INTERVAL '15 minutes'
          AND fixed_schedule
          AND initial_start IS NOT NULL
          AND max_runtime = INTERVAL '10 minutes' AND max_retries = 3 AND retry_period = INTERVAL '5 minutes'
          AND config = '{"lookback": "2 days", "max_catchup_window": "2 days", "overlap": "2 hours"}'::JSONB
    ) THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: run_point_telemetry_1h_job differs from migration 265.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'reconcile_point_telemetry_1h'
          AND schedule_interval = INTERVAL '1 day'
          AND fixed_schedule
          AND initial_start IS NOT NULL
          AND (initial_start AT TIME ZONE 'UTC')::TIME = TIME '22:30'
          AND max_runtime = INTERVAL '30 minutes' AND max_retries = 3 AND retry_period = INTERVAL '30 minutes'
          AND config = '{"reconcile_window": "35 days", "coarse": "1 day", "n_max": 7}'::JSONB
    ) THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: reconcile_point_telemetry_1h differs from migration 265.';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
          AND proc_name = 'policy_retention' AND config ->> 'drop_after' = '1 year'
    ) OR NOT EXISTS (
        SELECT 1 FROM timescaledb_information.jobs
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
          AND proc_name = 'policy_compression' AND config ->> 'compress_after' = '30 days'
    ) THEN
        RAISE EXCEPTION 'Migration 266 precondition failed: retention (1 year) / compression (30 days) policy differs from migration 265.';
    END IF;
END
$pre$;


-- ----------------------------------------------------------------------------
-- 2. Snapshot every job's definition so the postconditions can prove that
--    only the four M2 jobs changed, and only their scheduled flag / next_start.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE m266_jobs_before ON COMMIT DROP AS
SELECT
    job_id,
    proc_schema,
    proc_name,
    hypertable_schema,
    hypertable_name,
    scheduled,
    schedule_interval,
    max_runtime,
    max_retries,
    retry_period,
    fixed_schedule,
    initial_start,
    config,
    (   (proc_schema = 'analytics' AND proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
     OR (hypertable_schema IS NOT DISTINCT FROM 'analytics' AND hypertable_name IS NOT DISTINCT FROM 'point_telemetry_1h')
    ) AS is_m2
FROM timescaledb_information.jobs;


-- ----------------------------------------------------------------------------
-- 3. Activate (only jobs that are not already scheduled).
-- ----------------------------------------------------------------------------
DO $activate$
DECLARE
    r      RECORD;
    v_next TIMESTAMPTZ;
BEGIN
    FOR r IN
        SELECT j.job_id, j.proc_name, j.schedule_interval, j.fixed_schedule, j.initial_start
        FROM timescaledb_information.jobs AS j
        WHERE NOT j.scheduled
          AND (   (j.proc_schema = 'analytics' AND j.proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
               OR (j.hypertable_schema = 'analytics' AND j.hypertable_name = 'point_telemetry_1h'))
        ORDER BY j.job_id
    LOOP
        IF r.fixed_schedule AND r.initial_start IS NOT NULL THEN
            -- First slot of the job's own grid that is not before now().
            IF r.initial_start >= now() THEN
                v_next := r.initial_start;
            ELSE
                v_next := r.initial_start
                          + r.schedule_interval
                            * ceil(extract(epoch FROM (now() - r.initial_start))
                                   / extract(epoch FROM r.schedule_interval));
            END IF;

            PERFORM alter_job(r.job_id, scheduled => TRUE, next_start => v_next);
            RAISE NOTICE 'Migration 266: activated % (job %), next_start %', r.proc_name, r.job_id, v_next;
        ELSE
            PERFORM alter_job(r.job_id, scheduled => TRUE);
            RAISE NOTICE 'Migration 266: activated % (job %)', r.proc_name, r.job_id;
        END IF;
    END LOOP;
END
$activate$;


-- ----------------------------------------------------------------------------
-- 4. Postconditions.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    v_count INTEGER;
BEGIN
    -- All four M2 jobs are scheduled.
    SELECT count(*) INTO v_count
    FROM timescaledb_information.jobs
    WHERE scheduled
      AND (   (proc_schema = 'analytics' AND proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
           OR (hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'));
    IF v_count <> 4 THEN
        RAISE EXCEPTION 'Migration 266 postcondition failed: expected 4 scheduled point_telemetry_1h jobs, found %.', v_count;
    END IF;

    -- No job appeared or disappeared.
    IF (SELECT count(*) FROM timescaledb_information.jobs) <> (SELECT count(*) FROM m266_jobs_before) THEN
        RAISE EXCEPTION 'Migration 266 postcondition failed: the set of jobs changed.';
    END IF;

    -- Every job definition is unchanged; only the M2 jobs' scheduled flag may differ.
    IF EXISTS (
        SELECT 1
        FROM m266_jobs_before AS b
        LEFT JOIN timescaledb_information.jobs AS a ON a.job_id = b.job_id
        WHERE a.job_id IS NULL
           OR a.schedule_interval IS DISTINCT FROM b.schedule_interval
           OR a.max_runtime       IS DISTINCT FROM b.max_runtime
           OR a.max_retries       IS DISTINCT FROM b.max_retries
           OR a.retry_period      IS DISTINCT FROM b.retry_period
           OR a.fixed_schedule    IS DISTINCT FROM b.fixed_schedule
           OR a.initial_start     IS DISTINCT FROM b.initial_start
           OR a.config            IS DISTINCT FROM b.config
           OR (NOT b.is_m2 AND a.scheduled IS DISTINCT FROM b.scheduled)
    ) THEN
        RAISE EXCEPTION 'Migration 266 postcondition failed: a job definition changed, or a non-M2 job''s scheduled state changed.';
    END IF;

    RAISE NOTICE 'Migration 266: all postconditions passed (4 point_telemetry_1h jobs scheduled; every job definition and every non-M2 scheduled state unchanged).';
END
$post$;
