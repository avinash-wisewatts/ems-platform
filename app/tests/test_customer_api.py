"""Customer API (src.customer_main, ADR-023): isolation from the
Administration App, customer authentication and session handling, CSRF
(same-origin) protection, the staff/customer audience, and /api/v1 parity
with the admin portal.

Both apps share the /api/v1 router module, so one fake at
src.routers.analytics_api.<name> serves both and the responses must be
identical. Data access is faked here; tenant isolation through the real
database functions and the least-privilege role is covered by
test_customer_api_role_db.py.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

APP_DIR = Path(__file__).resolve().parents[1]
ORIGIN = {"Origin": "http://testserver"}
ORG_ID = "11111111-1111-4111-8111-111111111111"
SITE_ID = "22222222-2222-4222-8222-222222222222"
ALERT_ID = "33333333-3333-4333-8333-333333333333"

CUSTOMER = AuthenticatedPortalUser(
    portal_user_id=701, username="viewer@customer.example", display_name="Customer Viewer",
    role_code="VIEWER", organization_id=ORG_ID, access_scope_mode="ORGANIZATION",
)
STAFF = AuthenticatedPortalUser(
    portal_user_id=702, username="staff@wisewatts.example", display_name="WiseWatts Staff",
    role_code="ADMIN", access_scope_mode="GLOBAL",
)


@pytest.fixture
def customer_module():
    import src.config as config
    import src.customer_main as customer_main

    config.use_core_settings(customer_main.settings)
    try:
        yield customer_main
    finally:
        config._core_settings = None


@pytest.fixture
def customer_client(customer_module):
    return TestClient(customer_module.app, follow_redirects=False)


def _fake_authenticate(monkeypatch, target: str, user: AuthenticatedPortalUser | None) -> None:
    """Fake credential check that honours the audience argument like the real one."""

    async def fake(username: str, password: str, *, audience=None) -> AuthenticationResult:
        if user is None or password != "right" or (audience is not None and not audience(user)):
            return AuthenticationResult(False, None, AuthenticationStatus.INVALID_CREDENTIALS)
        return AuthenticationResult(True, user, AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr(target, fake)


def _customer_login(client, monkeypatch, user=CUSTOMER, password="right", headers=ORIGIN):
    _fake_authenticate(monkeypatch, "src.routers.customer_auth.authenticate_portal_user", user)
    return client.post("/auth/login", json={"username": user.username, "password": password}, headers=headers)


def _admin_login(portal_client, monkeypatch, user=CUSTOMER):
    async def fake(username: str, password: str, **_) -> AuthenticationResult:
        return AuthenticationResult(True, user, AuthenticationStatus.AUTHENTICATED)

    monkeypatch.setattr("src.main.authenticate_portal_user", fake)
    response = portal_client.post("/login", data={"username": user.username, "password": "x", "next_path": "/"})
    assert response.status_code == 303


# --- isolation from the Administration App -------------------------------------------

def test_customer_api_exposes_only_api_v1_auth_and_health(customer_module) -> None:
    paths = {getattr(r, "path", None) for r in customer_module.app.routes}
    assert {p for p in paths if not p.startswith("/api/v1/")} == {"/auth/login", "/auth/logout", "/auth/session", "/health"}
    for forbidden in ("/login", "/logout", "/administration", "/onboarding", "/context", "/app", "/static",
                      "/forbidden", "/api/live/assets/{asset_id}/ws", "/openapi.json", "/docs"):
        assert not any(p == forbidden or p.startswith(forbidden + "/") for p in paths), forbidden


def test_api_v1_routes_match_the_admin_portal_exactly(customer_module) -> None:
    from src.main import app as admin_app

    def api_v1(app):
        return {
            (r.path, frozenset(getattr(r, "methods", ()) or ()))
            for r in app.routes if getattr(r, "path", "").startswith("/api/v1/")
        }

    assert api_v1(customer_module.app) == api_v1(admin_app)


def test_customer_api_loads_without_admin_code_or_secrets() -> None:
    probe = (
        "import sys, json, src.customer_main as m; "
        "print(json.dumps({'admin': 'src.main' in sys.modules, 'grafana': 'src.grafana_client' in sys.modules, "
        "'settings': type(m.settings).__name__, 'cookie': m.settings.session_cookie_name, "
        "'grafana_fields': [f for f in type(m.settings).model_fields if 'grafana' in f]}))"
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith("EMS_GRAFANA")}
    env["PYTHONPATH"] = str(APP_DIR)
    result = subprocess.run([sys.executable, "-c", probe], cwd=APP_DIR, env=env, capture_output=True, text=True,
                            timeout=120)
    assert result.returncode == 0, result.stderr
    state = json.loads(result.stdout.strip().splitlines()[-1])
    assert state == {"admin": False, "grafana": False, "settings": "CustomerSettings", "cookie": "ems_session",
                     "grafana_fields": []}


def test_customer_settings_refuse_the_admin_cookie_name() -> None:
    from pydantic import ValidationError

    from src.customer_config import CustomerSettings

    with pytest.raises(ValidationError):
        CustomerSettings(EMS_APP_SESSION_COOKIE_NAME="ems_admin_session")
    settings = CustomerSettings()
    assert (settings.session_cookie_name, settings.customer_allow_staff, settings.report_export_worker_enabled) == (
        "ems_session", False, False)


def test_no_api_documentation_is_served(customer_client, monkeypatch) -> None:
    assert _customer_login(customer_client, monkeypatch).status_code == 200
    for path in ("/openapi.json", "/docs", "/redoc"):
        assert customer_client.get(path).status_code == 404


# --- authentication and session ------------------------------------------------------

def test_sign_in_mode_probe_is_public_and_identity_free(customer_client, monkeypatch) -> None:
    for signed_in in (False, True):
        if signed_in:
            assert _customer_login(customer_client, monkeypatch).status_code == 200
        response = customer_client.get("/auth/session")
        assert (response.status_code, response.json()) == (200, {"sign_in": "customer"})
        assert response.headers["cache-control"] == "no-store"


def test_unauthenticated_api_is_a_json_401_never_a_redirect(customer_client) -> None:
    response = customer_client.get("/api/v1/me")
    assert response.status_code == 401
    assert response.json() == {"error": "unauthenticated", "detail": "Authentication is required."}
    assert "location" not in response.headers


def test_login_sets_a_host_only_httponly_customer_cookie_and_returns_me(customer_client, monkeypatch) -> None:
    response = _customer_login(customer_client, monkeypatch)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    body = response.json()
    assert body["portal_user_id"] == 701 and body["access_scope_mode"] == "ORGANIZATION"
    cookie = response.headers["set-cookie"]
    assert cookie.startswith("ems_session=")
    assert "httponly" in cookie.lower() and "samesite=lax" in cookie.lower() and "path=/" in cookie.lower()
    assert "domain=" not in cookie.lower()
    assert "ems_admin_session" not in cookie
    assert customer_client.get("/api/v1/me").json()["portal_user_id"] == 701


GENERIC_401 = {"error": "invalid_credentials", "detail": "Invalid username or password."}


def test_wrong_password_is_the_generic_401_and_no_session(customer_client, monkeypatch) -> None:
    response = _customer_login(customer_client, monkeypatch, password="wrong")
    assert (response.status_code, response.json()) == (401, GENERIC_401)
    assert customer_client.get("/api/v1/me").status_code == 401


def test_unknown_user_is_the_same_generic_401(customer_client, monkeypatch) -> None:
    _fake_authenticate(monkeypatch, "src.routers.customer_auth.authenticate_portal_user", None)
    response = customer_client.post("/auth/login", json={"username": "nobody@example", "password": "right"},
                                    headers=ORIGIN)
    assert (response.status_code, response.json()) == (401, GENERIC_401)


def test_a_failed_login_signs_out_an_existing_session(customer_client, monkeypatch) -> None:
    assert _customer_login(customer_client, monkeypatch).status_code == 200
    assert _customer_login(customer_client, monkeypatch, password="wrong").status_code == 401
    assert customer_client.get("/api/v1/me").status_code == 401


def test_malformed_login_body_is_a_flat_422(customer_client) -> None:
    response = customer_client.post("/auth/login", json={"username": ""}, headers=ORIGIN)
    assert response.status_code == 422 and response.json()["error"] == "invalid_request"


def test_logout_ends_the_session(customer_client, monkeypatch) -> None:
    assert _customer_login(customer_client, monkeypatch).status_code == 200
    response = customer_client.post("/auth/logout", headers=ORIGIN)
    assert response.status_code == 204 and response.headers["cache-control"] == "no-store"
    assert customer_client.get("/api/v1/me").status_code == 401


def test_admin_session_cookie_is_not_accepted(customer_client, portal_client, monkeypatch) -> None:
    _admin_login(portal_client, monkeypatch)
    admin_cookie = portal_client.cookies.get("ems_admin_session")
    assert admin_cookie
    customer_client.cookies.set("ems_admin_session", admin_cookie)
    assert customer_client.get("/api/v1/me").status_code == 401


# --- CSRF: state-changing requests must be same-origin -------------------------------

@pytest.mark.parametrize("headers", [{}, {"Origin": "https://evil.example"}, {"Origin": "null"}])
def test_login_refuses_missing_or_foreign_origin(customer_client, monkeypatch, headers) -> None:
    response = _customer_login(customer_client, monkeypatch, headers=headers)
    assert response.status_code == 403
    assert response.json() == {"error": "forbidden", "detail": "Cross-origin request refused."}
    assert "set-cookie" not in response.headers


def test_logout_and_api_writes_refuse_foreign_origin(customer_client, monkeypatch) -> None:
    assert _customer_login(customer_client, monkeypatch).status_code == 200
    assert customer_client.post("/auth/logout", headers={"Origin": "https://evil.example"}).status_code == 403
    assert customer_client.get("/api/v1/me").status_code == 200          # still signed in
    assert customer_client.post(f"/api/v1/sites/{SITE_ID}/report-exports", json={},
                                headers={"Origin": "https://evil.example"}).status_code == 403


# --- audience: customers only unless staff are allowed --------------------------------

def test_staff_cannot_sign_in_by_default(customer_client, monkeypatch) -> None:
    response = _customer_login(customer_client, monkeypatch, user=STAFF)
    assert response.status_code == 401
    assert response.json()["error"] == "invalid_credentials"


def test_staff_can_sign_in_when_allowed_and_are_signed_out_when_disallowed(customer_client, customer_module,
                                                                          monkeypatch) -> None:
    monkeypatch.setattr(customer_module.settings, "customer_allow_staff", True)
    assert _customer_login(customer_client, monkeypatch, user=STAFF).status_code == 200
    assert customer_client.get("/api/v1/me").status_code == 200
    monkeypatch.setattr(customer_module.settings, "customer_allow_staff", False)
    assert customer_client.get("/api/v1/me").status_code == 401
    monkeypatch.setattr(customer_module.settings, "customer_allow_staff", True)
    assert customer_client.get("/api/v1/me").status_code == 401           # the session was cleared


# --- parity with the admin portal ---------------------------------------------------

def _alert_row() -> dict:
    return {
        "alert_id": ALERT_ID, "site_id": SITE_ID, "space_id": None, "asset_id": None,
        "condition_key": "ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:" + SITE_ID,
        "metric": "ENERGY_CONSUMPTION", "state": "ACTIVE",
        "triggered_at": datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc), "trigger_value": 123.4,
        "resolved_at": None, "resolved_value": None, "ended_at": None, "ended_reason": None,
        "ended_reason_code": None, "data_unavailable": False, "previous_occurrence_count": 2,
        "most_recent_previous_triggered_at": None,
    }


@pytest.fixture
def both(customer_client, portal_client, monkeypatch):
    """The same customer identity signed in to both apps; data layer faked once."""

    seen: list[int] = []

    async def can_access(portal_user_id, site_id):
        seen.append(portal_user_id)
        return str(site_id) == SITE_ID

    async def alerts(**kwargs):
        seen.append(kwargs.get("portal_user_id"))
        return [_alert_row()]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", can_access)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", alerts)
    _admin_login(portal_client, monkeypatch)
    assert _customer_login(customer_client, monkeypatch).status_code == 200
    return portal_client, customer_client, seen


@pytest.mark.parametrize("path", [
    "/api/v1/me",
    f"/api/v1/sites/{SITE_ID}/alerts?state=ACTIVE",
    f"/api/v1/sites/{SITE_ID}/alerts?state=BOGUS",
    "/api/v1/sites/44444444-4444-4444-8444-444444444444/alerts?state=ACTIVE",
    "/api/v1/sites/not-a-uuid/alerts",
    "/api/v1/no-such-endpoint",
])
def test_api_v1_responses_are_identical(both, path) -> None:
    admin, customer, seen = both
    a, c = admin.get(path), customer.get(path)
    assert (c.status_code, c.json()) == (a.status_code, a.json())
    assert set(seen) <= {CUSTOMER.portal_user_id}           # the session's identity reaches the data layer


def test_unauthenticated_api_v1_bodies_are_identical(customer_client, portal_client) -> None:
    a = portal_client.get("/api/v1/sites")
    c = customer_client.get("/api/v1/sites")
    assert (c.status_code, c.json()) == (a.status_code, a.json()) == (401, a.json())
