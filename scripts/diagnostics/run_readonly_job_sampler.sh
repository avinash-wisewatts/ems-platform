#!/usr/bin/env bash
# ============================================================================
# Resilient runner for the P11 job-duration sampler (read-only).
#
# Runs scripts/diagnostics/prod_job_duration_sampler.sql on <ssh-host> through
# the same read-only path as the other diagnostics (docker exec psql with
# default_transaction_read_only=on, 30 s statement / 2 s lock timeouts), for a
# fixed wall-clock duration. If the SSH session drops, it reconnects and
# continues with only the samples still due, so the run never exceeds its end
# time. It never retries after a segment that did not report read-only.
#
# Usage:
#   run_readonly_job_sampler.sh <ssh-host> <output-dir> [duration-seconds]
#     ssh-host          an ~/.ssh/config alias (e.g. ems-staging, ems-production)
#     output-dir        local directory; created; must not already hold a run
#     duration-seconds  default 86400 (24 h)
# Stop early: create <output-dir>/STOP (takes effect at the next reconnect)
# or terminate this script (its ssh child ends with it).
#
# Output (local only; job timings, no tenant data):
#   samples.txt  '|'-separated sampler rows, appended per segment
#   runner.log   UTC-timestamped segment starts / ends / exit codes / checks
#   segments/    raw output of each segment (first line must be 'on')
# Production: run only with explicit authorization of the query and the run.
# ============================================================================
set -uo pipefail

HOST="${1:?ssh host alias required}"
OUT="${2:?output directory required}"
DURATION="${3:-86400}"
INTERVAL=30
MAX_RECONNECTS=48
SQL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/prod_job_duration_sampler.sql"

[[ -f "${SQL}" ]] || { echo "sampler SQL not found: ${SQL}" >&2; exit 2; }
grep -q '^\\watch i=30 c=2880$' "${SQL}" || { echo "unexpected \\watch line in ${SQL}" >&2; exit 2; }
[[ -e "${OUT}/samples.txt" ]] && { echo "${OUT} already holds a run" >&2; exit 2; }
mkdir -p "${OUT}/segments"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "${OUT}/runner.log"; }

END=$(( $(date -u +%s) + DURATION ))
log "start host=${HOST} duration=${DURATION}s end=$(date -u -d "@${END}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "${END}") sql_sha256=$(sha256sum "${SQL}" | cut -c1-16)"

attempt=0
while :; do
    [[ -e "${OUT}/STOP" ]] && { log "STOP file present; ending"; break; }
    remaining=$(( (END - $(date -u +%s)) / INTERVAL ))
    (( remaining > 0 )) || { log "duration reached; ending"; break; }
    attempt=$(( attempt + 1 ))
    (( attempt > MAX_RECONNECTS + 1 )) && { log "reconnect limit (${MAX_RECONNECTS}) reached; ending"; break; }

    seg="${OUT}/segments/segment-$(printf '%03d' "${attempt}").txt"
    log "segment ${attempt}: ${remaining} samples"
    sed "s/^\\\\watch i=30 c=2880$/\\\\watch i=${INTERVAL} c=${remaining}/" "${SQL}" \
      | ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=60 -o ServerAliveCountMax=5 "${HOST}" \
          'docker exec -i -e PGOPTIONS="-c default_transaction_read_only=on -c statement_timeout=30s -c lock_timeout=2s" ems-timescaledb sh -c "psql -X -q -A -F \"|\" -P pager=off -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\""' \
          > "${seg}" 2>> "${OUT}/runner.log"
    rc=$?

    first="$(head -n 1 "${seg}" 2>/dev/null | tr -d '\r')"
    if [[ -s "${seg}" && "${first}" != "on" ]]; then
        log "segment ${attempt}: read-only check FAILED (first line '${first}'); ending without retry"
        exit 3
    fi
    tail -n +2 "${seg}" | grep -v '^$' >> "${OUT}/samples.txt"
    log "segment ${attempt}: exit ${rc}, $(tail -n +2 "${seg}" | grep -c '|') rows"

    (( rc == 0 )) && { log "segment completed its samples; ending"; break; }
    sleep 60
done
touch "${OUT}/samples.txt"
log "done: $(grep -c '|' "${OUT}/samples.txt") rows total"
