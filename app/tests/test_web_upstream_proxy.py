"""EMS_WEB_UPSTREAM -- /app/* proxied to the dedicated ems-web container.

With EMS_WEB_UPSTREAM set, src.main serves /app/* by proxying to the ems-web
container (web/Dockerfile's nginx image) instead of from the bind-mounted
bundle. The proxy sits behind the unchanged PortalAuthenticationMiddleware:
unauthenticated visitors still get the /login redirect and never reach the
upstream, only GET/HEAD are forwarded, and no cookie or credential is sent
upstream. Settings are read once at import, so the app is imported in a fresh
interpreter (same pattern as test_reports_feature_flag.py); the upstream is an
httpx.MockTransport that records every request it receives.
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
import httpx
from fastapi.testclient import TestClient

import src.main as main
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

seen = []

def upstream(request):
    seen.append({
        "method": request.method,
        "url": str(request.url),
        "headers": {k.lower(): v for k, v in request.headers.items()},
    })
    path = request.url.path
    if path == "/app/boom":
        raise httpx.ConnectError("ems-web unreachable", request=request)
    if path == "/app/assets/index-abc.js":
        return httpx.Response(
            200,
            content=b"console.log(1);",
            headers={
                "content-type": "application/javascript",
                "cache-control": "public, max-age=31536000, immutable",
                "etag": '"abc"',
                "set-cookie": "upstream=1",
                "server": "nginx",
            },
        )
    if path.startswith("/app/assets/"):
        return httpx.Response(404, content=b"not found", headers={"content-type": "text/html"})
    if path == "/app/moved":
        return httpx.Response(301, headers={"location": "/app/moved/"})
    if path == "/app/offsite":
        return httpx.Response(302, headers={"location": "http://ems-web/app/"})
    return httpx.Response(
        200,
        content=b"<!doctype html><div id=root></div>",
        headers={"content-type": "text/html", "cache-control": "no-store"},
    )

client_upstream = httpx.AsyncClient(transport=httpx.MockTransport(upstream))
main._get_web_upstream_client = lambda: client_upstream

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
    },
}

# --- unauthenticated: the existing middleware answers, upstream never called
out["anon_app"] = snap(client.get("/app/home"))
out["anon_asset"] = snap(client.get("/app/assets/index-abc.js"))
out["anon_upstream_calls"] = len(seen)

# --- authenticate through the real /login route with a faked credential check
user = AuthenticatedPortalUser(
    portal_user_id=7, username="web@example.com", display_name="Web",
    role_code="VIEWER", organization_id="11111111-1111-4111-8111-111111111111",
    access_scope_mode="ORGANIZATION", site_ids=(),
)
async def fake_authenticate(username, password):
    return AuthenticationResult(authenticated=True, user=user, status=AuthenticationStatus.AUTHENTICATED)
main.authenticate_portal_user = fake_authenticate
login = client.post("/login", data={"username": "web@example.com", "password": "x", "next_path": "/app/"})
out["login_status"] = login.status_code
out["login_location"] = login.headers.get("location")

def call(method, path, **kw):
    before = len(seen)
    response = client.request(method, path, **kw)
    result = snap(response)
    result["upstream"] = seen[before:]
    return result

out["app"] = call("GET", "/app")
out["app_slash"] = call("GET", "/app/")
out["route"] = call("GET", "/app/features/energy?site=1")
out["asset"] = call(
    "GET", "/app/assets/index-abc.js",
    headers={"If-None-Match": '"old"', "Authorization": "Bearer nope", "X-Forwarded-For": "1.2.3.4"},
)
out["asset_head"] = call("HEAD", "/app/assets/index-abc.js")
out["missing_asset"] = call("GET", "/app/assets/missing.js")
out["moved"] = call("GET", "/app/moved")
out["offsite"] = call("GET", "/app/offsite")
out["down"] = call("GET", "/app/boom")
out["traversal"] = call("GET", "/app/a/%2E%2E/b")
out["post"] = call("POST", "/app/home")
out["api_me"] = snap(client.get("/api/v1/me"))
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


def test_upstream_mode_registers_the_proxy_and_not_the_bundle_mount(probe):
    assert probe["routes"] == {"app": True, "app_path": True, "assets_mount": False}


def test_unauthenticated_requests_use_the_existing_login_redirect_and_never_reach_ems_web(probe):
    for key, target in (("anon_app", "%2Fapp%2Fhome"), ("anon_asset", "%2Fapp%2Fassets%2Findex-abc.js")):
        assert probe[key]["status"] == 303
        assert probe[key]["headers"]["location"] == f"/login?next_path={target}"
    assert probe["anon_upstream_calls"] == 0


def test_login_returns_to_app(probe):
    assert probe["login_status"] == 303
    assert probe["login_location"] == "/app/"


@pytest.mark.parametrize(
    "key,upstream_url",
    [
        # httpx normalises away the default :80 of EMS_WEB_UPSTREAM.
        ("app", "http://ems-web/app"),
        ("app_slash", "http://ems-web/app/"),
        ("route", "http://ems-web/app/features/energy?site=1"),
    ],
)
def test_spa_paths_are_forwarded_verbatim_and_return_the_entry_document(probe, key, upstream_url):
    result = probe[key]
    assert result["status"] == 200
    assert result["body"].startswith("<!doctype html>")
    assert result["headers"]["cache-control"] == "no-store"
    assert [call["url"] for call in result["upstream"]] == [upstream_url]
    assert result["upstream"][0]["method"] == "GET"


def test_hashed_asset_keeps_cache_headers_and_drops_upstream_cookies_and_server(probe):
    result = probe["asset"]
    assert result["status"] == 200
    assert result["body"] == "console.log(1);"
    assert result["headers"]["content-type"].startswith("application/javascript")
    assert result["headers"]["cache-control"] == "public, max-age=31536000, immutable"
    assert result["headers"]["etag"] == '"abc"'
    # The only Set-Cookie is the portal's own session refresh
    # (SessionMiddleware), never the upstream's.
    assert "upstream=1" not in result["headers"].get("set-cookie", "")
    assert result["headers"].get("server") != "nginx"


def test_no_session_cookie_or_credential_is_forwarded_upstream(probe):
    sent = probe["asset"]["upstream"][0]["headers"]
    assert "cookie" not in sent
    assert "authorization" not in sent
    assert "x-forwarded-for" not in sent
    assert sent["if-none-match"] == '"old"'


def test_head_is_forwarded_without_a_body(probe):
    result = probe["asset_head"]
    assert result["status"] == 200
    assert result["body"] == ""
    assert [call["method"] for call in result["upstream"]] == ["HEAD"]


def test_upstream_status_is_preserved_for_a_missing_asset(probe):
    assert probe["missing_asset"]["status"] == 404


def test_only_same_origin_relative_redirects_are_passed_through(probe):
    assert probe["moved"]["status"] == 301
    assert probe["moved"]["headers"]["location"] == "/app/moved/"
    assert "location" not in probe["offsite"]["headers"]


def test_unreachable_ems_web_is_a_502_not_a_crash(probe):
    assert probe["down"]["status"] == 502
    assert probe["down"]["headers"]["cache-control"] == "no-store"


def test_dot_segments_are_rejected_before_any_upstream_call(probe):
    assert probe["traversal"]["status"] == 404
    assert probe["traversal"]["upstream"] == []


def test_non_read_methods_are_not_forwarded(probe):
    assert probe["post"]["status"] in {303, 403, 405}
    assert probe["post"]["upstream"] == []


def test_api_v1_is_not_proxied(probe):
    assert probe["api_me"]["status"] == 200
    assert probe["api_me"]["headers"]["content-type"].startswith("application/json")


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
