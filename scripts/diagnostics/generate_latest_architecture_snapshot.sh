#!/usr/bin/env bash
set -euo pipefail

ROOT="/opt/ems-platform"
OUT_DIR="${ROOT}/snapshots"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT_DIR}/ems-architecture-snapshot-${STAMP}.txt"

mkdir -p "$OUT_DIR"

exec > >(tee "$OUT") 2>&1

echo "================================================================"
echo "EMS PLATFORM ARCHITECTURE SNAPSHOT"
echo "================================================================"
echo "Generated: $(date -Is)"
echo "Host: $(hostname)"
echo

section() {
    echo
    echo "================================================================"
    echo "$1"
    echo "================================================================"
}

psql_exec() {
    docker compose exec -T timescaledb \
        psql -X -U ems_admin -d ems -P pager=off "$@"
}

section "1. GIT"

git branch --show-current
git rev-parse HEAD
git status --short
git remote -v
git log --oneline --decorate -10

section "2. DOCKER"

docker compose ps

section "3. DATABASE / TIMESCALE"

psql_exec -c "
SELECT version();

SELECT extname, extversion
FROM pg_extension
WHERE extname = 'timescaledb';
"

section "4. DATABASE OBJECTS"

psql_exec -c "
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        WHEN 'p' THEN 'partitioned_table'
        ELSE c.relkind::text
    END AS object_type
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN
    ('analytics','telemetry','metadata','config','admin','public')
AND c.relkind IN ('r','v','m','p')
ORDER BY n.nspname, object_type, c.relname;
"

section "5. HYPERTABLES"

psql_exec -c "
SELECT
    hypertable_schema,
    hypertable_name,
    num_chunks,
    compression_enabled
FROM timescaledb_information.hypertables
ORDER BY hypertable_schema, hypertable_name;
"

section "6. CONTINUOUS AGGREGATES"

psql_exec -c "
SELECT
    view_schema,
    view_name,
    materialization_hypertable_schema,
    materialization_hypertable_name,
    materialized_only,
    finalized
FROM timescaledb_information.continuous_aggregates
ORDER BY view_schema, view_name;
"

section "7. TIMESCALE JOBS"

psql_exec -c "
SELECT
    job_id,
    proc_schema,
    proc_name,
    hypertable_schema,
    hypertable_name,
    schedule_interval,
    scheduled,
    config,
    next_start
FROM timescaledb_information.jobs
ORDER BY job_id;
"

section "8. JOB HEALTH"

psql_exec -c "
SELECT
    j.job_id,
    j.proc_schema,
    j.proc_name,
    j.scheduled,
    s.last_run_status,
    s.last_run_started_at,
    s.last_successful_finish,
    s.total_runs,
    s.total_successes,
    s.total_failures
FROM timescaledb_information.jobs j
LEFT JOIN timescaledb_information.job_stats s
    ON s.job_id = j.job_id
ORDER BY j.job_id;
"

section "9. RECENT JOB ERRORS"

psql_exec -c "
SELECT *
FROM timescaledb_information.job_errors
ORDER BY finish_time DESC
LIMIT 50;
" || true

section "10. COMPRESSION + RETENTION"

psql_exec -c "
SELECT
    job_id,
    proc_name,
    hypertable_schema,
    hypertable_name,
    schedule_interval,
    config
FROM timescaledb_information.jobs
WHERE proc_name IN
    ('policy_compression','policy_retention')
ORDER BY hypertable_schema, hypertable_name, proc_name;
"

section "11. CAGG REFRESH POLICIES"

psql_exec -c "
SELECT
    job_id,
    proc_name,
    hypertable_schema,
    hypertable_name,
    schedule_interval,
    config
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_refresh_continuous_aggregate'
ORDER BY hypertable_schema, hypertable_name;
"

section "12. INDEXES"

psql_exec -c "
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname IN
    ('analytics','telemetry','metadata','config','admin')
ORDER BY schemaname, tablename, indexname;
"

section "13. KEY ENERGY DATA"

psql_exec -c "
SELECT
    'energy_consumption_1min' AS object,
    count(*) AS rows,
    min(bucket_start) AS earliest,
    max(bucket_start) AS latest
