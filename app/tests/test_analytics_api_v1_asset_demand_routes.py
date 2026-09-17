"""Asset View (WiseWatts dashboard redesign, migration 245) --
/api/v1 asset demand route contract.

Mirrors the pattern of test_analytics_api_v1_demand_routes.py (Site Demand)
and test_analytics_api_v1_asset_energy_routes.py (Asset energy): DB access
is monkeypatched at the service-function boundary imported into
src.routers.analytics_api, so these tests pin HTTP contract, authentication,
and the 404-vs-empty distinction without a database connection.

Architectural guard (source-path proof): every test below monkeypatches
EXACTLY `fetch_asset_demand_series` / `fetch_asset_current_demand` -- the
two functions migration 245 wires to analytics.demand_intervals /
analytics.demand_state (scope_type='ASSET'). There is no code path in this
router module that could reach analytics.get_grafana_asset_demand_summary;
the migration's own postcondition block additionally asserts this at the
SQL level (see postgres/migrations/245_analytics_api_asset_demand.sql).
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


def _demand(portal_client, asset_id: str = ASSET_ID, **overrides):
    params = {"from": "2026-09-01T00:00:00Z", "to": "2026-09-08T00:00:00Z"}
    params.update(overrides)
    return portal_client.get(f"/api/v1/sites/{SITE_ID}/assets/{asset_id}/demand", params=params)


# ---------------------------------------------------------------------------
# Authentication gate.
# ---------------------------------------------------------------------------

def test_asset_demand_series_requires_authentication(portal_client) -> None:
    response = _demand(portal_client)
    assert response.status_code == 401
    assert response.json() == {"error": "unauthenticated", "detail": "Authentication is required."}


def test_asset_current_demand_requires_authentication(portal_client) -> None:
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/demand/current")
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/assets/{asset_id}/demand -- contract validation.
# ---------------------------------------------------------------------------

def test_asset_demand_series_from_after_to(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _demand(portal_client, **{"from": "2026-09-08T00:00:00Z", "to": "2026-09-01T00:00:00Z"})
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_asset_demand_series_window_too_large_is_422(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _demand(portal_client, **{"from": "2026-01-01T00:00:00Z", "to": "2026-09-01T00:00:00Z"})
    assert response.status_code == 422
    assert response.json()["error"] == "time_range_too_large"


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/assets/{asset_id}/demand -- 404 vs 200/empty,
# tenant isolation, source-path proof.
# ---------------------------------------------------------------------------

def test_asset_demand_series_inaccessible_asset_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, asset_id):
        return False

    async def fetch(**kwargs):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_demand_series", fetch)

    response = _demand(portal_client)
    assert response.status_code == 404
    assert called["fetch"] is False


def test_asset_demand_series_empty_is_200_no_data_true(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_demand_series", fetch)

    response = _demand(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["asset_id"] == ASSET_ID
    assert body["no_data"] is True
    assert body["series"] == []


def test_asset_demand_series_returns_rows_from_the_meter_role_resolved_source(portal_client, monkeypatch) -> None:
    """Source-path proof: the route reads via fetch_asset_demand_series
    (-> analytics.demand_intervals, scope_type='ASSET'), and the returned
    row's quality_status is passed through verbatim, not recomputed."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(**kwargs):
        return [
            {
                "interval_start": "2026-09-01T00:00:00Z",
                "interval_end": "2026-09-01T00:15:00Z",
                "demand_kw": 12.0,
                "peak_power_kw": 15.5,
                "quality_status": "VALID",
                "coverage_percent": 98.5,
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_demand_series", fetch)

    response = _demand(portal_client)
    assert response.status_code == 200
    point = response.json()["series"][0]
    assert point["demand_kw"] == 12.0
    assert point["peak_power_kw"] == 15.5
    assert point["quality_status"] == "VALID"
    assert point["coverage_percent"] == 98.5


def test_asset_demand_series_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_asset_allowed(portal_user_id, asset_id):
        return str(asset_id) == ASSET_ID

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", only_first_asset_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_demand_series", fetch)

    allowed = _demand(portal_client, asset_id=ASSET_ID)
    denied = _demand(portal_client, asset_id=OTHER_ASSET_ID)
    assert allowed.status_code == 200
    assert denied.status_code == 404


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/assets/{asset_id}/demand/current -- has_data
# distinction.
# ---------------------------------------------------------------------------

def test_asset_current_demand_inaccessible_asset_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def no(portal_user_id, asset_id):
        return False

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", no)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/demand/current")
    assert response.status_code == 404


def test_asset_current_demand_no_row_yet_has_data_false(portal_client, monkeypatch) -> None:
    """A real, expected state -- e.g. an asset with no PRIMARY_METER device
    has never had a demand_state row computed for it at all."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(portal_user_id, asset_id):
        return None

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_current_demand", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/demand/current")
    assert response.status_code == 200
    body = response.json()
    assert body["asset_id"] == ASSET_ID
    assert body["has_data"] is False
    assert body["current_demand_kw"] is None


def test_asset_current_demand_returns_the_live_reading(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, asset_id):
        return True

    async def fetch(portal_user_id, asset_id):
        return {
            "interval_start": "2026-09-08T11:15:00Z",
            "interval_end": "2026-09-08T11:30:00Z",
            "current_demand_kw": 12.0,
            "current_demand_kva": 12.6,
            "quality_status": "PROVISIONAL",
            "coverage_percent": 87.0,
        }

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_asset", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_asset_current_demand", fetch)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/demand/current")
    assert response.status_code == 200
    body = response.json()
    assert body["has_data"] is True
    assert body["current_demand_kw"] == 12.0
    assert body["quality_status"] == "PROVISIONAL"
