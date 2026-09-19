"""Phase 7 -- /api/v1 route behaviour (contract, auth, tenant gate, errors).

Database access is monkeypatched; these tests pin the HTTP contract, the
authentication gate, the 404-vs-no_data distinction, and the closed
parameter/resolution/time-range validation. DB-backed tenant-isolation
proof lives in test_analytics_api_v1_contract.py.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SPACE_ID = "77777777-7777-4777-8777-777777777777"
SITE_ID = "22222222-2222-4222-8222-222222222222"
ORG_ID = "11111111-1111-4111-8111-111111111111"


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
# Authentication gate (PortalAuthenticationMiddleware JSON branch).
# ---------------------------------------------------------------------------

def test_sites_requires_authentication(portal_client) -> None:
    response = portal_client.get("/api/v1/sites")
    assert response.status_code == 401
    assert response.headers["content-type"].startswith("application/json")
    assert response.json() == {
        "error": "unauthenticated",
        "detail": "Authentication is required.",
    }


def test_measurements_requires_authentication(portal_client) -> None:
    response = portal_client.get(
        f"/api/v1/spaces/{SPACE_ID}/measurements",
        params={
            "parameter": "TEMPERATURE",
            "resolution": "raw",
            "from": "2026-09-01T00:00:00Z",
            "to": "2026-09-01T06:00:00Z",
        },
    )
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


def test_unauthenticated_api_is_not_redirected_to_login(portal_client) -> None:
    response = portal_client.get("/api/v1/sites")
    assert response.status_code == 401
    assert "location" not in {k.lower() for k in response.headers}


# ---------------------------------------------------------------------------
# GET /api/v1/sites
# ---------------------------------------------------------------------------

def test_sites_returns_accessible_sites(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    seen: list[int] = []

    async def fake_sites(portal_user_id: int):
        seen.append(portal_user_id)
        return [
            {
                "site_id": SITE_ID,
                "organization_id": ORG_ID,
                "organization_name": "Acme Corp",
                "site_code": "SITE_1",
                "site_name": "Main Site",
                "timezone": "Asia/Kolkata",
            }
        ]

    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_accessible_sites", fake_sites
    )

    response = portal_client.get("/api/v1/sites")
    assert response.status_code == 200
    assert seen == [500]
    body = response.json()
    assert body == {
        "sites": [
            {
                "site_id": SITE_ID,
                "organization_id": ORG_ID,
                "organization_name": "Acme Corp",
                "site_code": "SITE_1",
                "site_name": "Main Site",
                "timezone": "Asia/Kolkata",
            }
        ]
    }


def test_sites_empty_is_200_not_error(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def fake_sites(portal_user_id: int):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_accessible_sites", fake_sites
    )

    response = portal_client.get("/api/v1/sites")
    assert response.status_code == 200
    assert response.json() == {"sites": []}


# ---------------------------------------------------------------------------
# GET /api/v1/spaces/{space_id}/measurements -- contract validation
# ---------------------------------------------------------------------------

def _measurements(portal_client, **overrides):
    params = {
        "parameter": "TEMPERATURE",
        "resolution": "raw",
        "from": "2026-09-01T00:00:00Z",
        "to": "2026-09-01T06:00:00Z",
    }
    params.update(overrides)
    return portal_client.get(
        f"/api/v1/spaces/{SPACE_ID}/measurements", params=params
    )


@pytest.mark.parametrize("bad", ["POWER", "co2", "", "temperature"])
def test_measurements_invalid_parameter(portal_client, monkeypatch, bad) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _measurements(portal_client, parameter=bad)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_parameter"


@pytest.mark.parametrize("bad", ["5m", "15m", "1d", "native", "RAW"])
def test_measurements_invalid_resolution(portal_client, monkeypatch, bad) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _measurements(portal_client, resolution=bad)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_resolution"


def test_measurements_from_after_to(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _measurements(
        portal_client,
        **{"from": "2026-09-02T00:00:00Z", "to": "2026-09-01T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_measurements_raw_window_too_large(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _measurements(
        portal_client,
        **{"from": "2026-09-01T00:00:00Z", "to": "2026-09-03T01:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "time_range_too_large"


def test_measurements_1h_allows_wider_window(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, space_id):
        return True

    async def rows(**kwargs):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_space", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_space_measurement_series", rows
    )

    response = _measurements(
        portal_client,
        resolution="1h",
        **{"from": "2026-08-10T00:00:00Z", "to": "2026-09-01T00:00:00Z"},
    )
    assert response.status_code == 200


def test_measurements_unparseable_timestamp(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _measurements(portal_client, **{"from": "not-a-date"})
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


# ---------------------------------------------------------------------------
# GET /api/v1/spaces/{space_id}/measurements -- 404 vs 200/no_data
# ---------------------------------------------------------------------------

def test_measurements_inaccessible_space_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"series": False}

    async def no(portal_user_id, space_id):
        return False

    async def series(**kwargs):
        called["series"] = True
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_space", no
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_space_measurement_series", series
    )

    response = _measurements(portal_client)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    # The series function must not run for an inaccessible/unknown space.
    assert called["series"] is False


def test_measurements_accessible_empty_range_is_200_no_data(
    portal_client, monkeypatch
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, space_id):
        return True

    async def series(**kwargs):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_space", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_space_measurement_series", series
    )

    response = _measurements(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is True
    assert body["series"] == []
    assert body["parameter"] == "TEMPERATURE"
    assert body["unit"] == "degC"
    assert body["resolution"] == "raw"
    assert body["from"] == "2026-09-01T00:00:00Z"
    assert body["to"] == "2026-09-01T06:00:00Z"


def test_measurements_rows_are_mapped_verbatim(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    seen: dict = {}

    async def yes(portal_user_id, space_id):
        return True

    async def series(**kwargs):
        seen.update(kwargs)
        return [
            {
                "bucket_start": datetime(2026, 9, 1, 0, 0, tzinfo=timezone.utc),
                "numeric_value": 21.5,
                "quality_code": None,
                "sample_count": 1,
            },
            {
                "bucket_start": datetime(2026, 9, 1, 0, 1, tzinfo=timezone.utc),
                "numeric_value": 21.6,
                "quality_code": None,
                "sample_count": 1,
            },
        ]

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_space", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_space_measurement_series", series
    )

    response = _measurements(portal_client, parameter="HUMIDITY")
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is False
    assert body["unit"] == "percent"
    assert [p["value"] for p in body["series"]] == [21.5, 21.6]
    assert all(p["quality"] is None for p in body["series"])
    # portal_user_id threaded to the boundary; browser value not trusted.
    assert seen["portal_user_id"] == 500
    assert str(seen["space_id"]) == SPACE_ID


def test_measurements_dew_point_value_is_not_transformed(
    portal_client, monkeypatch
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, space_id):
        return True

    async def series(**kwargs):
        assert kwargs["parameter"] == "DEW_POINT"
        return [
            {
                "bucket_start": datetime(2026, 9, 1, 0, 0, tzinfo=timezone.utc),
                "numeric_value": 12.3456789,
                "quality_code": None,
                "sample_count": 1,
            }
        ]

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_space", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_space_measurement_series", series
    )

    response = _measurements(portal_client, parameter="DEW_POINT")
    assert response.status_code == 200
    body = response.json()
    assert body["unit"] == "degC"
    assert body["series"][0]["value"] == 12.3456789


# ---------------------------------------------------------------------------
# GET /api/v1/sites/{site_id}/energy/consumption
# ---------------------------------------------------------------------------

def _energy(portal_client, **overrides):
    params = {
        "resolution": "1h",
        "from": "2026-09-01T00:00:00Z",
        "to": "2026-09-02T00:00:00Z",
    }
    params.update(overrides)
    return portal_client.get(
        f"/api/v1/sites/{SITE_ID}/energy/consumption", params=params
    )


@pytest.mark.parametrize("bad", ["raw", "5m", "15m", "1q"])
def test_energy_invalid_resolution(portal_client, monkeypatch, bad) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _energy(portal_client, resolution=bad)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_resolution"


def test_energy_1d_window_too_large(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _energy(
        portal_client,
        resolution="1d",
        **{"from": "2024-01-01T00:00:00Z", "to": "2026-01-02T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "time_range_too_large"


def test_energy_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"series": False}

    async def no(portal_user_id, site_id):
        return False

    async def series(**kwargs):
        called["series"] = True
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_site", no
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption", series
    )

    response = _energy(portal_client)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert called["series"] is False


def test_energy_accessible_rows_mapped(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def series(**kwargs):
        return [
            {
                "bucket_start": datetime(2026, 9, 1, 0, 0, tzinfo=timezone.utc),
                "import_consumption_kwh": 4.25,
                "export_consumption_kwh": 0.0,
                "source_interval_count": 4,
            }
        ]

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_site", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption", series
    )

    response = _energy(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is False
    assert body["resolution"] == "1h"
    assert body["series"] == [
        {
            "bucket_start": "2026-09-01T00:00:00Z",
            "import_kwh": 4.25,
            "export_kwh": 0.0,
            "source_interval_count": 4,
        }
    ]


def test_energy_accessible_empty_is_200_no_data(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def series(**kwargs):
        return []

    monkeypatch.setattr(
        "src.routers.analytics_api.portal_user_can_access_site", yes
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption", series
    )

    response = _energy(portal_client)
    assert response.status_code == 200
    assert response.json()["no_data"] is True
    assert response.json()["series"] == []


def test_energy_endpoint_rejects_post(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = portal_client.post(
        f"/api/v1/sites/{SITE_ID}/energy/consumption"
    )
    assert response.status_code == 405
