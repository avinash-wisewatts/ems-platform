"""Slice B (Power Quality backend, D1/D2) -- /api/v1 Power Quality route
contract.

Mirrors test_analytics_api_v1_hierarchy_routes.py / _demand_routes.py.
Architectural guard: every test monkeypatches
`fetch_site_power_quality_series` -- the one function migration 234 wires
to a direct config.site_energy_meter_roles JOIN, independent of
config.site_demand_policies. The migration's own postcondition block
asserts this at the SQL level (see
postgres/migrations/234_analytics_api_power_quality.sql); these tests pin
the HTTP-layer contract that depends on it (resolution vocabulary, no
threshold field anywhere in the response).
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE_ID = "33333333-3333-4333-8333-333333333333"


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


def _pq(portal_client, **overrides):
    params = {"resolution": "1h", "from": "2026-09-01T00:00:00Z", "to": "2026-09-02T00:00:00Z"}
    params.update(overrides)
    return portal_client.get(f"/api/v1/sites/{SITE_ID}/power-quality", params=params)


def test_power_quality_requires_authentication(portal_client) -> None:
    response = _pq(portal_client)
    assert response.status_code == 401


@pytest.mark.parametrize("bad", ["1min", "5min", "raw", "30min", ""])
def test_power_quality_invalid_resolution(portal_client, monkeypatch, bad) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _pq(portal_client, resolution=bad)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_resolution"


@pytest.mark.parametrize("resolution", ["15min", "1h", "1d"])
def test_power_quality_accepts_all_three_confirmed_live_resolutions(portal_client, monkeypatch, resolution) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_power_quality_series", fetch)

    response = _pq(portal_client, resolution=resolution)
    assert response.status_code == 200


def test_power_quality_from_after_to(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _pq(portal_client, **{"from": "2026-09-02T00:00:00Z", "to": "2026-09-01T00:00:00Z"})
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_power_quality_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def fetch(**kwargs):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_power_quality_series", fetch)

    response = _pq(portal_client)
    assert response.status_code == 404
    assert called["fetch"] is False


def test_power_quality_no_resolved_meter_is_200_empty_not_error(portal_client, monkeypatch) -> None:
    """A site with no SITE_CONSUMPTION-role device configured must return
    an empty, no_data series -- never an error -- per migration 234's
    resolution semantics (v_device_id IS NULL -> RETURN with zero rows)."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_power_quality_series", fetch)

    response = _pq(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is True
    assert body["series"] == []


def test_power_quality_returns_pf_and_all_three_thd_phases(portal_client, monkeypatch) -> None:
    """Response shape proof: PF plus L1/L2/L3 THD explicitly -- no
    fabricated 'total THD' field, matching the verified absence of a
    current_thd_total_percent column in the continuous aggregates."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(**kwargs):
        return [
            {
                "bucket_start": "2026-09-01T00:00:00Z",
                "power_factor_avg": 0.94,
                "power_factor_min": 0.90,
                "power_factor_max": 0.98,
                "current_thd_l1_avg": 4.2,
                "current_thd_l1_max": 5.1,
                "current_thd_l2_avg": 4.0,
                "current_thd_l2_max": 4.9,
                "current_thd_l3_avg": 4.4,
                "current_thd_l3_max": 5.3,
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_power_quality_series", fetch)

    response = _pq(portal_client)
    assert response.status_code == 200
    point = response.json()["series"][0]
    assert point["power_factor_avg"] == 0.94
    assert point["current_thd_l1_avg"] == 4.2
    assert point["current_thd_l2_avg"] == 4.0
    assert point["current_thd_l3_avg"] == 4.4
    # No invented threshold/status/deviation field anywhere in the response.
    assert "threshold" not in point
    assert "status" not in point
    assert "deviation" not in point


def test_power_quality_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def fetch(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_power_quality_series", fetch)

    allowed = portal_client.get(
        f"/api/v1/sites/{SITE_ID}/power-quality",
        params={"resolution": "1h", "from": "2026-09-01T00:00:00Z", "to": "2026-09-02T00:00:00Z"},
    )
    denied = portal_client.get(
        f"/api/v1/sites/{OTHER_SITE_ID}/power-quality",
        params={"resolution": "1h", "from": "2026-09-01T00:00:00Z", "to": "2026-09-02T00:00:00Z"},
    )
    assert allowed.status_code == 200
    assert denied.status_code == 404
