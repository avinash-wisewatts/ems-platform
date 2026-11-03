"""Staff user-administration console at /admin/* (ADR-023 Amendment 3).

With EMS_WEB_UPSTREAM set, src.main proxies /admin/* to the ems-web
container's staff bundle -- the route WiseWatts staff keep for Admin -> Users
once ADR-023 stage 4 removes /app and /api/v1 from the Administration App.
Access: PortalAuthenticationMiddleware requires user.manage (unauthenticated
-> /login), then the handler requires GLOBAL scope, so tenant administrators
and every non-administrator are refused before ems-web is contacted. Same
fresh-interpreter probe pattern as test_web_upstream_proxy.py.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from src.auth.authorization import PortalPermission, required_permission_for_request

APP_DIR = Path(__file__).resolve().parents[1]

PROBE = r'''
import json
import httpx
from fastapi.testclient import TestClient

import src.main as main
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

seen = []

def upstream(request):
    seen.append({"url": str(request.url), "headers": {k.lower(): v for k, v in request.headers.items()}})
    return httpx.Response(200, content=b"<!doctype html><div id=root></div>",
                          headers={"content-type": "text/html", "cache-control": "no-store"})

client_upstream = httpx.AsyncClient(transport=httpx.MockTransport(upstream))
main._get_web_upstream_client = lambda: client_upstream

ORG = "11111111-1111-4111-8111-111111111111"
USERS = {
    "staff_admin": AuthenticatedPortalUser(portal_user_id=1, username="staff_admin", display_name="Staff",
        role_code="ADMIN", organization_id=None, access_scope_mode="GLOBAL", site_ids=()),
    "tenant_admin": AuthenticatedPortalUser(portal_user_id=2, username="tenant_admin", display_name="Tenant",
        role_code="ADMIN", organization_id=ORG, access_scope_mode="ORGANIZATION", site_ids=()),
    "staff_operator": AuthenticatedPortalUser(portal_user_id=3, username="staff_operator", display_name="Op",
        role_code="OPERATOR", organization_id=None, access_scope_mode="GLOBAL", site_ids=()),
}

async def fake_authenticate(username, password):
    return AuthenticationResult(authenticated=True, user=USERS[username], status=AuthenticationStatus.AUTHENTICATED)
main.authenticate_portal_user = fake_authenticate

def call(client, method, path):
    before = len(seen)
    response = client.request(method, path)
    return {
        "status": response.status_code,
        "location": response.headers.get("location"),
        "cache_control": response.headers.get("cache-control"),
        "body": response.text,
        "upstream": seen[before:],
    }

PAGES = ("/admin", "/admin/users", "/admin/users/42", "/admin/assets/index-x.js")

out = {}
staff_routes = [r for r in main.app.routes if getattr(r, "path", "") in ("/admin", "/admin/{staff_path:path}")]
out["staff_route_count"] = len(staff_routes)
out["staff_routes_match_administration"] = [
    bool(r.path_regex.match(p)) for r in staff_routes
    for p in ("/administration", "/administration/organizations", "/adminx")
]
anon = TestClient(main.app, follow_redirects=False)
out["anon"] = {p: call(anon, "GET", p) for p in PAGES}
out["anon_me"] = call(anon, "GET", "/api/admin/v1/me")

for name in USERS:
    c = TestClient(main.app, follow_redirects=False)
    c.post("/login", data={"username": name, "password": "x", "next_path": "/admin/users"})
    out[name] = {p: call(c, "GET", p) for p in PAGES}
    out[name]["head"] = call(c, "HEAD", "/admin/users")
    out[name]["post"] = call(c, "POST", "/admin/users")
    out[name]["traversal"] = call(c, "GET", "/admin/a/%2E%2E/b")
    out[name]["me"] = call(c, "GET", "/api/admin/v1/me")
print(json.dumps(out))
'''


def _run(code: str, *, upstream: bool) -> str:
    env = dict(os.environ)
    env.pop("EMS_REPORTS_ENABLED", None)
    if upstream:
        env["EMS_WEB_UPSTREAM"] = "http://ems-web:80/"
    else:
        env.pop("EMS_WEB_UPSTREAM", None)
    env["PYTHONPATH"] = str(APP_DIR)
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=APP_DIR, env=env, capture_output=True, text=True, timeout=120
    )
    assert result.returncode == 0, result.stderr
    return result.stdout.strip().splitlines()[-1]


@pytest.fixture(scope="module")
def probe() -> dict:
    return json.loads(_run(PROBE, upstream=True))


def test_unauthenticated_visitors_get_the_login_redirect_and_never_reach_ems_web(probe):
    for path, result in probe["anon"].items():
        assert result["status"] == 303, path
        assert result["location"].startswith("/login?next_path="), path
        assert result["upstream"] == [], path
    assert probe["anon_me"]["status"] == 401


def test_staff_administrator_gets_the_staff_bundle(probe):
    staff = probe["staff_admin"]
    assert staff["/admin"]["status"] == 302
    assert staff["/admin"]["location"] == "/admin/users"
    assert staff["/admin"]["upstream"] == []
    for path in ("/admin/users", "/admin/users/42", "/admin/assets/index-x.js"):
        assert staff[path]["status"] == 200, path
        assert [u["url"] for u in staff[path]["upstream"]] == [f"http://ems-web{path}"], path
        sent = staff[path]["upstream"][0]["headers"]
        assert "cookie" not in sent and "authorization" not in sent
    assert staff["head"]["status"] == 200
    assert staff["head"]["body"] == ""


def test_tenant_administrators_are_refused_by_the_staff_route_before_ems_web(probe):
    for path in ("/admin", "/admin/users", "/admin/users/42", "/admin/assets/index-x.js"):
        result = probe["tenant_admin"][path]
        assert result["status"] == 403, path
        assert result["upstream"] == [], path


def test_non_administrators_get_the_existing_forbidden_page_before_ems_web(probe):
    # No user.manage: PortalAuthenticationMiddleware's standard HTML refusal.
    for path in ("/admin", "/admin/users", "/admin/users/42", "/admin/assets/index-x.js"):
        result = probe["staff_operator"][path]
        assert result["status"] == 303, path
        assert result["location"] == "/forbidden", path
        assert result["upstream"] == [], path


def test_tenant_administrator_refusal_is_explicit_and_not_cached(probe):
    result = probe["tenant_admin"]["/admin/users"]
    assert result["cache_control"] == "no-store"
    assert "staff administrators only" in result["body"]


def test_non_read_methods_and_dot_segments_never_reach_ems_web(probe):
    for name in ("staff_admin", "tenant_admin", "staff_operator"):
        assert probe[name]["post"]["upstream"] == []
        assert probe[name]["post"]["status"] in {303, 403, 405}
        assert probe[name]["traversal"]["upstream"] == []
        assert probe[name]["traversal"]["status"] in {303, 403, 404}


def test_administration_pages_are_not_captured_by_the_admin_route(probe):
    # /administration/* is the server-rendered Administration App, not the proxy.
    assert probe["staff_route_count"] == 2
    assert probe["staff_routes_match_administration"] == [False] * 6


def test_me_probe_reports_staff_status_and_requires_user_manage(probe):
    staff = probe["staff_admin"]["me"]
    assert staff["status"] == 200
    assert staff["cache_control"] == "no-store"
    body = json.loads(staff["body"])
    assert body["is_staff"] is True
    assert body["access_scope_mode"] == "GLOBAL"
    assert "user.manage" in body["permissions"]
    assert set(body) == {
        "portal_user_id",
        "username",
        "display_name",
        "role_code",
        "access_scope_mode",
        "organization_id",
        "is_staff",
        "permissions",
    }

    assert probe["tenant_admin"]["me"]["status"] == 200
    assert json.loads(probe["tenant_admin"]["me"]["body"])["is_staff"] is False

    assert probe["staff_operator"]["me"]["status"] == 403


@pytest.mark.parametrize(
    "path,expected",
    [
        ("/admin", PortalPermission.USER_MANAGE),
        ("/admin/", PortalPermission.USER_MANAGE),
        ("/admin/users", PortalPermission.USER_MANAGE),
        ("/admin/assets/x.js", PortalPermission.USER_MANAGE),
        ("/api/admin/v1/me", PortalPermission.USER_MANAGE),
        ("/administration/organizations", PortalPermission.DASHBOARD_VIEW),
        ("/adminx", PortalPermission.DASHBOARD_VIEW),
    ],
)
def test_admin_path_permissions(path, expected):
    assert required_permission_for_request("GET", path) == expected


def test_without_ems_web_upstream_no_admin_route_exists():
    code = (
        "import json, src.main as m; "
        "print(json.dumps(sorted(r.path for r in m.app.routes if getattr(r, 'path', '').startswith('/admin'))))"
    )
    paths = json.loads(_run(code, upstream=False))
    assert "/admin" not in paths
    assert "/admin/{staff_path:path}" not in paths
