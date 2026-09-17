"""Asset View (WiseWatts dashboard redesign, migration 244) --
/api/v1 asset energy consumption route contract.

Mirrors the pattern of test_analytics_api_v1_hierarchy_routes.py's asset
live-state tests: DB access is monkeypatched at the service-function
boundary imported into src.routers.analytics_api, so these tests pin HTTP
contract, authentication, and the 404-vs-empty distinction without a
database connection.
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
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
        data={"username": "admin@example.com", "password": "valid-password", "next_path": "/"},
    )
    assert response.status_code == 303


def _url(**params: str) -> str:
    query = "&".join(f"{k}={v}" for k, v in params.items())
    return f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/energy/consumption?{query}"


def test_asset_energy_consumption_requires_authentication(portal_client) -> None:
    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 401


def test_asset_energy_consumption_inaccessible_asset_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def no(portal_user_id, asset_id):
        return False

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", no)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 404


def test_asset_energy_consumption_invalid_range_is_422(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T02:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_asset_energy_consumption_returns_interval_rows(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(portal_user_id, asset_id, dt_from, dt_to):
        return [
            {
                "interval_start": "2026-09-16T00:00:00Z",
                "device_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                "device_name": "Meter 1",
                "elapsed_minutes": 60.0,
                "import_consumption_kwh": 12.5,
                "export_consumption_kwh": 0.0,
                "import_quality_code": "GOOD",
                "export_quality_code": "GOOD",
                "reset_detected": False,
                "gap_detected": False,
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_energy_intervals", fetch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 200
    body = response.json()
    assert body["asset_id"] == ASSET_ID
    assert body["no_data"] is False
    assert body["series"][0]["import_consumption_kwh"] == 12.5


def test_asset_energy_consumption_empty_is_200_no_data_true(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(portal_user_id, asset_id, dt_from, dt_to):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_energy_intervals", fetch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is True
    assert body["series"] == []
