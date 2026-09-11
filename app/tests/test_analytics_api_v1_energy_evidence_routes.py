"""Slice C (Energy Performance, C2) -- /api/v1 energy evidence route contract.

Mirrors the pattern of test_analytics_api_v1_demand_routes.py: DB access is
monkeypatched at the service-function boundary imported into
src.routers.analytics_api, so these tests pin HTTP contract, authentication,
and the 404-vs-empty distinction without a database connection.

Architectural guard (source-path proof): every "rows mapped" test below
monkeypatches EXACTLY `fetch_site_energy_consumption_evidence` -- the function
migration 235 wires to analytics.get_portal_site_energy_consumption_evidence,
which reads analytics.energy_consumption_hourly/daily (the same two
historians migration 231 reads). `fetch_site_energy_consumption` (the
existing /energy/consumption endpoint's function) is never monkeypatched or
exercised by these tests, and a dedicated test below asserts the two routes
use two different, independent service functions.
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"


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


def _evidence(portal_client, **overrides):
    params = {
        "resolution": "1h",
        "from": "2026-09-01T00:00:00Z",
        "to": "2026-09-02T00:00:00Z",
    }
    params.update(overrides)
    return portal_client.get(
        f"/api/v1/sites/{SITE_ID}/energy/consumption/evidence", params=params
    )


# ---------------------------------------------------------------------------
# Authentication gate.
# ---------------------------------------------------------------------------

def test_evidence_requires_authentication(portal_client) -> None:
    response = _evidence(portal_client)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


# ---------------------------------------------------------------------------
# Contract validation (mirrors /energy/consumption exactly -- same
# ENERGY_RESOLUTION_MAX_WINDOW, same parse_time_range).
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad", ["raw", "5m", "15min", "1w"])
def test_evidence_invalid_resolution(portal_client, monkeypatch, bad) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _evidence(portal_client, resolution=bad)
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_resolution"


def test_evidence_1d_window_too_large(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _evidence(
        portal_client,
        resolution="1d",
        **{"from": "2024-01-01T00:00:00Z", "to": "2026-01-02T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "time_range_too_large"


def test_evidence_from_after_to(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _evidence(
        portal_client,
        **{"from": "2026-09-02T00:00:00Z", "to": "2026-09-01T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


# ---------------------------------------------------------------------------
# Tenant gate.
# ---------------------------------------------------------------------------

def test_evidence_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"evidence": False}

    async def no(portal_user_id, site_id):
        return False

    async def evidence(**kwargs):
        called["evidence"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption_evidence", evidence
    )

    response = _evidence(portal_client)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert called["evidence"] is False


# ---------------------------------------------------------------------------
# Row mapping / no-data.
# ---------------------------------------------------------------------------

def test_evidence_accessible_rows_mapped(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def evidence(**kwargs):
        return [
            {
                "bucket_start": datetime(2026, 9, 1, 0, 0, tzinfo=timezone.utc),
                "source_interval_count": 4,
                "valid_import_intervals": 3,
                "invalid_import_intervals": 1,
                "valid_export_intervals": 4,
                "invalid_export_intervals": 0,
                "gap_interval_count": 1,
                "reset_interval_count": 0,
                "rollover_interval_count": 0,
                "invalid_interval_count": 0,
                "first_source_bucket": datetime(2026, 9, 1, 0, 0, tzinfo=timezone.utc),
                "last_source_bucket": datetime(2026, 9, 1, 0, 45, tzinfo=timezone.utc),
            }
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption_evidence", evidence
    )

    response = _evidence(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["no_data"] is False
    assert body["resolution"] == "1h"
    assert body["series"] == [
        {
            "bucket_start": "2026-09-01T00:00:00Z",
            "source_interval_count": 4,
            "valid_import_intervals": 3,
            "invalid_import_intervals": 1,
            "valid_export_intervals": 4,
            "invalid_export_intervals": 0,
            "gap_interval_count": 1,
            "reset_interval_count": 0,
            "rollover_interval_count": 0,
            "invalid_interval_count": 0,
            "first_source_bucket": "2026-09-01T00:00:00Z",
            "last_source_bucket": "2026-09-01T00:45:00Z",
        }
    ]


def test_evidence_accessible_empty_is_200_no_data(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def evidence(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption_evidence", evidence
    )

    response = _evidence(portal_client)
    assert response.status_code == 200
    assert response.json()["no_data"] is True
    assert response.json()["series"] == []


def test_evidence_endpoint_rejects_post(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = portal_client.post(
        f"/api/v1/sites/{SITE_ID}/energy/consumption/evidence"
    )
    assert response.status_code == 405


# ---------------------------------------------------------------------------
# Architectural guard: the evidence route must not touch the existing
# /energy/consumption service function or response shape.
# ---------------------------------------------------------------------------

def test_evidence_route_does_not_call_consumption_fetch(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def evidence(**kwargs):
        return []

    async def consumption_should_not_be_called(**kwargs):
        raise AssertionError(
            "GET /energy/consumption/evidence must not call fetch_site_energy_consumption "
            "-- it is a separate, additive read (migration 235), not a wrapper "
            "around migration 231."
        )

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption_evidence", evidence
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption",
        consumption_should_not_be_called,
    )

    response = _evidence(portal_client)
    assert response.status_code == 200
