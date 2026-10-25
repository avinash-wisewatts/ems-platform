"""Release workflows wire the migration environment scope safeguards.

- deploy-production.yml and rollback.yml require expected_migrations and run
  the pending-migration precheck (origin/staging's copy) BEFORE
  deploy_release.sh, so a refused precheck changes nothing.
- The production post-deploy verification runs with DEPLOY_ENVIRONMENT, which
  enables the REQUIRED "Staging-only Objects Absent" gate.
- deploy-production.yml never deploys the Web bundle (the Reports UI).
"""

from __future__ import annotations

from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"
PRECHECK = "git show origin/staging:scripts/release/precheck_release_migrations.sh"


@pytest.mark.parametrize("name", ["deploy-production.yml", "rollback.yml"])
def test_precheck_runs_before_deploy_release(name):
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    assert "expected_migrations:" in text and "required: true" in text.split("expected_migrations:", 1)[1][:600]
    assert "EXPECTED_MIGRATIONS: ${{ inputs.expected_migrations }}" in text
    assert PRECHECK in text
    assert text.index(PRECHECK) < text.index('scripts/release/deploy_release.sh"')
    assert '"+refs/heads/staging:refs/remotes/origin/staging"' in text


def test_rollback_precheck_runs_before_the_web_bundle_checkout():
    text = (WORKFLOWS / "rollback.yml").read_text(encoding="utf-8")
    assert text.index(PRECHECK) < text.index("deploy_web_bundle.sh")


def test_production_verification_enables_the_scope_gate():
    text = (WORKFLOWS / "deploy-production.yml").read_text(encoding="utf-8")
    assert "DEPLOY_ENVIRONMENT=production ./scripts/release/post_deploy_verify.sh" in text
    rollback = (WORKFLOWS / "rollback.yml").read_text(encoding="utf-8")
    assert 'DEPLOY_ENVIRONMENT="${ENVIRONMENT_NAME}" "${PROJECT_PATH}/scripts/release/post_deploy_verify.sh"' in rollback


def test_post_deploy_verify_runs_the_scope_gate_as_required():
    text = (REPO / "scripts" / "release" / "post_deploy_verify.sh").read_text(encoding="utf-8")
    block = text.split("REQUIRED: Staging-only Objects Absent", 1)[1].split("ADVISORY", 1)[0]
    assert 'verify_environment_scope.sh"; then' in block and "REQUIRED_FAILED=1" in block


def test_production_never_deploys_the_web_bundle():
    assert "deploy_web_bundle" not in (WORKFLOWS / "deploy-production.yml").read_text(encoding="utf-8")


def test_deploy_release_passes_the_environment_to_the_runner():
    text = (REPO / "scripts" / "release" / "deploy_release.sh").read_text(encoding="utf-8")
    assert 'DEPLOY_ENVIRONMENT="${ENVIRONMENT_NAME}"' in text.split("[4/6] Applying database migrations", 1)[1][:400]


def test_test_runner_applies_every_migration():
    assert 'DEPLOY_ENVIRONMENT="test"' in (REPO / "scripts" / "test" / "apply_test_migrations.sh").read_text(encoding="utf-8")
