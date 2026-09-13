"""MVP-4 (Data Quality & Freshness) -- /api/v1 telemetry-freshness route
contract.

Mirrors test_analytics_api_v1_power_quality_routes.py /
_demand_routes.py. Architectural guard: every test monkeypatches
`fetch_site_telemetry_freshness` -- the one function migration 237 wires
to analytics.get_portal_site_telemetry_freshness. These tests pin the
HTTP-layer contract that decision pack Sec 5/5a requires: a stable
FRESH/STALE/NO_DATA/UNKNOWN vocabulary per domain (energy, demand,
power_quality), no blended site-wide verdict, and no leakage of internal
identifiers (device_id, gateway_id) or internal state names
(NEVER_SEEN/SILENT/RECEIVING/VALIDATED, quality_status, quality_code)
into this response.

See docs/00-governance/decision-packs/mvp-4-data-quality-and-freshness-decision-pack.md.
"""

from __future__ import annotations

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult
from src.analytics_api_service import (
    DomainFreshness,
    build_site_telemetry_freshness_response,
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


def _freshness(portal_client, site_id: str = SITE_ID):
    return portal_client.get(f"/api/v1/sites/{site_id}/telemetry-freshness")


def _row(**overrides):
    row = {
        "site_id": SITE_ID,
        "energy_state": "FRESH",
        "energy_as_of": "2026-09-13T09:58:00Z",
        "demand_state": "FRESH",
        "demand_as_of": "2026-09-13T09:58:00Z",
        "power_quality_state": "FRESH",
        "power_quality_as_of": "2026-09-13T09:58:00Z",
    }
    row.update(overrides)
    return row


def test_telemetry_freshness_requires_authentication(portal_client) -> None:
    response = _freshness(portal_client)
    assert response.status_code == 401


def test_telemetry_freshness_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def fetch(portal_user_id, site_id):
        called["fetch"] = True
        return _row()

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    assert response.status_code == 404
    assert called["fetch"] is False


def test_telemetry_freshness_unknown_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def no(portal_user_id, site_id):
        return False

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)

    response = _freshness(portal_client, site_id="99999999-9999-4999-8999-999999999999")
    assert response.status_code == 404


def test_telemetry_freshness_authorized_site_returns_per_domain_states(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return _row(
            energy_state="FRESH",
            demand_state="STALE",
            power_quality_state="NO_DATA",
        )

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["site_id"] == SITE_ID
    assert body["energy"]["state"] == "FRESH"
    assert body["demand"]["state"] == "STALE"
    assert body["power_quality"]["state"] == "NO_DATA"


@pytest.mark.parametrize("state", ["FRESH", "STALE", "NO_DATA", "UNKNOWN"])
def test_telemetry_freshness_supports_every_api_semantic_state(portal_client, monkeypatch, state) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return _row(energy_state=state, demand_state=state, power_quality_state=state)

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["energy"]["state"] == state
    assert body["demand"]["state"] == state
    assert body["power_quality"]["state"] == state


def test_telemetry_freshness_no_resolved_device_is_unknown_not_fresh(portal_client, monkeypatch) -> None:
    """A site with no SITE_CONSUMPTION meter and no resolvable SITE-scope
    Demand policy must report UNKNOWN, never a fabricated FRESH -- the
    non-negotiable 'unknown must never read as positive' constraint."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return _row(
            energy_state="UNKNOWN",
            energy_as_of=None,
            demand_state="UNKNOWN",
            demand_as_of=None,
            power_quality_state="UNKNOWN",
            power_quality_as_of=None,
        )

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["energy"]["state"] == "UNKNOWN"
    assert body["energy"]["as_of"] is None
    assert body["demand"]["state"] == "UNKNOWN"
    assert body["power_quality"]["state"] == "UNKNOWN"


def test_telemetry_freshness_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def only_first_site_allowed(portal_user_id, site_id):
        return str(site_id) == SITE_ID

    async def fetch(portal_user_id, site_id):
        return _row()

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", only_first_site_allowed)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    allowed = _freshness(portal_client, site_id=SITE_ID)
    denied = _freshness(portal_client, site_id=OTHER_SITE_ID)
    assert allowed.status_code == 200
    assert denied.status_code == 404


def test_telemetry_freshness_response_contains_no_internal_identifiers_or_vocabulary(portal_client, monkeypatch) -> None:
    """Semantic-boundary proof (ADR-007 / ADR-001): no device_id,
    gateway_id, internal six-value telemetry state, or Demand/quality
    vocabulary anywhere in the response body."""

    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return _row()

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    assert response.status_code == 200
    raw_text = response.text.lower()

    for forbidden in (
        "device_id",
        "gateway_id",
        "logical_point_id",
        "never_seen",
        "silent",
        "receiving",
        "validated",
        "quality_status",
        "quality_code",
        "coverage_percent",
        "grafana",
    ):
        assert forbidden not in raw_text, f"forbidden term leaked into response: {forbidden}"

    # The only allowed vocabulary is the four API-semantic states.
    body = response.json()
    for domain in ("energy", "demand", "power_quality"):
        assert body[domain]["state"] in ("FRESH", "STALE", "NO_DATA", "UNKNOWN")


def test_telemetry_freshness_field_names_are_stable_semantic_contract(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def fetch(portal_user_id, site_id):
        return _row()

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_telemetry_freshness", fetch)

    response = _freshness(portal_client)
    body = response.json()
    assert set(body.keys()) == {"site_id", "energy", "demand", "power_quality"}
    for domain in ("energy", "demand", "power_quality"):
        assert set(body[domain].keys()) == {"state", "as_of"}


# ---------------------------------------------------------------------------
# Pure unit coverage for the row -> response-model mapping (no HTTP, no DB).
# ---------------------------------------------------------------------------

def test_build_site_telemetry_freshness_response_maps_row_fields() -> None:
    row = _row(energy_state="STALE", demand_state="NO_DATA", power_quality_state="FRESH")
    response = build_site_telemetry_freshness_response(site_id=SITE_ID, row=row)
    assert response.energy == DomainFreshness(state="STALE", as_of=row["energy_as_of"])
    assert response.demand.state == "NO_DATA"
    assert response.power_quality.state == "FRESH"


def test_build_site_telemetry_freshness_response_none_row_is_unknown_never_fresh() -> None:
    """Defense-in-depth: if this is ever reached with no row (should not
    happen given the router's own access check), it must default to
    UNKNOWN for every domain -- never fabricate a positive state."""

    response = build_site_telemetry_freshness_response(site_id=SITE_ID, row=None)
    assert response.energy.state == "UNKNOWN"
    assert response.demand.state == "UNKNOWN"
    assert response.power_quality.state == "UNKNOWN"