FROM analytics.energy_consumption_1min

UNION ALL

SELECT
    'energy_consumption_5min',
    count(*),
    min(bucket_start),
    max(bucket_start)
FROM analytics.energy_consumption_5min

UNION ALL

SELECT
    'energy_consumption_15min',
    count(*),
    min(bucket_start),
    max(bucket_start)
FROM analytics.energy_consumption_15min

UNION ALL

SELECT
    'energy_consumption_hourly',
    count(*),
    min(bucket_start),
    max(bucket_start)
FROM analytics.energy_consumption_hourly

UNION ALL

SELECT
    'energy_consumption_daily',
    count(*),
    min(bucket_start),
    max(bucket_start)
FROM analytics.energy_consumption_daily;
"

section "14. ENVIRONMENT DATA"

psql_exec -c "
SELECT
    'environment_measurements' AS object,
    count(*) AS rows
FROM telemetry.environment_measurements

UNION ALL

SELECT
    'environment_daily',
    count(*)
FROM telemetry.environment_daily;
" || true

section "15. CAPTURE POLICY"

psql_exec -c "
SELECT *
FROM config.telemetry_capture_policies
ORDER BY site_id, effective_from DESC;
" || true

section "16. FUNCTIONS"

psql_exec -c "
SELECT
    n.nspname AS schema_name,
    p.proname AS routine_name,
    pg_get_function_identity_arguments(p.oid) AS arguments
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname IN
    ('analytics','telemetry','metadata','config')
ORDER BY n.nspname, p.proname;
"

section "17. GRAFANA-RELATED DATABASE OBJECTS"

psql_exec -c "
SELECT
    n.nspname AS schema_name,
    c.relname AS object_name,
    CASE c.relkind
        WHEN 'r' THEN 'table'
        WHEN 'v' THEN 'view'
        WHEN 'm' THEN 'materialized_view'
        ELSE c.relkind::text
    END AS object_type
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname ILIKE '%grafana%'
   OR c.relname ILIKE '%tenant%'
   OR c.relname ILIKE '%selector%'
   OR c.relname ILIKE '%dashboard%'
ORDER BY n.nspname, c.relname;
"

section "18. GRAFANA FUNCTIONS"

psql_exec -c "
SELECT
    n.nspname AS schema_name,
    p.proname AS routine_name,
    pg_get_function_identity_arguments(p.oid) AS arguments
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname ILIKE '%grafana%'
   OR p.proname ILIKE '%tenant%'
   OR p.proname ILIKE '%selector%'
ORDER BY n.nspname, p.proname;
"

section "19. GRAFANA REPOSITORY FILES"

find . \
    -not -path './.git/*' \
    -not -path './node_modules/*' \
    -type f \
    \( -iname '*grafana*' \
       -o -iname '*dashboard*.json' \
       -o -iname '*datasource*.yaml' \
       -o -iname '*datasource*.yml' \) \
    2>/dev/null | sort

section "20. GRAFANA RUNTIME"

curl -fsS http://localhost:3000/api/health || true

echo
echo "--- Dashboard inventory ---"
curl -fsS \
    'http://localhost:3000/api/search?type=dash-db' || true

section "21. MIGRATIONS"

echo "--- Migration ledger ---"

psql_exec -c "
SELECT count(*) AS migration_count,
       max(migration_id) AS highest_migration
FROM admin.schema_migrations;
"

echo
echo "--- Recent migration files ---"
find postgres/migrations -maxdepth 1 -type f \
    | sort | tail -50

echo
echo "--- Migration working-tree state ---"
git status --short -- postgres/migrations

section "22. TESTS / VERIFICATION"

find app/tests -type f 2>/dev/null | sort | tail -100 || true

echo
find scripts/verify -type f 2>/dev/null | sort | tail -100 || true

section "23. SNAPSHOT COMPLETE"

echo "Snapshot file:"
echo "$OUT"

echo
echo "Generated:"
date -Is

echo
echo "Git branch:"
git branch --show-current

echo
echo "Git HEAD:"
git rev-parse HEAD
