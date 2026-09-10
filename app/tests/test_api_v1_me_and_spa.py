"""Phase 8 backend glue -- GET /api/v1/me session echo + the inert /app SPA hook.

These are the only backend changes Phase 8 introduces. /api/v1/me is an
additive session echo (no DB, no secrets); it does not alter any of the three
frozen Phase 7 data contracts. The /app SPA-serving block in src.main is a
complete no-op while no frontend bundle is present (the case in this image and
every test).
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


def _login(portal_client, monkeypatch, *, role_code: str, scope: str = "GLOBAL",
           organization_id=None, site_ids=()):
    user = AuthenticatedPortalUser(
        portal_user_id=42,
        username="p8@example.com",
        display_name="Phase 8 User",
        role_code=role_code,
        organization_id=organization_id,
        access_scope_mode=scope,
        site_ids=tuple(site_ids),
    )

    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True, user=user, status=AuthenticationStatus.AUTHENTICATED
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    r = portal_client.post(
        "/login",
        data={"username": "p8@example.com", "password": "x", "next_path": "/"},
    )
    assert r.status_code == 303
    return user


# ---------------------------------------------------------------------------
# GET /api/v1/me
# ---------------------------------------------------------------------------

def test_me_requires_authentication(portal_client) -> None:
    r = portal_client.get("/api/v1/me")
    assert r.status_code == 401
    assert r.headers["content-type"].startswith("application/json")
    assert r.json() == {
        "error": "unauthenticated",
        "detail": "Authentication is required.",
    }
    assert "location" not in {k.lower() for k in r.headers}


def test_me_echoes_global_admin_identity_and_permissions(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch, role_code="ADMIN", scope="GLOBAL")
    r = portal_client.get("/api/v1/me")
    assert r.status_code == 200
    body = r.json()
    assert body["portal_user_id"] == 42
    assert body["username"] == "p8@example.com"
    assert body["display_name"] == "Phase 8 User"
    assert body["role_code"] == "ADMIN"
    assert body["access_scope_mode"] == "GLOBAL"
    assert body["organization_id"] is None
    assert body["site_ids"] == []
    # ADMIN holds every canonical permission.
    assert set(body["permissions"]) == {
        "organization.manage", "user.manage", "site.manage", "location.manage",
        "asset.manage", "gateway.manage", "device.manage", "relationship.manage",
        "metering_policy.manage", "commissioning.execute", "alert.acknowledge",
        "dashboard.view", "report.export", "audit.view",
    }
    assert body["permissions"] == sorted(body["permissions"])


def test_me_viewer_permissions_are_view_only(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch, role_code="VIEWER",
           scope="ORGANIZATION",
           organization_id="11111111-1111-4111-8111-111111111111")
    r = portal_client.get("/api/v1/me")
    assert r.status_code == 200
    body = r.json()
    assert body["role_code"] == "VIEWER"
    assert body["access_scope_mode"] == "ORGANIZATION"
    assert body["organization_id"] == "11111111-1111-4111-8111-111111111111"
    assert set(body["permissions"]) == {"dashboard.view", "report.export"}
    # the shell's minimum permission is present for every role
    assert "dashboard.view" in body["permissions"]


def test_me_selected_sites_scope_reflects_site_ids(portal_client, monkeypatch) -> None:
    _login(
        portal_client, monkeypatch, role_code="OPERATOR", scope="SELECTED_SITES",
        organization_id="11111111-1111-4111-8111-111111111111",
        site_ids=("22222222-2222-4222-8222-222222222222",),
    )
    r = portal_client.get("/api/v1/me")
    assert r.status_code == 200
    body = r.json()
    assert body["access_scope_mode"] == "SELECTED_SITES"
    assert body["site_ids"] == ["22222222-2222-4222-8222-222222222222"]
    assert "dashboard.view" in body["permissions"]


def test_me_does_not_require_a_database_pool(portal_client, monkeypatch) -> None:
    # portal_client never enters the app lifespan, so the DB pool is never
    # opened. A successful /api/v1/me proves it performs no database access.
    _login(portal_client, monkeypatch, role_code="ADMIN")
    assert portal_client.get("/api/v1/me").status_code == 200


# ---------------------------------------------------------------------------
# /app SPA hook is inert without a bundle
# ---------------------------------------------------------------------------

def test_app_prefix_has_no_route_without_a_bundle(portal_client, monkeypatch) -> None:
    # No app/src/spa/index.html in the image or test tree -> src.main registers
    # no /app route at all.
    from src.main import app

    app_paths = {getattr(r, "path", None) for r in app.routes}
    assert "/app" not in app_paths
    assert "/app/{spa_path:path}" not in app_paths

    # Authenticated request to /app therefore 404s (no route), it does not
    # accidentally serve or shadow anything.
    _login(portal_client, monkeypatch, role_code="ADMIN")
    assert portal_client.get("/app").status_code == 404


def test_app_prefix_unauthenticated_uses_existing_login_redirect(portal_client) -> None:
    # /app is a normal protected path: the existing middleware redirects an
    # unauthenticated visitor to the existing /login flow (no JSON, no new
    # auth surface).
    r = portal_client.get("/app", follow_redirects=False)
    assert r.status_code == 303
    assert r.headers["location"].startswith("/login?next_path=")


# ---------------------------------------------------------------------------
# OpenAPI
# ---------------------------------------------------------------------------

def test_openapi_documents_me_without_disturbing_phase7_paths() -> None:
    from src.main import app

    schema = app.openapi()
    paths = schema["paths"]

    assert "/api/v1/me" in paths
    assert set(paths["/api/v1/me"]) == {"get"}
    op = paths["/api/v1/me"]["get"]
    assert op["operationId"] == "getCurrentUser"
    assert "session" in op["tags"]
    assert set(op["responses"]) >= {"200", "401"}

    # the three frozen Phase 7 contracts are still present and unchanged in shape
    for p in (
        "/api/v1/sites",
        "/api/v1/sites/{site_id}/energy/consumption",
        "/api/v1/spaces/{space_id}/measurements",
    ):
        assert p in paths
        assert set(paths[p]) == {"get"}

    assert "CurrentUserResponse" in schema["components"]["schemas"]
