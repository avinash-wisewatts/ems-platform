#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS -- edge certificate check: schedule-gap report (ADR-023)
#
# GitHub runs scheduled workflows on a best-effort basis and drops runs
# under load (observed 2026-10-28/29: 2 of 6 three-hourly slots ran). This
# step reports, from inside a run, how long ago the previous run of the
# same workflow started, and emits a warning annotation when that gap is
# larger than <max_gap_hours>.
#
# It is NOT a dead-man's switch: it runs on the same scheduler, so if the
# scheduler stops entirely nothing reports it. It makes dropped slots
# visible in the run history after the fact. It never fails the job.
#
#   edge_certificate_schedule_gap.sh <workflow_file> <run_id> <max_gap_hours>
#
# Needs GH_TOKEN (actions: read) and GH_REPO.
# ============================================================

set -uo pipefail

workflow="${1:-}"
run_id="${2:-}"
max_gap_hours="${3:-}"

if [[ -z "${workflow}" || ! "${run_id}" =~ ^[0-9]+$ || ! "${max_gap_hours}" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 <workflow_file> <run_id> <max_gap_hours>" >&2
    exit 0
fi

summary() {
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        echo "$1" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

runs="$(gh api "repos/${GH_REPO}/actions/workflows/${workflow}/runs?per_page=20" \
    --jq ".workflow_runs[] | select(.id != ${run_id}) | [.created_at, .event, .id] | @tsv" 2>&1)" || {
    echo "::warning title=Schedule gap report unavailable::could not list previous runs: ${runs}"
    exit 0
}
previous="$(head -1 <<< "${runs}")"
if [[ -z "${previous}" ]]; then
    echo "No previous run of ${workflow}; nothing to compare."
    exit 0
fi

IFS=$'\t' read -r prev_created prev_event prev_id <<< "${previous}"
gap_minutes=$(( ( $(date -u +%s) - $(date -u -d "${prev_created}" +%s) ) / 60 ))
gap_text="$(( gap_minutes / 60 )) h $(( gap_minutes % 60 )) min"
echo "Previous run ${prev_id} (${prev_event}) started ${prev_created}: ${gap_text} ago."

if (( gap_minutes > max_gap_hours * 60 )); then
    echo "::warning title=Certificate check schedule gap::previous run started ${gap_text} ago (${prev_created}, ${prev_event}); more than ${max_gap_hours} h -- GitHub skipped or delayed scheduled runs."
    summary "**Schedule gap** -- previous check started ${gap_text} ago (${prev_created}); more than ${max_gap_hours} h."
fi
exit 0
