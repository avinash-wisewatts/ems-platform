-- ============================================================================
-- Job-duration sampler (release-plan precheck P11). READ-ONLY.
--
-- Every 30 s for 24 h (2,880 samples) records, for the ingest and routing
-- jobs, the last run's start, duration, status, total runs / failures and the
-- matching telemetry.pipeline_state rows-per-run and lag. Each sample is one
-- short catalog read (timescaledb_information.jobs / job_stats, the small
-- telemetry.pipeline_state table); no hypertable is read.
--
-- Jobs are found by procedure / hypertable name, so job IDs never need to be
-- copied (production 2026-10-16: 1000, 1001, 1012, 1044, 1083, 1063, 1062,
-- 1060, 1053).
--
-- Why 24 h: job_history keeps failures only, so per-run durations exist only
-- as the latest run in job_stats; 30 s sampling catches every run of the
-- 1-minute jobs (the 2026-10-16 60-minute sample caught 60 / 60 normalization
-- runs). It also records natural catch-up runs of normalization (rows per run
-- well above the usual 3,144) -- real multi-minute batch timings obtained
-- without delaying any job.
--
-- Run (production only with explicit authorization), output to a local file:
--   psql -X -v ON_ERROR_STOP=1 -f scripts/diagnostics/prod_job_duration_sampler.sql > samples.txt
-- through the read-only helper (default_transaction_read_only=on). Stop early
-- with Ctrl-C / by ending the SSH session; nothing needs cleaning up.
-- Output: one '|'-separated line per job per sample:
--   sample_utc|job_id|role|started_utc|duration_s|last_status|job_status|total_runs|total_failures|rows|lag_s
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
\pset tuples_only on
SET statement_timeout = '10s';
SET lock_timeout = '1s';
SET application_name = 'ems_p11_job_sampler';
SHOW default_transaction_read_only;

SELECT to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS sample_utc,
       j.job_id,
       CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END AS role,
       to_char(s.last_run_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS started_utc,
       round(extract(epoch FROM s.last_run_duration)::numeric, 2) AS duration_s,
       s.last_run_status,
       s.job_status,
       s.total_runs,
       s.total_failures,
       ps.last_inserted_rows AS rows,
       round(extract(epoch FROM now() - ps.last_received_at)) AS lag_s
FROM timescaledb_information.jobs AS j
JOIN timescaledb_information.job_stats AS s USING (job_id)
LEFT JOIN telemetry.pipeline_state AS ps
       ON ps.pipeline_name = CASE j.proc_name
            WHEN 'run_normalization_job'           THEN 'normalized_points'
            WHEN 'run_energy_routing_job'          THEN 'energy_measurements'
            WHEN 'run_environment_routing_job'     THEN 'environment_measurements'
            WHEN 'run_energy_consumption_1min_job' THEN 'energy_consumption_1min'
            WHEN 'run_demand_calculation_job'      THEN 'demand_intervals'
            WHEN 'run_raw_receipt_state_job'       THEN 'raw_receipt_state'
            WHEN 'run_routing_late_sweep_job'      THEN 'energy_measurements_late_sweep'
          END
WHERE j.proc_name IN ('run_normalization_job', 'run_energy_routing_job', 'run_environment_routing_job',
                      'run_energy_consumption_1min_job', 'run_demand_calculation_job',
                      'run_raw_receipt_state_job', 'run_routing_late_sweep_job')
   OR (j.proc_name = 'policy_refresh_continuous_aggregate'
       AND j.hypertable_name IN ('ca_energy_1min', 'ca_energy_phase_power_1min'))
   OR (j.proc_name = 'policy_compression' AND j.hypertable_name = 'raw_messages')
ORDER BY j.job_id
\watch i=30 c=2880
