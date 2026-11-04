"""EMS_WEB_UPSTREAM set (dedicated ems-web container, staging -- ADR-023):
admin-portal serves NO /app at all.

The EMS Web App is reached only on the customer host, through the edge proxy
(ems-web for /app, customer-api for /auth and /api/v1). admin-portal no longer
proxies /app to ems-web (that forwarding was removed) and does not fall back
to a bind-mounted bundle in this mode: /app and /app/* are a plain 404 for
everyone, before authentication, with no redirect to /login and no outbound
request. Its own /api/v1 and the Administration App pages are unchanged.

Settings are read once at import, so the app is imported in a fresh
interpreter (same pattern as test_reports_feature_flag.py).

(History: this file was test_web_upstream_proxy.py, which tested the removed
/app forwarding.)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

APP_DIR = Path(__file__).resolve().parents[1]

PROBE = r"""
import json
import socket
from fastapi.testclient import TestClient

# Any outbound connection attempt (e.g. to ems-web) would be recorded.
outbound = []
_real_connect = socket.socket.connect
def _record(self, address):
    outbound.append(str(address))
    return _real_connect(self, address)
socket.socket.connect = _record

import src.main as main
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

paths = {getattr(r, "path", None) for r in main.app.routes}
client = TestClient(main.app, follow_redirects=False)

def snap(response):
    return {
        "status": response.status_code,
        "headers": {k.lower(): v for k, v in response.headers.items()},
        "body": response.text,
    }

out = {
    "routes": {
        "app": "/app" in paths,
        "app_path": "/app/{spa_path:path}" in paths,
        "assets_mount": "/app/assets" in paths,
        "proxy_helper": hasattr(main, "_get_web_upstream_client"),
    },
}

APP_PATHS = ["/app", "/app/", "/app/home", "/app/admin/users", "/app/assets/index-abc.js", "/app/a/%2E%2E/b"]
out["anon"] = {p: snap(client.get(p)) for p in APP_PATHS}
out["anon_head"] = snap(client.head("/app/"))

user = AuthenticatedPortalUser(
    portal_user_id=7, username="staff@example.com", display_name="Staff",
    role_code="ADMIN", organization_id=None,
    access_scope_mode="GLOBAL", site_ids=(),
)
async def fake_authenticate(username, password, **kwargs):
    return AuthenticationResult(authenticated=True, user=user, status=AuthenticationStatus.AUTHENTICATED)
main.authenticate_portal_user = fake_authenticate
login = client.post("/login", data={"username": "staff@example.com", "password": "x", "next_path": "/app/"})
out["login_status"] = login.status_code
out["login_location"] = login.headers.get("location")

out["signed_in"] = {p: snap(client.get(p)) for p in APP_PATHS}
out["signed_in_post"] = snap(client.post("/app/home"))
out["api_me"] = snap(client.get("/api/v1/me"))
out["outbound"] = [a for a in outbound if "ems-web" in a]
print(json.dumps(out))
"""


@pytest.fixture(scope="module")
def probe() -> dict:
    env = dict(os.environ)
    env.pop("EMS_REPORTS_ENABLED", None)
    env["EMS_WEB_UPSTREAM"] = "http://ems-web:80/"
    env["PYTHONPATH"] = str(APP_DIR)
    result = subprocess.run(
        [sys.executable, "-c", PROBE], cwd=APP_DIR, env=env, capture_output=True, text=True, timeout=120
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_no_app_route_proxy_or_bundle_mount_is_registered(probe):
    assert probe["routes"] == {"app": False, "app_path": False, "assets_mount": False, "proxy_helper": False}


def _assert_removed(result):
    assert result["status"] == 404
    assert "location" not in result["headers"]
    assert result["headers"]["cache-control"] == "no-store"
    assert "customer host" in result["body"]


@pytest.mark.parametrize(
    "path", ["/app", "/app/", "/app/home", "/app/admin/users", "/app/assets/index-abc.js", "/app/a/%2E%2E/b"]
)
def test_signed_out_app_paths_are_404_without_a_login_redirect(probe, path):
    _assert_removed(probe["anon"][path])


@pytest.mark.parametrize("path", ["/app", "/app/", "/app/home", "/app/admin/users", "/app/assets/index-abc.js"])
def test_signed_in_staff_also_get_404_for_app(probe, path):
    _assert_removed(probe["signed_in"][path])


def test_head_and_post_to_app_are_404(probe):
    assert probe["anon_head"]["status"] == 404
    _assert_removed(probe["signed_in_post"])


def test_sign_in_never_returns_to_app(probe):
    assert probe["login_status"] == 303
    assert probe["login_location"] == "/administration/organizations"


def test_admin_portal_api_v1_is_unchanged(probe):
    assert probe["api_me"]["status"] == 200
    assert probe["api_me"]["headers"]["content-type"].startswith("application/json")


def test_nothing_is_requested_from_ems_web(probe):
    assert probe["outbound"] == []


@pytest.mark.parametrize("value", ["ftp://ems-web", "ems-web:80"])
def test_web_upstream_must_be_an_http_url(value):
    from pydantic import ValidationError

    from src.config import Settings

    with pytest.raises(ValidationError):
        Settings(EMS_WEB_UPSTREAM=value)


@pytest.mark.parametrize("value,expected", [("", None), ("  ", None), ("http://ems-web:80/", "http://ems-web:80")])
def test_web_upstream_blank_is_unset_and_trailing_slash_is_trimmed(value, expected):
    from src.config import Settings

    assert Settings(EMS_WEB_UPSTREAM=value).web_upstream == expected
