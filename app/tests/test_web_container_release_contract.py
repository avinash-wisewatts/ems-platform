"""Release contract for the dedicated EMS Web App container (`ems-web`).

- compose.yaml: ems-web publishes no host port, holds no env file/secrets,
  and is not a dependency of admin-portal (each can be recreated without the
  other); admin-portal's EMS_WEB_UPSTREAM switch defaults to empty (the
  bind-mounted bundle fallback) and the fallback mount is kept.
- scripts/release/deploy_web.sh recreates ONLY ems-web: every compose call
  names it with --no-deps --no-build, and it never touches another service,
  migrations, git or a .env file.
- deploy-web.yml is a genuinely web-only path: staging-only, digest-pinned,
  never runs deploy_release.sh / migrations / a checkout.
- deploy-staging.yml deploys ems-web by digest before deploy_release.sh and
  keeps the bundle placement (the fallback).
- Production never deploys the web container (production release plan D6).
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"
DEPLOY_WEB_SH = REPO / "scripts" / "release" / "deploy_web.sh"
OTHER_SERVICES = ("admin-portal", "live-telemetry", "timescaledb", "telegraf", "grafana")


def _compose() -> dict:
    return yaml.safe_load((REPO / "compose.yaml").read_text(encoding="utf-8"))


def _code_lines(path: Path) -> list[str]:
    return [
        line for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_ems_web_service_is_internal_only_and_secret_free():
    service = _compose()["services"]["ems-web"]
    assert "ports" not in service
    assert "env_file" not in service and "environment" not in service
    assert service["container_name"] == "ems-web"
    assert service["image"].startswith("${EMS_WEB_IMAGE")
    assert service["build"]["context"] == "./web"
    assert service["restart"] == "unless-stopped"
    assert "healthcheck" in service
    assert service.get("read_only") is True


def test_admin_portal_and_ems_web_do_not_depend_on_each_other():
    services = _compose()["services"]
    assert "ems-web" not in services["admin-portal"].get("depends_on", {})
    assert "depends_on" not in services["ems-web"]


def test_admin_portal_upstream_switch_defaults_off_and_keeps_the_bundle_fallback():
    admin = _compose()["services"]["admin-portal"]
    assert admin["environment"]["EMS_WEB_UPSTREAM"] == "${EMS_WEB_UPSTREAM:-}"
    assert "${EMS_WEB_SPA_PATH:-./web-spa}:/app/src/spa:ro" in admin["volumes"]


def test_deploy_web_script_only_ever_recreates_ems_web():
    lines = _code_lines(DEPLOY_WEB_SH)
    text = "\n".join(lines)

    compose_calls = [line for line in lines if re.search(r"\bcompose (up|down|restart|stop|start|rm|pull|run|create)\b", line)]
    assert compose_calls, "deploy_web.sh must deploy via compose"
    for line in compose_calls:
        assert 'up -d --no-build --no-deps "${SERVICE}"' in line, line
    assert 'SERVICE="ems-web"' in text

    for name in OTHER_SERVICES:
        assert name not in text, f"deploy_web.sh must not reference {name}"
    for forbidden in ("apply_migrations", "deploy_release", "git checkout", "git fetch", "psql", ".env"):
        assert forbidden not in text, f"deploy_web.sh must not use {forbidden}"


def test_deploy_web_script_verifies_provenance_and_restores_on_unhealthy():
    text = DEPLOY_WEB_SH.read_text(encoding="utf-8")
    assert "org.opencontainers.image.revision" in text
    assert "health_check.sh" in text
    assert 'EMS_WEB_IMAGE="${previous_image}" compose up -d --no-build --no-deps "${SERVICE}"' in text
    assert DEPLOY_WEB_SH.read_bytes().count(b"\r\n") == 0


def test_deploy_web_workflow_is_web_only_staging_only_and_digest_pinned():
    text = (WORKFLOWS / "deploy-web.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(text)
    on = workflow.get("on", workflow.get(True))
    target = on["workflow_dispatch"]["inputs"]["target_environment"]
    assert target["options"] == ["staging"]

    assert "scripts/release/deploy_web.sh" in text
    assert "@${digest}" in text and "imagetools inspect" in text
    for forbidden in ("deploy_release", "apply_migrations", "deploy_web_bundle", "git checkout", "PRODUCTION_"):
        assert forbidden not in text, f"deploy-web.yml must not use {forbidden}"


def test_staging_pipeline_runs_ems_web_by_digest_before_the_release_and_keeps_the_bundle():
    text = (WORKFLOWS / "deploy-staging.yml").read_text(encoding="utf-8")
    assert '--build-arg GIT_SHA="${{ github.sha }}"' in text
    assert 'EMS_WEB_IMAGE="${WEB_IMAGE}@${WEB_DIGEST}"' in text
    bundle = text.index('"${PROJECT_PATH}/scripts/release/deploy_web_bundle.sh"')
    container = text.index('"${PROJECT_PATH}/scripts/release/deploy_web.sh"')
    release = text.index('"${PROJECT_PATH}/scripts/release/deploy_release.sh"')
    assert bundle < container < release


def test_production_never_deploys_the_web_container():
    text = (WORKFLOWS / "deploy-production.yml").read_text(encoding="utf-8")
    for forbidden in ("deploy_web", "EMS_WEB_IMAGE", "ems-web", "EMS_WEB_UPSTREAM"):
        assert forbidden not in text
    assert "deploy_web.sh" not in (WORKFLOWS / "rollback.yml").read_text(encoding="utf-8")


def test_web_image_carries_its_source_revision():
    dockerfile = (REPO / "web" / "Dockerfile").read_text(encoding="utf-8")
    assert "ARG GIT_SHA" in dockerfile
    assert 'org.opencontainers.image.revision="${GIT_SHA}"' in dockerfile
    nginx = (REPO / "web" / "nginx.conf").read_text(encoding="utf-8")
    assert "absolute_redirect off;" in nginx
