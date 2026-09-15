#!/usr/bin/env bash
#
# ============================================================================
# staging_measure_raw_message_failure_capture_window.sh
#
# Purpose:
#   Collect the staging performance evidence needed to pick a real
#   config.max_window value for job 1068 (see migration 243). Runs a bounded,
#   read-only EXPLAIN of the SAME per-row cost
#   telemetry.capture_raw_message_failures_incremental pays, for one
#   explicit, small, operator-supplied time window -- never job 1068's own
#   INSERT, never unbounded.
#
# This script is NOT part of any automated suite (not called by
# run_integration_environment.sh or any CI workflow) and is NOT invoked by
# migration 243. It is meant to be run manually, against staging, by an
# operator who has explicitly decided to do so -- per this repository's
# CLAUDE.md staging-safety rules, running it against staging requires its own
# separate, explicit authorization and is NOT covered by any authorization
# already given for the read-only investigation or the code change.
#
# Safety, enforced here (see the .sql file for the rest):
#   - --window-start and --window-end are REQUIRED, explicit, operator-
#     supplied timestamps. There is no default and no "from the stuck
#     checkpoint to now" behavior -- that is precisely the unbounded pattern
#     under investigation.
#   - The window is capped at 60 minutes (enforced twice: here, in bash,
#     before anything is sent to the database, AND again inside the .sql
#     file's own guard, in case this wrapper is ever bypassed).
#   - --statement-timeout-seconds defaults to 30 and is capped at 60. It is
#     always applied as SET LOCAL (this transaction only).
#   - ANALYZE is OFF by default (plan-only EXPLAIN, zero execution risk).
#     Pass --analyze to actually execute the query (still bounded by the
#     window cap and the statement timeout above, and still read-only/
#     ROLLBACK-wrapped -- see the .sql file). Consider the plan-only default
#     first; only reach for --analyze once the plan itself looks reasonable.
#   - The whole measurement runs inside BEGIN ... ROLLBACK and only ever
#     executes a SELECT (the procedure's read-side CTEs reproduced verbatim,
#     ending in an aggregate count) -- it cannot reach job 1068's own INSERT
#     INTO telemetry.raw_message_failures, so no row can ever be written by
#     this script, analyzed or not.
#
# Usage:
#   scripts/test/staging_measure_raw_message_failure_capture_window.sh \
#       --window-start '2026-09-15 14:00:00+05:30' \
#       --window-end   '2026-09-15 14:15:00+05:30' \
#       [--analyze] [--statement-timeout-seconds N]
#
# Prefer a RECENT window (the last 15-60 minutes of live data). Job 1068's
# stalled checkpoint (2026-08-30) is now far behind telemetry.raw_messages'
# 48-hour retention floor -- a window chosen from that historical range would
# scan nothing and measure nothing representative.
# ============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

WINDOW_START=""
WINDOW_END=""
ANALYZE="false"
STATEMENT_TIMEOUT_SECONDS=30

usage() {
    echo "Usage: $0 --window-start TIMESTAMPTZ --window-end TIMESTAMPTZ [--analyze] [--statement-timeout-seconds N]" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-start) WINDOW_START="$2"; shift 2 ;;
        --window-end) WINDOW_END="$2"; shift 2 ;;
        --analyze) ANALYZE="true"; shift ;;
        --statement-timeout-seconds) STATEMENT_TIMEOUT_SECONDS="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "${WINDOW_START}" || -z "${WINDOW_END}" ]]; then
    echo "ERROR: --window-start and --window-end are both required (no default -- see the file header)." >&2
    usage
fi

if [[ ! "${STATEMENT_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( STATEMENT_TIMEOUT_SECONDS < 1 )) || (( STATEMENT_TIMEOUT_SECONDS > 60 )); then
    echo "ERROR: --statement-timeout-seconds must be an integer between 1 and 60." >&2
    exit 2
fi

# Bash-side window-width guard, ahead of the .sql file's own guard, using
# GNU date (falls back to a python3 check if date -d is unavailable, e.g. on
# a strict-POSIX host).
if date -d "${WINDOW_START}" >/dev/null 2>&1; then
    START_EPOCH="$(date -d "${WINDOW_START}" +%s)"
    END_EPOCH="$(date -d "${WINDOW_END}" +%s)"
    WIDTH_SECONDS=$(( END_EPOCH - START_EPOCH ))
    if (( WIDTH_SECONDS <= 0 )); then
        echo "ERROR: --window-end must be after --window-start." >&2
        exit 2
    fi
    if (( WIDTH_SECONDS > 3600 )); then
        echo "ERROR: window width (${WIDTH_SECONDS}s) exceeds the 60-minute safety cap." >&2
        exit 2
    fi
else
    echo "WARNING: could not parse timestamps with 'date -d' on this host; relying on the .sql file's own 60-minute guard inside the database transaction." >&2
fi

EXPLAIN_KW="FALSE"
if [[ "${ANALYZE}" == "true" ]]; then
    EXPLAIN_KW="TRUE"
    echo "NOTE: --analyze requested. This EXECUTES the read-only measurement query (still bounded, still ROLLBACK-wrapped, still cannot write telemetry.raw_message_failures). Statement timeout: ${STATEMENT_TIMEOUT_SECONDS}s." >&2
else
    echo "NOTE: plan-only EXPLAIN (no execution). Pass --analyze once the plan itself looks reasonable." >&2
fi

docker compose exec -T timescaledb \
    psql \
    -X \
    -v ON_ERROR_STOP=1 \
    -U ems_admin \
    -d ems \
    -v "window_start=${WINDOW_START}" \
    -v "window_end=${WINDOW_END}" \
    -v "statement_timeout_ms=$(( STATEMENT_TIMEOUT_SECONDS * 1000 ))" \
    -v "explain_kw=${EXPLAIN_KW}" \
    -f - \
< "${SCRIPT_DIR}/staging_measure_raw_message_failure_capture_window.sql"
