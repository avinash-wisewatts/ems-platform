"""Asset View (migration 246) -- /api/v1 asset power trend route contract.

Mirrors the pattern of test_analytics_api_v1_asset_demand_routes.py: DB
access is monkeypatched at the service-function boundary imported into
src.routers.analytics_api, so these tests pin HTTP contract, authentication,
and the 404-vs-empty distinction without a database connection.

Architectural guard (source-path proof): every test below monkeypatches
EXACTLY `fetch_asset_power_trend` -- the function migration 246 wires to
telemetry.energy_measurements (via the asset's PRIMARY_METER device). There
is no code path in this router module that could reach
analytics.get_grafana_asset_electrical_trend or any grafana_org_id/
v_grafana_* object; the migration's own postcondition block additionally
asserts this at the SQL level (see
postgres/migrations/246_analytics_api_asset_power_trend.sql).
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
ASSET_ID = "88888888-8888-4888-8888-888888888888"
OTHER_ASSET_ID = "99999999-9999-4999-8999-999999999999"


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


def _url(asset_id: str = ASSET_ID, **params: str) -> str:
    query = "&".join(f"{k}={v}" for k, v in params.items())
    return f"/api/v1/sites/{SITE_ID}/assets/{asset_id}/power-trend?{query}"


def test_asset_power_trend_requires_authentication(portal_client) -> None:
    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 401


def test_asset_power_trend_inaccessible_asset_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, asset_id):
        return False

    async def fetch(**kwargs):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_power_trend", fetch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 404
    assert called["fetch"] is False


def test_asset_power_trend_invalid_range_is_422(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T02:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_asset_power_trend_no_maximum_query_window(portal_client, monkeypatch) -> None:
    """No resolution routing and no application-layer cap -- native sample
    grain only, matching Demand's own "no artificial limit" decision."""
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_power_trend", fetch)

    response = portal_client.get(
        _url(**{"from": "2020-01-01T00:00:00Z", "to": "2026-09-16T00:00:00Z"})
    )
    assert response.status_code == 200
    assert response.json()["no_data"] is True


def test_asset_power_trend_returns_sample_rows(portal_client, monkeypatch) -> None:
    """Source-path proof: the route reads via fetch_asset_power_trend
    (-> telemetry.energy_measurements), and quality_code is never present
    in the response -- only is_estimated."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(**kwargs):
        return [
            {
                "sample_time": "2026-09-16T00:00:00Z",
                "active_power_kw": 12.5,
                "is_estimated": False,
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_power_trend", fetch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 200
    body = response.json()
    assert body["asset_id"] == ASSET_ID
    assert body["no_data"] is False
    point = body["series"][0]
    assert point["active_power_kw"] == 12.5
    assert point["is_estimated"] is False
    assert "quality_code" not in point


def test_asset_power_trend_empty_is_200_no_data_true(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_power_trend", fetch)

    response = portal_client.get(
        _url(**{"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"})
    )
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is True
    assert body["series"] == []


def test_asset_power_trend_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_asset_allowed(portal_user_id, asset_id):
        return str(asset_id) == ASSET_ID

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", only_first_asset_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_power_trend", fetch)

    params = {"from": "2026-09-16T00:00:00Z", "to": "2026-09-16T01:00:00Z"}
    allowed = portal_client.get(_url(ASSET_ID, **params))
    denied = portal_client.get(_url(OTHER_ASSET_ID, **params))
    assert allowed.status_code == 200
    assert denied.status_code == 404
