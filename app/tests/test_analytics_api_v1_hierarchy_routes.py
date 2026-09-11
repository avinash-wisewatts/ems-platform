"""Slice 0 (Hierarchy Foundation) -- /api/v1 Space and Asset list routes.

Mirrors the contract/auth/tenant-gate pattern established in
test_analytics_api_v1_routes.py for the Phase 7 first slice: DB access is
monkeypatched at the service-function boundary imported into
src.routers.analytics_api, so these tests pin HTTP contract, authentication
gate, and the 404-vs-empty-list distinction without any database connection.
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE_ID = "33333333-3333-4333-8333-333333333333"
ORG_ID = "11111111-1111-4111-8111-111111111111"
SPACE_ID = "77777777-7777-4777-8777-777777777777"
ASSET_ID = "88888888-8888-4888-8888-888888888888"


def _login_global_admin(portal_client, monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=500,
                username="admin@example.com",
                display_name="Platform Admin",
                role_code="ADMIN",
                access_scope_mode="GLOBAL",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )
    assert response.status_code == 303


# ---------------------------------------------------------------------------
# Authentication gate.
# ---------------------------------------------------------------------------

def test_spaces_requires_authentication(portal_client) -> None:
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/spaces")
    assert response.status_code == 401
    assert response.json() == {
        "error": "unauthenticated",
        "detail": "Authentication is required.",
    }


def test_assets_requires_authentication(portal_client) -> None:
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/spaces -- 404 vs 200/empty, tenant isolation.
# ---------------------------------------------------------------------------

def test_spaces_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def fetch(portal_user_id, site_id):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_spaces", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/spaces")
    assert response.status_code == 404
    assert response.json() == {
        "error": "not_found",
        "detail": "Site not found or not accessible.",
    }
    assert called["fetch"] is False, "must not read data for an inaccessible site"


def test_spaces_empty_site_is_200_not_error(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_spaces", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/spaces")
    assert response.status_code == 200
    assert response.json() == {"site_id": SITE_ID, "spaces": []}


def test_spaces_returns_accessible_site_spaces(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    seen: list[int] = []

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        seen.append(portal_user_id)
        return [
            {
                "space_id": SPACE_ID,
                "site_id": SITE_ID,
                "space_code": "BANQUET_2",
                "space_name": "Banquet Hall 2",
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_spaces", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/spaces")
    assert response.status_code == 200
    assert seen == [500]
    assert response.json() == {
        "site_id": SITE_ID,
        "spaces": [
            {
                "space_id": SPACE_ID,
                "site_id": SITE_ID,
                "space_code": "BANQUET_2",
                "space_name": "Banquet Hall 2",
            }
        ],
    }


def test_spaces_tenant_isolation_does_not_leak_other_site(portal_client, monkeypatch) -> None:
    """A caller accessible to SITE_ID must not be able to read OTHER_SITE_ID's
    spaces by requesting a different site_id in the URL -- the access check
    is evaluated per-request against the URL's own site_id, not cached."""

    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def fetch(portal_user_id, site_id):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed
    )
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_spaces", fetch)

    allowed = portal_client.get(f"/api/v1/sites/{SITE_ID}/spaces")
    denied = portal_client.get(f"/api/v1/sites/{OTHER_SITE_ID}/spaces")

    assert allowed.status_code == 200
    assert denied.status_code == 404


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/assets -- 404 vs 200/empty, tenant isolation.
# ---------------------------------------------------------------------------

def test_assets_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def fetch(portal_user_id, site_id):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_assets", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert called["fetch"] is False


def test_assets_empty_site_is_200_not_error(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_assets", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets")
    assert response.status_code == 200
    assert response.json() == {"site_id": SITE_ID, "assets": []}


def test_assets_returns_accessible_site_assets_with_nullable_placement(
    portal_client, monkeypatch
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return [
            {
                "asset_id": ASSET_ID,
                "site_id": SITE_ID,
                "space_id": None,
                "parent_asset_id": None,
                "external_id": "AHU_01",
                "asset_name": "AHU 01",
                "lifecycle_status": "ACTIVE",
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_assets", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets")
    assert response.status_code == 200
    body = response.json()
    assert body["assets"][0]["space_id"] is None
    assert body["assets"][0]["parent_asset_id"] is None
    assert body["assets"][0]["external_id"] == "AHU_01"


def test_assets_tenant_isolation_does_not_leak_other_site(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def fetch(portal_user_id, site_id):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed
    )
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_assets", fetch)

    allowed = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets")
    denied = portal_client.get(f"/api/v1/sites/{OTHER_SITE_ID}/assets")

    assert allowed.status_code == 200
    assert denied.status_code == 404
