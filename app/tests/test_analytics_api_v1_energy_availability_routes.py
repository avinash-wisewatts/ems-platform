"""WiseWatts dashboard redesign -- Main Dashboard Energy Usage chart.
/api/v1 GET /sites/{site_id}/energy/consumption/availability route contract
(migration 247).

Mirrors test_analytics_api_v1_telemetry_freshness_routes.py's structure.
Architectural guard: every test monkeypatches `fetch_site_energy_availability`
-- the one function migration 247 wires to
analytics.get_portal_site_energy_availability. This endpoint reports the
site's ACTUAL persisted energy-consumption data availability (earliest/
latest), independent of -- and never a substitute for -- the existing
ENERGY_RESOLUTION_MAX_WINDOW per-request query-window caps.
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult
from src.analytics_api_service import (
    SiteEnergyAvailabilityResponse,
    build_site_energy_availability_response,
)


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


def _availability(portal_client, site_id: str = SITE_ID):
    return portal_client.get(f"/api/v1/sites/{site_id}/energy/consumption/availability")


def test_availability_requires_authentication(portal_client) -> None:
    response = _availability(portal_client)
    assert response.status_code == 401


def test_availability_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def fetch(portal_user_id, site_id):
        called["fetch"] = True
        return {"site_id": SITE_ID, "earliest": "2025-01-01T00:00:00Z", "latest": "2026-09-19T00:00:00Z"}

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_availability", fetch)

    response = _availability(portal_client)
    assert response.status_code == 404
    assert called["fetch"] is False


def test_availability_unknown_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def no(portal_user_id, site_id):
        return False

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)

    response = _availability(portal_client, site_id="99999999-9999-4999-8999-999999999999")
    assert response.status_code == 404


def test_availability_returns_actual_earliest_and_latest(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return {"site_id": SITE_ID, "earliest": "2025-01-01T00:00:00Z", "latest": "2026-09-19T14:00:00Z"}

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_availability", fetch)

    response = _availability(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["site_id"] == SITE_ID
    assert body["has_data"] is True
    assert body["earliest"] == "2025-01-01T00:00:00Z"
    assert body["latest"] == "2026-09-19T14:00:00Z"


def test_availability_no_data_site_reports_has_data_false_never_a_fabricated_date(portal_client, monkeypatch) -> None:
    """A site the caller CAN access but that has no energy data anywhere
    (verified this session: true for every site in the local dev database)
    must report has_data=false with earliest/latest both null -- never a
    guessed date, and never treated the same as an inaccessible site."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return {"site_id": SITE_ID, "earliest": None, "latest": None}

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_availability", fetch)

    response = _availability(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["has_data"] is False
    assert body["earliest"] is None
    assert body["latest"] is None


def test_availability_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def fetch(portal_user_id, site_id):
        return {"site_id": site_id, "earliest": "2025-01-01T00:00:00Z", "latest": "2026-09-19T00:00:00Z"}

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_availability", fetch)

    allowed = _availability(portal_client, site_id=SITE_ID)
    denied = _availability(portal_client, site_id=OTHER_SITE_ID)
    assert allowed.status_code == 200
    assert denied.status_code == 404


def test_availability_field_names_are_stable_contract(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return {"site_id": SITE_ID, "earliest": "2025-01-01T00:00:00Z", "latest": "2026-09-19T00:00:00Z"}

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_energy_availability", fetch)

    response = _availability(portal_client)
    body = response.json()
    assert set(body.keys()) == {"site_id", "has_data", "earliest", "latest"}


# ---------------------------------------------------------------------------
# Pure unit coverage for the row -> response-model mapping (no HTTP, no DB).
# ---------------------------------------------------------------------------

def test_build_site_energy_availability_response_maps_row_fields() -> None:
    row = {"site_id": SITE_ID, "earliest": "2025-01-01T00:00:00Z", "latest": "2026-09-19T14:00:00Z"}
    response = build_site_energy_availability_response(site_id=SITE_ID, row=row)
    assert response == SiteEnergyAvailabilityResponse(
        site_id=SITE_ID, has_data=True, earliest=row["earliest"], latest=row["latest"]
    )


def test_build_site_energy_availability_response_null_earliest_is_no_data() -> None:
    row = {"site_id": SITE_ID, "earliest": None, "latest": None}
    response = build_site_energy_availability_response(site_id=SITE_ID, row=row)
    assert response.has_data is False
    assert response.earliest is None
    assert response.latest is None


def test_build_site_energy_availability_response_none_row_is_no_data_never_fabricated() -> None:
    """Defense-in-depth: if this is ever reached with no row (should not
    happen given the router's own access check), it must report
    has_data=false -- never fabricate a positive/dated result."""

    response = build_site_energy_availability_response(site_id=SITE_ID, row=None)
    assert response.has_data is False
    assert response.earliest is None
    assert response.latest is None
