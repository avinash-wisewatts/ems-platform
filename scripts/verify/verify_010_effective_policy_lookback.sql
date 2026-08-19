\echo '=== 010 MIGRATION LEDGER ==='
SELECT migration_id, applied_at, execution_ms
FROM admin.schema_migrations
WHERE migration_id = '010_effective_policy_lookback';

\echo ''
\echo '=== ACTIVE CAPTURE POLICY HORIZON ==='
SELECT
    p.site_id,
    p.capture_interval_seconds,
    p.late_arrival_tolerance_seconds,
    p.effective_from,
    p.effective_to,
    p.effective_to + make_interval(secs => p.capture_interval_seconds + p.late_arrival_tolerance_seconds) AS influence_through
FROM config.telemetry_capture_policies p
WHERE p.is_enabled
ORDER BY p.effective_to NULLS LAST, p.effective_from;

\echo ''
\echo '=== NORMALIZATION JOB ==='
SELECT job_id,last_run_status,last_run_started_at,last_successful_finish,last_run_duration,total_runs,total_successes,total_failures
FROM timescaledb_information.job_stats
WHERE job_id=1000;

\echo ''
\echo '=== NORMALIZATION PIPELINE STATE ==='
SELECT last_received_at,last_started_at,last_completed_at,last_inserted_rows,last_status,last_error
FROM telemetry.pipeline_state
WHERE pipeline_name='normalized_points';
