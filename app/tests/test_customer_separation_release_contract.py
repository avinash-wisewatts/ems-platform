"""Release contract for the customer/staff separation (ADR-023).

- compose.yaml: customer-api and edge are profile-gated (never started by a
  bare `up` or by deploy_release.sh), so the default service set -- and every
  host that has not activated them, production included -- is unchanged.
  customer-api has no host port and only its own env file (no app/.env, no
  administration or Grafana secrets); edge is digest-pinned and its staff
  host defaults to nobody.
- edge/Caddyfile: the customer host routes only the customer paths and
  answers everything else 404; admin-portal is reachable only on the
  IP-restricted staff host.
- scripts/release/deploy_customer_api.sh recreates only customer-api.
- Production workflows deploy none of it.
"""

from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO / ".github" / "workflows"
DEPLOY = REPO / "scripts" / "release" / "deploy_customer_api.sh"


def _services() -> dict:
    return yaml.safe_load((REPO / "compose.yaml").read_text(encoding="utf-8"))["services"]


def _code(path: Path) -> str:
    return "\n".join(l for l in path.read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("#"))


def _caddyfile() -> str:
    return (REPO / "edge" / "Caddyfile").read_text(encoding="utf-8")


def _site_block(host_var: str) -> str:
    CADDYFILE = _caddyfile()
    start = CADDYFILE.index("{$" + host_var + "} {")
    depth, i = 0, CADDYFILE.index("{", start + len(host_var) + 3)
    for j in range(i, len(CADDYFILE)):
        depth += {"{": 1, "}": -1}.get(CADDYFILE[j], 0)
        if depth == 0:
            return CADDYFILE[i:j]
    raise AssertionError("unterminated block")


def test_default_service_set_is_unchanged() -> None:
    unprofiled = {name for name, s in _services().items() if "profiles" not in s}
    assert unprofiled == {"timescaledb", "telegraf", "grafana", "live-telemetry", "admin-portal", "ems-web"}


def test_customer_api_is_internal_profile_gated_and_admin_secret_free() -> None:
    s = _services()["customer-api"]
    assert s["profiles"] == ["customer"]
    assert "ports" not in s and "environment" not in s
    assert s["env_file"] == [{"path": "./app/customer-api.env", "required": False}]
    assert s["image"].startswith("${EMS_CUSTOMER_API_IMAGE")
    assert s["command"][:2] == ["uvicorn", "src.customer_main:app"]
    assert set(s["depends_on"]) == {"timescaledb"}
    assert s["read_only"] is True and s["container_name"] == "ems-customer-api"


def test_customer_env_example_has_only_customer_configuration() -> None:
    text = (REPO / "app" / "customer-api.env.example").read_text(encoding="utf-8")
    keys = {l.split("=", 1)[0] for l in text.splitlines() if l and not l.startswith("#") and "=" in l}
    assert "EMS_APP_DB_USER" in keys and "EMS_APP_DB_USER=ems_customer_api" in text
    assert not any(k.startswith(("EMS_GRAFANA", "MQTT", "EMS_WEB_UPSTREAM", "EMS_ADMIN")) for k in keys), keys
    assert "EMS_APP_SESSION_COOKIE_NAME=ems_session" in text


def test_edge_is_profile_gated_pinned_and_staff_host_defaults_to_nobody() -> None:
    s = _services()["edge"]
    assert s["profiles"] == ["edge"]
    assert re.fullmatch(r"caddy:[0-9.]+-alpine@sha256:[0-9a-f]{64}", s["image"])
    assert "./edge/Caddyfile:/etc/caddy/Caddyfile:ro" in s["volumes"]
    assert "env_file" not in s
    assert s["environment"]["EMS_STAFF_ALLOWED_CIDRS"] == "${EMS_STAFF_ALLOWED_CIDRS:-127.0.0.1/32}"
    assert s["environment"]["EMS_EDGE_TLS"] == "${EMS_EDGE_TLS:-internal}"


def test_customer_host_routes_only_customer_paths() -> None:
    block = _site_block("EMS_CUSTOMER_HOST")
    upstreams = set(re.findall(r"reverse_proxy\s+(\S+)", block))
    assert upstreams == {"customer-api:8070", "live-telemetry:8090", "ems-web:80"}
    assert "admin-portal" not in block and "grafana" not in block
    assert "@customer_api path /api/v1/* /auth/*" in block
    # `redir /app/ 302` would parse /app/ as a matcher and leave / unanswered.
    assert "redir * /app/ 302" in block
    assert block.rstrip().endswith("handle {\n\t\trespond 404\n\t}")


def test_staff_host_is_ip_restricted_and_the_only_way_to_admin_portal() -> None:
    block = _site_block("EMS_STAFF_HOST")
    assert "@not_staff not remote_ip {$EMS_STAFF_ALLOWED_CIDRS:127.0.0.1/32}" in block
    assert "respond @not_staff 403" in block
    assert block.index("respond @not_staff 403") < block.index("reverse_proxy admin-portal:8080")
    assert len(re.findall(r"reverse_proxy\s+admin-portal", _caddyfile())) == 1


def test_deploy_release_still_names_only_admin_portal_and_live_telemetry() -> None:
    text = (REPO / "scripts" / "release" / "deploy_release.sh").read_text(encoding="utf-8")
    assert 'APP_SERVICES="${APP_SERVICES:-admin-portal live-telemetry}"' in text
    assert "customer-api" not in _code(REPO / "scripts" / "release" / "deploy_release.sh")
    assert "--profile" not in text


def test_deploy_customer_api_only_ever_recreates_customer_api() -> None:
    code = _code(DEPLOY)
    calls = [l for l in code.splitlines() if re.search(r"\bcompose (up|down|restart|stop|start|rm|run|create)\b", l)]
    assert calls
    for line in calls:
        assert 'up -d --no-build --no-deps "${SERVICE}"' in line, line
    assert 'SERVICE="customer-api"' in code
    for other in ("admin-portal", "live-telemetry", "ems-web", "timescaledb", "telegraf", "grafana", "edge"):
        assert other not in code, other
    for forbidden in ("apply_migrations", "deploy_release", "git checkout", "git fetch", "psql"):
        assert forbidden not in code, forbidden
    assert b"\r\n" not in DEPLOY.read_bytes()


def test_production_workflows_deploy_none_of_it() -> None:
    for name in ("deploy-production.yml", "rollback.yml"):
        text = (WORKFLOWS / name).read_text(encoding="utf-8")
        for forbidden in ("customer-api", "customer_api", "deploy_customer_api", "--profile", "Caddyfile"):
            assert forbidden not in text, (name, forbidden)
        assert not re.search(r"edge", text), name


def test_deploy_customer_api_workflow_is_customer_api_only_staging_only_and_digest_pinned() -> None:
    text = (WORKFLOWS / "deploy-customer-api.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(text)
    on = workflow.get("on", workflow.get(True))
    assert on["workflow_dispatch"]["inputs"]["target_environment"]["options"] == ["staging"]
    assert '"${PROJECT_PATH}/scripts/release/deploy_customer_api.sh"' in text
    assert "@${digest}" in text and "imagetools inspect" in text and "-app" in text
    for forbidden in ("deploy_release", "apply_migrations", "deploy_web", "git checkout", "PRODUCTION_", "--profile edge"):
        assert forbidden not in text, forbidden
