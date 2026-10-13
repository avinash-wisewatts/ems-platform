-- ============================================================================
-- Migration 298
-- Plan T1.3c-1 (staging optimization plan, run 11): the demand forward job
-- (analytics.run_demand_calculation_job, job 1078 on staging) runs every
-- 15 minutes at UTC quarter-hour + 7 minutes (:07, :22, :37, :52) instead of
-- every minute. Schedule only.
--
-- Why this is safe (read-only review of migration 210 + staging evidence,
-- plan section 5C):
--
--   * The job finalizes by WATERMARK, not by cadence. Each run finalizes every
--     closed interval in [checkpoint - overlap, v_to) with
--       v_to = date_bin('15 minutes',
--                LEAST(now - grace, parent_frontier, checkpoint + max_catchup_window))
--       grace = max(enabled late_arrival_tolerance_seconds) + 300 s (330 s today)
--     and advances the checkpoint to v_to only on success. v_to moves in
--     15-minute steps whatever the cadence, so 14 of every 15 one-minute runs
--     today return early without work; a missed, failed or late run is
--     recovered by the next one (a skipped slot widens that run's window).
--   * Catch-up: up to max_catchup_window (6 h) per run -> 24 h of backlog per
--     hour at 15 minutes (was 6 h per minute). The forward window is
--     additionally bounded by the parent frontier
--     LEAST(max energy_measurements.bucket_start, max normalized_points.event_time),
--     so the job never finalizes ahead of routed source data.
--   * Late readings: unchanged. Readings count only if received by
--     interval_end + late_arrival_tolerance (30 s); each interval is still
--     re-examined by the next two watermark steps (overlap 30 min) and by the
--     hourly reconciler (6 h window), and VALID rows stay immutable.
--   * Phase: a slot at quarter + 7 min is after quarter + grace (5 min 30 s),
--     so the interval that just ended is finalized in that slot. The extra
--     90 s over today's ~5.9 min leaves more time for readings received at the
--     30 s deadline to be normalized and routed (energy_measurements lag
--     ~3 min) before the first attempt. Every real-world UTC offset is a
--     multiple of 15 minutes, so UTC quarter-hours are site-local
--     quarter-hours (IST: :07 UTC = :37 IST).
--   * Latency of a completed interval: ~interval_end + 7 min (was ~5.9 min).
--     demand_state (written by the same run) still updates once per
--     interval, as today. The reconciler 1121 runs at :29 and takes the same
--     advisory lock for ~17 s; the :07/:22/:37/:52 slots do not collide.
--
-- Changes: schedule_interval 1 minute -> 15 minutes; fixed_schedule TRUE with
-- initial_start (the grid origin) at the next quarter-hour + 7 minutes;
-- next_start = that slot (demand finalization pauses at most ~15 minutes
-- once, at deploy).
--
-- NOT changed: procedure bodies (run_demand_calculation_job,
-- refresh_demand_analytics, calculate_demand_window, resolve_demand_interval),
-- job config (lookback 3 h, max_catchup_window 6 h, overlap 30 min,
-- reconcile_window 6 h), max_runtime 10 min, max_retries 3, retry_period
-- 5 min, check_config, the late-arrival tolerance, schema, data, and every
-- other job (including reconciler 1121).
--
-- Rollback (no data component):
--   SELECT alter_job(<job_id>, schedule_interval => INTERVAL '1 minute');
-- ============================================================================

DO $pre$
DECLARE
    v_jobs  integer;
    v_grace interval;
BEGIN
    SELECT count(*) INTO v_jobs
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'analytics' AND proc_name = 'run_demand_calculation_job';
    IF v_jobs <> 1 THEN
        RAISE EXCEPTION 'Migration 298: expected exactly one analytics.run_demand_calculation_job job, found %', v_jobs;
    END IF;

    -- The job's own grace; the 7-minute phase must not be earlier.
    v_grace := make_interval(secs => COALESCE(
        (SELECT max(late_arrival_tolerance_seconds) FROM config.site_demand_policies WHERE is_enabled), 0) + 300);
    IF v_grace > INTERVAL '7 minutes' THEN
        RAISE WARNING 'Migration 298: demand grace % exceeds the 7-minute schedule phase; each interval will be finalized one slot (15 minutes) later than intended. Review the phase.', v_grace;
    END IF;
END
$pre$;

DO $sched$
DECLARE
    v_origin CONSTANT timestamptz := TIMESTAMPTZ '2000-01-01 00:00:00+00';
    v_phase  CONSTANT interval    := INTERVAL '7 minutes';
    v_every  CONSTANT interval    := INTERVAL '15 minutes';
    v_start  timestamptz;
    b        RECORD;
    r        RECORD;
BEGIN
    SELECT j.job_id, j.scheduled, j.max_runtime, j.max_retries, j.retry_period,
           j.config, j.check_schema, j.check_name
    INTO STRICT b
    FROM timescaledb_information.jobs AS j
    WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_demand_calculation_job';

    -- Next quarter-hour + 7 minutes (UTC) that is not before now().
    v_start := date_bin(v_every, now(), v_origin) + v_phase;
    IF v_start < now() THEN
        v_start := v_start + v_every;
    END IF;

    PERFORM alter_job(
        b.job_id,
        schedule_interval => v_every,
        fixed_schedule    => TRUE,
        initial_start     => v_start,
        next_start        => v_start
    );

    -- Postconditions: the schedule changed and nothing else did.
    SELECT j.schedule_interval, j.fixed_schedule, j.initial_start, j.scheduled,
           j.max_runtime, j.max_retries, j.retry_period, j.config,
           j.check_schema, j.check_name
    INTO STRICT r
    FROM timescaledb_information.jobs AS j
    WHERE j.job_id = b.job_id;

    IF r.schedule_interval <> v_every OR NOT r.fixed_schedule THEN
        RAISE EXCEPTION 'Migration 298: schedule is % (fixed %), expected 15 minutes fixed',
            r.schedule_interval, r.fixed_schedule;
    END IF;
    IF (extract(epoch FROM r.initial_start)::bigint % 900) <> 420 THEN
        RAISE EXCEPTION 'Migration 298: initial_start % is not a UTC quarter-hour + 7 minutes', r.initial_start;
    END IF;
    IF (r.scheduled, r.max_runtime, r.max_retries, r.retry_period, r.config, r.check_schema, r.check_name)
       IS DISTINCT FROM
       (b.scheduled, b.max_runtime, b.max_retries, b.retry_period, b.config, b.check_schema, b.check_name) THEN
        RAISE EXCEPTION 'Migration 298: a job setting other than the schedule changed';
    END IF;

    RAISE NOTICE 'Migration 298: job % (analytics.run_demand_calculation_job) every %, first run %',
        b.job_id, v_every, v_start;
END
$sched$;
