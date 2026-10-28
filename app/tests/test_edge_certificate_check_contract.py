"""Edge certificate check (ADR-023): the scheduled workflow and its script
stay a read-only, secret-free alert.

The workflow only checks out the repository and runs
scripts/verify/check_edge_certificate.sh, which makes one TLS handshake to
the public endpoint; neither may reach the host (SSH), use a secret, or
change Caddy or its certificate storage.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
WORKFLOW = REPO / ".github" / "workflows" / "edge-certificate-check.yml"
SCRIPT = REPO / "scripts" / "verify" / "check_edge_certificate.sh"


def test_workflow_is_scheduled_read_only_and_secret_free() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    assert re.search(r'^\s+- cron: "[^"]+"$', text, re.MULTILINE)
    assert "workflow_dispatch:" in text
    assert re.search(r"^permissions:\n  contents: read\n", text, re.MULTILINE)
    assert "secrets." not in code and "ssh-action" not in code and "ssh " not in code
    assert './scripts/verify/check_edge_certificate.sh "${EDGE_HOST}" 443 "${MIN_HOURS}"' in text
    assert "MIN_HOURS: ${{ inputs.min_hours || '48' }}" in text


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
