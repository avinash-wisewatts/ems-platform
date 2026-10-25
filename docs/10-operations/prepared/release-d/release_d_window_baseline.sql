-- ============================================================================
-- Release D acceptance window: baseline snapshot (READ-ONLY).
--
-- Run once at the start of an observation window. It records the window start
-- (w0), each acceptance job's total_runs, found by name (job IDs differ between
-- staging and production), and the failure total excluding job 1114, then
-- prints the psql variables for release_d_acceptance_window.sql:
--
--   psql -X -v ON_ERROR_STOP=1 -f docs/10-operations/prepared/release-d/release_d_window_baseline.sql
--
-- Keep the printed "-v" line with the window's evidence. Role keys are
-- proc_name, or proc_name:hypertable_name for policy jobs.
-- ============================================================================
\set ON_ERROR_STOP on
\pset footer off
BEGIN TRANSACTION READ ONLY;
SET LOCAL statement_timeout = '30s';
SET LOCAL lock_timeout = '2s';
SET LOCAL TIME ZONE 'UTC';

SHOW default_transaction_read_only;

WITH roles AS (
    SELECT j.job_id,
           CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END AS role,
           j.scheduled, j.schedule_interval, s.total_runs, s.total_failures, s.last_run_status
    FROM timescaledb_information.jobs j
    JOIN timescaledb_information.job_stats s USING (job_id)
    WHERE j.proc_name IN ('run_normalization_job', 'run_energy_routing_job', 'run_environment_routing_job',
                          'run_energy_consumption_1min_job', 'run_demand_calculation_job',
                          'run_raw_receipt_state_job', 'run_routing_late_sweep_job')
       OR (j.proc_name = 'policy_refresh_continuous_aggregate'
           AND j.hypertable_name IN ('ca_energy_1min', 'ca_energy_phase_power_1min')))
SELECT * FROM roles ORDER BY role;

-- Exactly one job per role, or the baseline is ambiguous.
SELECT CASE WHEN count(*) = count(DISTINCT role) THEN 'OK: one job per role'
            ELSE 'STOP: duplicate jobs for a role' END AS role_check
FROM (SELECT CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END AS role
      FROM timescaledb_information.jobs j
      WHERE j.proc_name IN ('run_normalization_job', 'run_energy_routing_job', 'run_environment_routing_job',
                            'run_energy_consumption_1min_job', 'run_demand_calculation_job',
                            'run_raw_receipt_state_job', 'run_routing_late_sweep_job')
         OR (j.proc_name = 'policy_refresh_continuous_aggregate'
             AND j.hypertable_name IN ('ca_energy_1min', 'ca_energy_phase_power_1min'))) r;

\echo === psql variables for release_d_acceptance_window.sql
SELECT format('-v w0=%L -v baseline=%L -v failures0=%s',
              to_char(now(), 'YYYY-MM-DD HH24:MI:SS.US+00'),
              string_agg(role || '=' || total_runs, ',' ORDER BY role),
              (SELECT sum(total_failures) FROM timescaledb_information.job_stats WHERE job_id <> 1114)) AS psql_args
FROM (
    SELECT CASE WHEN j.proc_name LIKE 'policy_%' THEN j.proc_name || ':' || j.hypertable_name ELSE j.proc_name END AS role,
           s.total_runs
    FROM timescaledb_information.jobs j
    JOIN timescaledb_information.job_stats s USING (job_id)
    WHERE j.proc_name IN ('run_normalization_job', 'run_energy_routing_job', 'run_environment_routing_job',
                          'run_energy_consumption_1min_job', 'run_demand_calculation_job',
                          'run_raw_receipt_state_job', 'run_routing_late_sweep_job')
       OR (j.proc_name = 'policy_refresh_continuous_aggregate'
           AND j.hypertable_name IN ('ca_energy_1min', 'ca_energy_phase_power_1min'))) r;

ROLLBACK;
