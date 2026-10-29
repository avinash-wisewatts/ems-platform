"""Edge certificate check (ADR-023): the scheduled workflow and its scripts
stay a read-only, secret-free alert.

The workflow checks out the repository and runs
scripts/verify/check_edge_certificate.sh, which makes one TLS handshake to
the public endpoint; neither may reach the host (SSH), use a secret, or
change Caddy or its certificate storage. The alert scripts
(edge_certificate_alert.sh, edge_certificate_schedule_gap.sh) talk only to
the GitHub API through `gh` with the workflow's own token. The alert
contract: one open alert issue, updated on every failure with a throttled
reminder, closed only by a pass at the configured threshold.
"""

from __future__ import annotations

import os
import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "edge-certificate-check.yml"
SCRIPT = REPO / "scripts" / "verify" / "check_edge_certificate.sh"
ALERT = REPO / "scripts" / "verify" / "edge_certificate_alert.sh"
GAP = REPO / "scripts" / "verify" / "edge_certificate_schedule_gap.sh"

# Records every call; answers only what the scripts read back.
FAKE_GH = """#!/usr/bin/env bash
echo "$*" >> "${FAKE_GH_LOG}"
case "$1 $2" in
  "issue list") [[ -n "${FAKE_OPEN:-}" ]] && echo "${FAKE_OPEN}"; exit 0;;
  "issue create") echo "https://github.com/o/r/issues/99";;
  "issue view") echo "${FAKE_CREATED}";;
  "api repos/o/r/issues/"*) [[ -n "${FAKE_LAST_NOTICE:-}" ]] && echo "${FAKE_LAST_NOTICE}"; exit 0;;
  "api repos/o/r/actions/"*) [[ "${FAKE_API_FAIL:-}" == 1 ]] && { echo "HTTP 403"; exit 1; }
                            [[ -n "${FAKE_RUNS:-}" ]] && printf '%b\\n' "${FAKE_RUNS}"; exit 0;;
esac
exit 0
"""


def _code(path: Path) -> str:
    return "\n".join(line for line in path.read_text(encoding="utf-8").splitlines() if not line.lstrip().startswith("#"))


def _ago(hours: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")


def _run(tmp_path: Path, script: Path, *args: str, **fake: str) -> tuple[subprocess.CompletedProcess, list[str]]:
    gh = tmp_path / "gh"
    gh.write_text(FAKE_GH, encoding="utf-8")
    gh.chmod(0o755)
    log = tmp_path / "gh.log"
    log.write_text("", encoding="utf-8")
    env = {**os.environ, "PATH": f"{tmp_path}{os.pathsep}{os.environ['PATH']}", "GH_REPO": "o/r", "FAKE_GH_LOG": str(log), **fake}
    result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True, timeout=30, env=env)
    return result, log.read_text(encoding="utf-8").splitlines()


def test_workflow_is_scheduled_read_only_and_secret_free() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    # Two off-peak slots an hour: GitHub drops scheduled runs under load.
    assert '    - cron: "17,47 * * * *"' in text
    assert "workflow_dispatch:" in text
    assert re.search(r"^permissions:\n  contents: read\n  issues: write\n  actions: read\n", text, re.MULTILINE)
    assert "secrets." not in code and "ssh-action" not in code and "ssh " not in code
    assert "uses: " in code and all(
        line.strip() == "- uses: actions/checkout@v4" for line in code.splitlines() if "uses: " in line
    )
    assert './scripts/verify/check_edge_certificate.sh "${EDGE_HOST}" 443 "${MIN_HOURS}"' in text
    assert "CONFIGURED_MIN_HOURS: ${{ vars.EDGE_CERT_MIN_HOURS || '48' }}" in text
    assert "MIN_HOURS: ${{ inputs.min_hours || vars.EDGE_CERT_MIN_HOURS || '48' }}" in text
    assert 'resolve "${EDGE_HOST}" "${RUN_URL}" "${MIN_HOURS}" "${CONFIGURED_MIN_HOURS}"' in text
    # The token reaches only the alert/gap steps, never the check itself.
    job_env = text.split("    env:\n", 1)[1].split("    steps:\n", 1)[0]
    assert "GH_TOKEN" not in job_env
    assert text.count("GH_TOKEN: ${{ github.token }}") == 3


