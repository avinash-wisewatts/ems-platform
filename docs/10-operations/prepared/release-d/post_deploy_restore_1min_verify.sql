-- ============================================================================
-- Release D post-deploy step, verification (READ-ONLY). Pairs with
-- post_deploy_restore_1min_schedules.sql.
--
-- Run twice: immediately after the restore (T0) and about 60 minutes later
-- (T60). Compare the two outputs:
--
--   * SCHEDULE: all six on 1 minute; 1000 / 1001 / 1012 / 1063 fixed, 1044 /
--     1083 not fixed; all scheduled; next_start within the next minute.
--   * RUNS: for each job, total_runs(T60) - total_runs(T0) is 59-61 per 60
--     minutes elapsed; total_failures unchanged; last_run_status Success.
--   * FAILURES: the non-1114 failure total equals the pre-deploy baseline
--     (2,840 on 2026-10-23) and no job errors since the restore.
--   * BACKLOG: checkpoint lag (now - last_received_at) of the four ingest
--     pipelines these jobs drive under 5 minutes (environment may be blank or
--     higher when no environment data arrived); energy routing lag under 5
--     minutes (about 2 minutes on 2026-10-23).
--
--   psql -X -v ON_ERROR_STOP=1 -v restore_at='<UTC timestamp of the restore>' \
--        -f docs/10-operations/prepared/release-d/post_deploy_restore_1min_verify.sql
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\if :{?restore_at}
\else
\echo 'Set -v restore_at=<UTC timestamp of the restore>.'
\quit
\endif

BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';
SET LOCAL TIME ZONE 'UTC';

SELECT now() AS checked_at, :'restore_at'::timestamptz AS restore_at,
       round(extract(epoch FROM now() - :'restore_at'::timestamptz) / 60, 1) AS minutes_since_restore;

-- SCHEDULE and RUNS
SELECT j.job_id, coalesce(j.hypertable_name, j.proc_name) AS job,
       j.schedule_interval, j.fixed_schedule, j.scheduled,
       s.total_runs, s.total_failures, s.last_run_status,
       s.last_run_started_at, s.last_run_duration, s.next_start
FROM timescaledb_information.jobs j
JOIN timescaledb_information.job_stats s USING (job_id)
WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                       ('telemetry', 'run_energy_routing_job'),
                                       ('telemetry', 'run_environment_routing_job'),
                                       ('analytics', 'run_energy_consumption_1min_job'))
   OR (j.proc_name = 'policy_refresh_continuous_aggregate'
       AND j.hypertable_name IN ('ca_energy_1min', 'ca_energy_phase_power_1min'))
ORDER BY j.job_id;

-- FAILURES
SELECT sum(total_failures) FILTER (WHERE job_id <> 1114) AS failures_excl_1114,
       count(*) FILTER (WHERE last_run_status = 'Failed') AS jobs_failing
FROM timescaledb_information.job_stats;

SELECT job_id, proc_name, start_time, sqlerrcode, left(err_message, 120) AS err_message
FROM timescaledb_information.job_errors
WHERE start_time >= :'restore_at'::timestamptz
ORDER BY start_time;

-- BACKLOG
SELECT pipeline_name, last_status, last_completed_at,
       round(extract(epoch FROM now() - last_received_at)) AS checkpoint_lag_s
FROM telemetry.pipeline_state
WHERE pipeline_name IN ('normalized_points', 'energy_measurements',
                        'environment_measurements', 'energy_consumption_1min')
ORDER BY pipeline_name;

SELECT round(extract(epoch FROM now() - max(received_at))) AS energy_routing_lag_s
FROM telemetry.energy_measurements
WHERE received_at > now() - INTERVAL '1 hour';

ROLLBACK;
