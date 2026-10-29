#!/usr/bin/env bash
#
# ============================================================
# WiseWatts EMS -- edge certificate alert issue (ADR-023)
#
# Called by .github/workflows/edge-certificate-check.yml after the check.
# GitHub's own "workflow failed" e-mail depends on the recipient's personal
# notification settings and leaves no record that it was sent, so a failed
# check also raises an alert the repository can see and audit: one open
# issue labelled edge-certificate-alert, assigned to and @mentioning the
# recipient. github-actions[bot] is the author, so the assignment and the
# mention reach the recipient as "participating" notifications (web inbox
# and e-mail by default).
#
#   edge_certificate_alert.sh raise   <host> <run_url> <recipient> [detail_file]
#   edge_certificate_alert.sh resolve <host> <run_url> <run_min_hours> <configured_min_hours>
#
# raise:   open the alert issue, or update the one already open -- never
#          more than one open alert. Every failure rewrites the open issue's
#          body with the latest result (an edit: no new notification); a
#          comment that @mentions the recipient again is added only when the
#          last alert notice is at least ALERT_REMIND_HOURS old (default 6),
#          so a check that runs every 30 minutes does not page every run.
# resolve: comment on and close the open alert issue, if any -- only when
#          this run's threshold is at least the configured threshold, so a
#          manual run with a lowered min_hours cannot clear a real alert.
#
# Needs GH_TOKEN (the workflow's GITHUB_TOKEN, issues: write) and
# GH_REPO. Touches only issues and the label; no secrets in the output.
# ============================================================

set -euo pipefail

label="edge-certificate-alert"
reminder_marker="<!-- edge-certificate-alert:notice -->"
remind_hours="${ALERT_REMIND_HOURS:-6}"
action="${1:-}"
host="${2:-}"
run_url="${3:-}"

usage() {
    echo "usage: $0 raise <host> <run_url> <recipient> [detail_file]" >&2
    echo "       $0 resolve <host> <run_url> <run_min_hours> <configured_min_hours>" >&2
    exit 2
}

if [[ -z "${host}" || -z "${run_url}" ]] || [[ "${action}" != raise && "${action}" != resolve ]]; then
    usage
fi
[[ "${remind_hours}" =~ ^[0-9]+$ ]] || usage

open_issue="$(gh issue list --label "${label}" --state open --limit 1 --json number --jq '.[0].number // empty')"

if [[ "${action}" == resolve ]]; then
    run_min="${4:-}"
    configured_min="${5:-}"
    [[ "${run_min}" =~ ^[0-9]+$ && "${configured_min}" =~ ^[0-9]+$ ]] || usage
    if (( run_min < configured_min )); then
        echo "Passed at ${run_min} h, below the configured ${configured_min} h: an open alert is left as it is."
        exit 0
    fi
    if [[ -z "${open_issue}" ]]; then
        echo "No open ${label} issue; nothing to resolve."
        exit 0
    fi
    gh issue comment "${open_issue}" --body "Resolved: the certificate check for \`${host}\` passes again with at least ${run_min} h of validity ([run](${run_url}))."
    gh issue close "${open_issue}" --reason completed
    echo "Closed alert issue #${open_issue}."
    exit 0
fi

recipient="${4:-}"
detail_file="${5:-}"
if [[ ! "${recipient}" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "invalid recipient login: '${recipient}'" >&2
    exit 2
fi

detail="(no check output captured)"
if [[ -n "${detail_file}" && -s "${detail_file}" ]]; then
    detail="$(grep -E '^\[(PASS|FAIL)\]|issuer:|not after:|verify error|refused|timed out' "${detail_file}" | head -10 || true)"
fi
now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

body="@${recipient} the staging customer endpoint certificate check is failing.

Latest failing check: ${now} ([run](${run_url}))

\`\`\`
${detail}
\`\`\`

Recovery: docs/10-operations/customer-staff-separation-runbook.md, section 3b (steps 1-3 are read-only; forcing a renewal or restarting \`edge\` needs approval). Every failing check updates this text; a reminder comment follows at most every ${remind_hours} h. This issue closes automatically when a check passes at the configured threshold."

if [[ -z "${open_issue}" ]]; then
    gh label create "${label}" --color B60205 \
        --description "Staging customer endpoint certificate check failed" --force > /dev/null
    url="$(gh issue create --title "Edge certificate check failed: ${host}" \
        --label "${label}" --assignee "${recipient}" --body "${body}")"
    echo "Opened alert issue ${url} (assigned to @${recipient})."
    exit 0
fi

gh issue edit "${open_issue}" --body "${body}" > /dev/null
echo "Updated alert issue #${open_issue} with the latest result."

# Time of the last notice: the newest reminder comment, else the issue itself.
last_notice="$(gh api "repos/${GH_REPO}/issues/${open_issue}/comments?per_page=100" --paginate \
    --jq "[.[] | select(.body | contains(\"${reminder_marker}\")) | .created_at] | last // empty" | tail -1)"
if [[ -z "${last_notice}" ]]; then
    last_notice="$(gh issue view "${open_issue}" --json createdAt --jq '.createdAt')"
fi
age_hours=$(( ( $(date -u +%s) - $(date -u -d "${last_notice}" +%s) ) / 3600 ))

if (( age_hours < remind_hours )); then
    echo "Last notice ${last_notice} (${age_hours} h ago, under ${remind_hours} h): no reminder."
    exit 0
fi
gh issue comment "${open_issue}" --body "${reminder_marker}
Still failing (${now}). @${recipient} -- latest result is in the issue description ([run](${run_url}))."
echo "Reminder posted on alert issue #${open_issue} (last notice ${age_hours} h ago)."