def test_script_only_handshakes() -> None:
    text = SCRIPT.read_text(encoding="utf-8")
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    assert "openssl s_client" in code and "-verify_return_error" in code
    for forbidden in ("ssh ", "docker ", "caddy ", "curl ", "wget ", "systemctl "):
        assert forbidden not in code, forbidden
    assert b"\r" not in SCRIPT.read_bytes()


def test_script_usage_errors_exit_2() -> None:
    for args in ([], ["host", "not-a-port"], ["host", "443", "soon"]):
        result = subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, timeout=30)
        assert result.returncode == 2, args


def test_alert_scripts_only_use_the_github_cli() -> None:
    for path in (ALERT, GAP):
        code = _code(path)
        for forbidden in ("ssh ", "docker ", "caddy ", "curl ", "wget ", "systemctl ", "openssl "):
            assert forbidden not in code, (path.name, forbidden)
        assert b"\r" not in path.read_bytes()


def test_raise_opens_one_assigned_issue_when_none_is_open(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, ALERT, "raise", "h", "https://run/1", "someone", FAKE_OPEN="")
    assert result.returncode == 0, result.stderr
    created = [c for c in calls if c.startswith("issue create")]
    assert len(created) == 1
    assert "--label edge-certificate-alert" in created[0] and "--assignee someone" in created[0]
    assert "@someone" in created[0]


def test_raise_updates_open_issue_and_throttles_the_reminder(tmp_path: Path) -> None:
    # Last notice 1 h ago: the description is updated, nobody is paged again.
    result, calls = _run(tmp_path, ALERT, "raise", "h", "https://run/2", "someone", FAKE_OPEN="7", FAKE_CREATED=_ago(1))
    assert result.returncode == 0, result.stderr
    assert any(c.startswith("issue edit 7") for c in calls)
    assert not any(c.startswith("issue comment") or c.startswith("issue create") for c in calls)

    # Issue 10 h old but the last reminder 2 h ago: still no new reminder.
    _, calls = _run(tmp_path, ALERT, "raise", "h", "https://run/3", "someone",
                    FAKE_OPEN="7", FAKE_CREATED=_ago(10), FAKE_LAST_NOTICE=_ago(2))
    assert not any(c.startswith("issue comment") for c in calls)

    # Last notice 7 h ago: updated and one reminder that mentions the recipient.
    _, calls = _run(tmp_path, ALERT, "raise", "h", "https://run/4", "someone", FAKE_OPEN="7", FAKE_CREATED=_ago(7))
    assert any(c.startswith("issue edit 7") for c in calls)
    reminders = [c for c in calls if c.startswith("issue comment 7")]
    assert len(reminders) == 1 and "@someone" in reminders[0]


def test_resolve_closes_only_at_the_configured_threshold(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, ALERT, "resolve", "h", "https://run/5", "24", "48", FAKE_OPEN="7")
    assert result.returncode == 0, result.stderr
    assert not any(c.startswith("issue close") or c.startswith("issue comment") for c in calls)

    result, calls = _run(tmp_path, ALERT, "resolve", "h", "https://run/6", "48", "48", FAKE_OPEN="7")
    assert result.returncode == 0, result.stderr
    assert any(c.startswith("issue close 7") for c in calls)

    result, calls = _run(tmp_path, ALERT, "resolve", "h", "https://run/7", "48", "48", FAKE_OPEN="")
    assert result.returncode == 0 and not any(c.startswith("issue close") for c in calls)

    result, _ = _run(tmp_path, ALERT, "resolve", "h", "https://run/8", FAKE_OPEN="7")
    assert result.returncode == 2


def test_schedule_gap_report_warns_but_never_fails(tmp_path: Path) -> None:
    result, _ = _run(tmp_path, GAP, "edge-certificate-check.yml", "222", "2", FAKE_RUNS=f"{_ago(0.5)}\\tschedule\\t111")
    assert result.returncode == 0 and "::warning" not in result.stdout

    result, _ = _run(tmp_path, GAP, "edge-certificate-check.yml", "222", "2", FAKE_RUNS=f"{_ago(5)}\\tschedule\\t111")
    assert result.returncode == 0 and "::warning title=Certificate check schedule gap::" in result.stdout

    result, _ = _run(tmp_path, GAP, "edge-certificate-check.yml", "222", "2", FAKE_API_FAIL="1")
    assert result.returncode == 0 and "::warning title=Schedule gap report unavailable::" in result.stdout
