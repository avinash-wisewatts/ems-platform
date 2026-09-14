#!/usr/bin/env bash
#
# ============================================================================
# WiseWatts EMS — TimescaleDB Job Verification
#
# Purpose:
#   Verify that all declarative TimescaleDB automation required by the EMS
#   telemetry pipeline is registered, enabled, uniquely defined, and healthy.
#
# Scope:
#   - Normalization routing job
#   - Energy-domain routing job
#   - Environment-domain routing job
#   - MVP-7 alert evaluation job (ADR-016/ADR-017) -- registered by a
#     separate, explicitly authorized manual step, not deploy-automatic;
#     absence is reported here, not treated as a deployment regression
#   - Compression policies
#   - Retention policies
#   - Continuous aggregate refresh policies
#   - Recent background-job execution status
#
# Safety:
#   This script performs read-only database checks.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${PROJECT_ROOT}" || {
    echo "[FAIL] Unable to enter project directory: ${PROJECT_ROOT}"
    exit 1
}

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

print_header
print_section "TimescaleDB Background Jobs and Lifecycle Policies"


# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------

check_single_job() {
    local proc_name="$1"
    local display_name="$2"
    local proc_schema="${3:-telemetry}"
    local expect_overlap="${4:-true}"

    local job_count
    local scheduled_count
    local schedule_count
    local runtime_count
    local retry_count
    local overlap_count

    job_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}';
        "
    )"

    if [[ "${job_count}" == "1" ]]; then
        pass "${display_name} is registered exactly once"
    elif [[ "${job_count}" == "0" ]]; then
        fail "${display_name} is not registered"
        return
    else
        fail "${display_name} has duplicate registrations (${job_count})"
        return
    fi

    scheduled_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}'
              AND scheduled = TRUE;
        "
    )"

    if [[ "${scheduled_count}" == "1" ]]; then
        pass "${display_name} is enabled"
    else
        fail "${display_name} is disabled"
    fi

    schedule_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}'
              AND schedule_interval = INTERVAL '1 minute';
        "
    )"

    if [[ "${schedule_count}" == "1" ]]; then
        pass "${display_name} runs every 1 minute"
    else
        fail "${display_name} does not have the expected 1-minute schedule"
    fi

    runtime_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}'
              AND max_runtime = INTERVAL '5 minutes';
        "
    )"

    if [[ "${runtime_count}" == "1" ]]; then
        pass "${display_name} has a 5-minute maximum runtime"
    else
        warn "${display_name} does not have the expected 5-minute maximum runtime"
    fi

    retry_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}'
              AND max_retries = 3
              AND retry_period = INTERVAL '1 minute';
        "
    )"

    if [[ "${retry_count}" == "1" ]]; then
        pass "${display_name} retry policy is configured"
    else
        warn "${display_name} retry policy differs from the production standard"
    fi

    if [[ "${expect_overlap}" != "true" ]]; then
        return
    fi

    overlap_count="$(
        psql_query "
            SELECT COUNT(*)
            FROM timescaledb_information.jobs
            WHERE proc_schema = '${proc_schema}'
              AND proc_name = '${proc_name}'
              AND config ->> 'overlap' = '15 minutes';
        "
    )"

    if [[ "${overlap_count}" == "1" ]]; then
        pass "${display_name} uses the 15-minute late-data overlap"
    else
        fail "${display_name} does not use the expected 15-minute overlap"
    fi
}


check_procedure() {
    local procedure_signature="$1"
    local display_name="$2"
    local proc_schema="${3:-telemetry}"
    local procedure_exists

    procedure_exists="$(
        psql_query "
            SELECT COUNT(*)
            FROM pg_proc p
            JOIN pg_namespace n
              ON n.oid = p.pronamespace
            WHERE n.nspname = '${proc_schema}'
              AND p.oid = to_regprocedure('${procedure_signature}');
        "
    )"

    if [[ "${procedure_exists}" == "1" ]]; then
        pass "${display_name} procedure exists"
    else
        fail "${display_name} procedure is missing"
    fi
}


