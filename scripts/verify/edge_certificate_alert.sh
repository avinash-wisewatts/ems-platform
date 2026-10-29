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
#   edge_certificate_alert.sh resolve <host> <run_url>
#
# raise:   open the alert issue, or comment on (and re-mention in) the one
#          already open -- never more than one open alert.
# resolve: comment on and close the open alert issue, if any.
#
# Needs GH_TOKEN (the workflow's GITHUB_TOKEN, issues: write) and
# GH_REPO. Touches only issues and the label; no secrets in the output.
# ============================================================

set -euo pipefail

label="edge-certificate-alert"
action="${1:-}"
host="${2:-}"
run_url="${3:-}"

if [[ -z "${host}" || -z "${run_url}" ]] || [[ "${action}" != raise && "${action}" != resolve ]]; then
    echo "usage: $0 raise <host> <run_url> <recipient> [detail_file] | resolve <host> <run_url>" >&2
    exit 2
fi

open_issue="$(gh issue list --label "${label}" --state open --limit 1 --json number --jq '.[0].number // empty')"

if [[ "${action}" == resolve ]]; then
    if [[ -z "${open_issue}" ]]; then
        echo "No open ${label} issue; nothing to resolve."
        exit 0
    fi
    gh issue comment "${open_issue}" --body "Resolved: the certificate check for \`${host}\` passes again ([run](${run_url}))."
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

body="@${recipient} the staging customer endpoint certificate check failed.

\`\`\`
${detail}
\`\`\`

Run: ${run_url}

Recovery: docs/10-operations/customer-staff-separation-runbook.md, section 3b (steps 1-3 are read-only; forcing a renewal or restarting \`edge\` needs approval). This issue closes automatically when a scheduled check passes again."

if [[ -n "${open_issue}" ]]; then
    gh issue comment "${open_issue}" --body "Still failing. ${body}"
    echo "Commented on open alert issue #${open_issue} (recipient @${recipient})."
    exit 0
fi

gh label create "${label}" --color B60205 \
    --description "Staging customer endpoint certificate check failed" --force > /dev/null
url="$(gh issue create --title "Edge certificate check failed: ${host}" \
    --label "${label}" --assignee "${recipient}" --body "${body}")"
echo "Opened alert issue ${url} (assigned to @${recipient})."
