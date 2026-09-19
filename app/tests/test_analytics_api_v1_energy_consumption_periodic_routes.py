"""Main Dashboard Energy Usage chart -- migration 248 route contract.

GET /api/v1/sites/{site_id}/energy/consumption's `resolution` enum is
widened to include 1w/1mo/1y (server-side Weekly/Monthly/Yearly aggregation
of the SAME analytics.energy_consumption_daily historian resolution=1d
already reads) -- same path, same response model, same no_data contract.
1h/1d must remain byte-for-byte unaffected: they still call
fetch_site_energy_consumption, never fetch_site_energy_consumption_periodic.

Deep SQL correctness (real Weekly/Monthly/Yearly grouping, partial first/
last periods, timezone/calendar correctness, tenant isolation against real
rows) is covered separately by
scripts/test/assert_energy_consumption_periodic_portal_read.sql, which runs
against a real Postgres rather than a mocked service layer -- these tests
only pin the HTTP-layer contract and the dispatch/mapping wiring.
"""

from __future__ import annotations

from datetime import datetime, timezone

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


def _energy(portal_client, site_id: str = SITE_ID, **overrides):
    params = {
        "resolution": "1w",
        "from": "2026-08-24T00:00:00Z",
        "to": "2026-09-02T00:00:00Z",
    }
    params.update(overrides)
    return portal_client.get(f"/api/v1/sites/{site_id}/energy/consumption", params=params)


def _row(bucket_start: str, import_kwh: float) -> dict:
    return {
        "bucket_start": datetime.fromisoformat(bucket_start.replace("Z", "+00:00")).astimezone(timezone.utc),
        "import_consumption_kwh": import_kwh,
        "export_consumption_kwh": 0.0,
        "source_interval_count": 96,
    }


@pytest.mark.parametrize("resolution", ["1w", "1mo", "1y"])
def test_periodic_resolution_dispatches_to_periodic_fetch_not_hourly_daily(
    portal_client, monkeypatch, resolution
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"periodic": False, "hourly_daily": False}

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        called["periodic"] = True
        assert kwargs["resolution"] == resolution
        return [_row("2026-08-24T00:00:00Z", 37)]

    async def hourly_daily(**kwargs):
        called["hourly_daily"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption", hourly_daily)

    response = _energy(portal_client, resolution=resolution)
    assert response.status_code == 200
    assert called["periodic"] is True
    assert called["hourly_daily"] is False
    body = response.json()
    assert body["resolution"] == resolution
    assert body["no_data"] is False


@pytest.mark.parametrize("resolution", ["1h", "1d"])
def test_hourly_daily_resolution_still_dispatches_to_the_original_fetch(
    portal_client, monkeypatch, resolution
) -> None:
    """Regression guard for migration 248: widening the resolution enum
    must not change 1h/1d's existing dispatch."""

    _login_global_admin(portal_client, monkeypatch)

    called = {"periodic": False, "hourly_daily": False}

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        called["periodic"] = True
        return []

    async def hourly_daily(**kwargs):
        called["hourly_daily"] = True
        return [_row("2026-08-24T00:00:00Z", 12)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption", hourly_daily)

    response = _energy(
        portal_client, resolution=resolution, **{"from": "2026-08-24T00:00:00Z", "to": "2026-08-25T00:00:00Z"}
    )
    assert response.status_code == 200
    assert called["hourly_daily"] is True
    assert called["periodic"] is False


def test_periodic_inaccessible_site_is_404_and_never_fetches(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"periodic": False}

    async def no(portal_user_id, site_id):
        return False

    async def periodic(**kwargs):
        called["periodic"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    response = _energy(portal_client, resolution="1mo")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert called["periodic"] is False


def test_periodic_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def periodic(**kwargs):
        return [_row("2026-08-24T00:00:00Z", 10)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    allowed = _energy(portal_client, site_id=SITE_ID, resolution="1y")
    denied = _energy(portal_client, site_id=OTHER_SITE_ID, resolution="1y")
    assert allowed.status_code == 200
    assert denied.status_code == 404


def test_periodic_empty_result_is_200_no_data_true(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    response = _energy(portal_client, resolution="1mo")
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is True
    assert body["series"] == []


def test_periodic_representative_multi_period_range_maps_totals_in_order(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        return [
            _row("2026-06-01T00:00:00Z", 100.0),
            _row("2026-07-01T00:00:00Z", 150.5),
            _row("2026-08-01T00:00:00Z", 90.25),
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    response = _energy(
        portal_client, resolution="1mo", **{"from": "2026-06-01T00:00:00Z", "to": "2026-09-01T00:00:00Z"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is False
    assert [p["import_kwh"] for p in body["series"]] == [100.0, 150.5, 90.25]
    assert body["series"][0]["bucket_start"] == "2026-06-01T00:00:00Z"


def test_periodic_resolutions_are_no_longer_rejected_as_invalid(portal_client, monkeypatch) -> None:
    """1w/1mo/1y used to be outside ENERGY_RESOLUTION_MAX_WINDOW's keys and
    were rejected with invalid_resolution -- migration 248 adds them via a
    separate ENERGY_PERIODIC_RESOLUTION_MAX_WINDOW dict, merged only for
    this route."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    for resolution in ("1w", "1mo", "1y"):
        response = _energy(portal_client, resolution=resolution)
        assert response.status_code == 200, f"{resolution} should be accepted, got {response.status_code}"


def test_periodic_window_far_beyond_the_1d_366_day_cap_is_accepted(portal_client, monkeypatch) -> None:
    """Proves the periodic tiers' own (separate, much larger) window cap is
    what applies here -- NOT ENERGY_RESOLUTION_MAX_WINDOW["1d"]'s 366 days,
    which the plain Daily tier is still bound by unchanged."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def periodic(**kwargs):
        return [_row("2020-01-01T00:00:00Z", 1000.0)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_consumption_periodic", periodic)

    response = _energy(
        portal_client, resolution="1y", **{"from": "2020-01-01T00:00:00Z", "to": "2026-09-19T00:00:00Z"}
    )
    assert response.status_code == 200


def test_periodic_window_beyond_its_own_cap_is_422(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    response = _energy(
        portal_client, resolution="1y", **{"from": "1990-01-01T00:00:00Z", "to": "2026-09-19T00:00:00Z"}
    )
    assert response.status_code == 422
    assert response.json()["error"] == "time_range_too_large"


def test_periodic_endpoint_rejects_post(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = portal_client.post(f"/api/v1/sites/{SITE_ID}/energy/consumption")
    assert response.status_code == 405