# ----------------------------------------------------------------------------
# 1. Required routing procedures
# ----------------------------------------------------------------------------

print_section "Required Routing Procedures"

check_procedure \
    "telemetry.run_normalization_job(integer,jsonb)" \
    "Normalization job"

check_procedure \
    "telemetry.run_energy_routing_job(integer,jsonb)" \
    "Energy routing job"

check_procedure \
    "telemetry.run_environment_routing_job(integer,jsonb)" \
    "Environment routing job"


# ----------------------------------------------------------------------------
# 2. Required routing-job registrations
# ----------------------------------------------------------------------------

print_section "Routing Job Registrations"

check_single_job \
    "run_normalization_job" \
    "Normalization job"

check_single_job \
    "run_energy_routing_job" \
    "Energy routing job"

check_single_job \
    "run_environment_routing_job" \
    "Environment routing job"


# ----------------------------------------------------------------------------
# 2b. MVP-7 alert evaluation job (ADR-016/ADR-017)
#
# Unlike the routing jobs above, this job has no "overlap" config (there is
# no late-data window concept for alert evaluation), so expect_overlap is
# passed as false. This job is registered by a separate, explicitly
# authorized manual step (postgres/jobs/238_alert_evaluation_job.sql;
# scripts/apply_migrations.sh does not read job-category files) -- its
# absence on a given deployment is expected and reported here, not a
# deployment regression by itself. See docs/07-features/alerts/README.md.
# ----------------------------------------------------------------------------

print_section "MVP-7 Alert Evaluation Job (ADR-016/ADR-017)"

check_procedure \
    "analytics.run_alert_evaluation_job(integer,jsonb)" \
    "Alert evaluation job" \
    "analytics"

check_single_job \
    "run_alert_evaluation_job" \
    "Alert evaluation job" \
    "analytics" \
    "false"


# ----------------------------------------------------------------------------
# 3. Duplicate custom-job detection
# ----------------------------------------------------------------------------

print_section "Duplicate Job Detection"

duplicate_custom_jobs="$(
    psql_query "
        SELECT COUNT(*)
        FROM
        (
            SELECT proc_schema, proc_name
            FROM timescaledb_information.jobs
            WHERE (
                proc_schema = 'telemetry'
                AND proc_name IN
                (
                    'run_normalization_job',
                    'run_energy_routing_job',
                    'run_environment_routing_job'
                )
            )
            OR (
                proc_schema = 'analytics'
                AND proc_name = 'run_alert_evaluation_job'
            )
            GROUP BY proc_schema, proc_name
            HAVING COUNT(*) > 1
        ) duplicate_jobs;
    "
)"

if [[ "${duplicate_custom_jobs}" == "0" ]]; then
    pass "No duplicate telemetry routing jobs exist"
else
    fail "${duplicate_custom_jobs} duplicate telemetry routing job definition(s) found"
fi


# ----------------------------------------------------------------------------
# 4. Lifecycle policy counts
#
# Expected minimums from the canonical SQL:
#
# Compression:
#   1 energy raw hypertable
#   3 energy continuous aggregates
#   1 environment raw hypertable
#   2 environment continuous aggregates
#   Total: 7
#
# Retention:
#   1 energy raw hypertable
#   2 energy continuous aggregates
#   1 environment raw hypertable
#   2 environment continuous aggregates
#   Total: 6
#
# Daily energy history intentionally has no retention policy.
# ----------------------------------------------------------------------------

print_section "Storage Lifecycle Policies"

compression_policy_count="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.jobs
        WHERE proc_schema = '_timescaledb_functions'
          AND proc_name = 'policy_compression';
    "
)"

if [[ "${compression_policy_count}" -ge 7 ]]; then
    pass "Compression policies are registered (${compression_policy_count})"
else
    fail "Expected at least 7 compression policies; found ${compression_policy_count}"
fi


retention_policy_count="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.jobs
        WHERE proc_schema = '_timescaledb_functions'
          AND proc_name = 'policy_retention';
    "
)"

if [[ "${retention_policy_count}" -ge 6 ]]; then
    pass "Retention policies are registered (${retention_policy_count})"
else
    fail "Expected at least 6 retention policies; found ${retention_policy_count}"
fi


refresh_policy_count="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.jobs
        WHERE proc_schema = '_timescaledb_functions'
          AND proc_name = 'policy_refresh_continuous_aggregate';
    "
)"

if [[ "${refresh_policy_count}" -gt 0 ]]; then
    pass "Continuous aggregate refresh policies are registered (${refresh_policy_count})"
else
    fail "No continuous aggregate refresh policies are registered"
fi


# ----------------------------------------------------------------------------
# 5. Disabled policy detection
# ----------------------------------------------------------------------------

print_section "Policy Scheduling State"

disabled_policy_count="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.jobs
        WHERE proc_schema = '_timescaledb_functions'
          AND proc_name IN
          (
              'policy_compression',
              'policy_retention',
              'policy_refresh_continuous_aggregate'
          )
          AND scheduled = FALSE;
    "
)"

if [[ "${disabled_policy_count}" == "0" ]]; then
    pass "All lifecycle and refresh policies are enabled"
else
    fail "${disabled_policy_count} lifecycle or refresh policy job(s) are disabled"
fi


# ----------------------------------------------------------------------------
# 6. Execution health
#
# A newly deployed job may not have run yet. That condition is a warning,
# not a failure. A recorded failed last run is treated as a failure.
# ----------------------------------------------------------------------------

print_section "Recent Job Execution Health"

failed_last_run_count="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.job_stats s
        JOIN timescaledb_information.jobs j
          ON j.job_id = s.job_id
        WHERE
        (
            j.proc_schema = 'telemetry'
            OR
            (
                j.proc_schema = '_timescaledb_functions'
                AND j.proc_name IN
                (
                    'policy_compression',
                    'policy_retention',
                    'policy_refresh_continuous_aggregate'
                )
            )
            OR
            (
                j.proc_schema = 'analytics'
                AND j.proc_name = 'run_alert_evaluation_job'
            )
        )
        AND LOWER(COALESCE(s.last_run_status, '')) = 'failed';
    "
)"

if [[ "${failed_last_run_count}" == "0" ]]; then
    pass "No managed TimescaleDB job has a failed last-run status"
else
    fail "${failed_last_run_count} managed TimescaleDB job(s) have a failed last-run status"
fi


never_run_custom_jobs="$(
    psql_query "
        SELECT COUNT(*)
        FROM timescaledb_information.jobs j
        LEFT JOIN timescaledb_information.job_stats s
          ON s.job_id = j.job_id
        WHERE
        (
            (
                j.proc_schema = 'telemetry'
                AND j.proc_name IN
                (
                    'run_normalization_job',
                    'run_energy_routing_job',
                    'run_environment_routing_job'
                )
            )
            OR
            (
                j.proc_schema = 'analytics'
                AND j.proc_name = 'run_alert_evaluation_job'
            )
        )
        AND s.last_run_started_at IS NULL;
    "
)"

if [[ "${never_run_custom_jobs}" == "0" ]]; then
    pass "All telemetry routing jobs and the alert evaluation job have executed at least once"
else
    warn "${never_run_custom_jobs} custom job(s) (telemetry routing and/or MVP-7 alert evaluation) have not executed yet"
fi


# ----------------------------------------------------------------------------
# 7. Human-readable job inventory
# ----------------------------------------------------------------------------

print_section "Registered Job Inventory"

psql_query "
    SELECT
        job_id,
        proc_schema || '.' || proc_name AS job_name,
        schedule_interval,
        scheduled,
        COALESCE(config::TEXT, '{}') AS config
    FROM timescaledb_information.jobs
    WHERE proc_schema = 'telemetry'
       OR
       (
           proc_schema = 'analytics'
           AND proc_name = 'run_alert_evaluation_job'
       )
       OR
       (
           proc_schema = '_timescaledb_functions'
           AND proc_name IN
           (
               'policy_compression',
               'policy_retention',
               'policy_refresh_continuous_aggregate'
           )
       )
    ORDER BY proc_schema, proc_name, job_id;
" | sed 's/^/  /'


summary
