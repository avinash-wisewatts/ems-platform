"""MVP-7 Basic Alerts -- /api/v1 route contract (ADR-016/ADR-017).

Router-level only: auth, tenant gate, state validation, list/detail shape,
and the recurrence fields' pass-through. The lifecycle state machine
(qualification/resolution/configuration-transition/retention) lives in SQL
(migration 239) and cannot be exercised without a live database -- see
test_alert_evaluation_contract.py for the static contract checks applied
instead, matching this repository's existing pattern (e.g.
test_demand_calculation_processor_contract.py) for SQL logic that has no
Python-layer equivalent to test directly.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

SITE_ID = "22222222-2222-4222-8222-222222222222"
ALERT_ID = "33333333-3333-4333-8333-333333333333"


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


def _alert_row(
    *,
    alert_id: str = ALERT_ID,
    site_id: str = SITE_ID,
    state: str = "ACTIVE",
    condition_key: str = "ENERGY_ATTENTION:PERCENT_DEVIATION_FROM_TYPICAL_REFERENCE:15:SITE:" + SITE_ID,
    triggered_at: datetime = datetime(2026, 9, 14, 10, 0, tzinfo=timezone.utc),
    trigger_value: float = 123.4,
    resolved_at: datetime | None = None,
    resolved_value: float | None = None,
    ended_at: datetime | None = None,
    ended_reason: str | None = None,
    ended_reason_code: str | None = None,
    data_unavailable: bool = False,
    previous_occurrence_count: int = 0,
    most_recent_previous_triggered_at: datetime | None = None,
) -> dict[str, Any]:
    return {
        "alert_id": alert_id,
        "site_id": site_id,
        "space_id": None,
        "asset_id": None,
        "condition_key": condition_key,
        "metric": "ENERGY_CONSUMPTION",
        "state": state,
        "triggered_at": triggered_at,
        "trigger_value": trigger_value,
        "resolved_at": resolved_at,
        "resolved_value": resolved_value,
        "ended_at": ended_at,
        "ended_reason": ended_reason,
        "ended_reason_code": ended_reason_code,
        "data_unavailable": data_unavailable,
        "previous_occurrence_count": previous_occurrence_count,
        "most_recent_previous_triggered_at": most_recent_previous_triggered_at,
    }


def test_site_alerts_requires_authentication(portal_client) -> None:
    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


def test_alert_detail_requires_authentication(portal_client) -> None:
    response = portal_client.get(f"/api/v1/alerts/{ALERT_ID}")
    assert response.status_code == 401


def test_site_alerts_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def rows(**kwargs):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", rows)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts")
    assert response.status_code == 404
    assert called["fetch"] is False


def test_site_alerts_rejects_invalid_state(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts", params={"state": "BOGUS"})
    assert response.status_code == 422


def test_site_alerts_returns_list_shape(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [_alert_row(previous_occurrence_count=2)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", rows)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts", params={"state": "ACTIVE"})
    assert response.status_code == 200
    body = response.json()
    assert body["site_id"] == SITE_ID
    assert len(body["alerts"]) == 1
    alert = body["alerts"][0]
    assert alert["state"] == "ACTIVE"
    assert alert["previous_occurrence_count"] == 2
    # Ended is never presented as Resolved -- ADR-016 decision 7/17.
    assert alert["resolved_at"] is None
    assert alert["ended_at"] is None


def test_site_alerts_ended_row_carries_reason_not_resolved_fields(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [
            _alert_row(
                state="ENDED",
                ended_at=datetime(2026, 9, 14, 11, 0, tzinfo=timezone.utc),
                ended_reason="Attention condition configuration changed",
                ended_reason_code="CONFIGURATION_CHANGED",
            )
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", rows)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts", params={"state": "ENDED"})
    assert response.status_code == 200
    alert = response.json()["alerts"][0]
    assert alert["state"] == "ENDED"
    assert alert["ended_reason"] == "Attention condition configuration changed"
    assert alert["ended_reason_code"] == "CONFIGURATION_CHANGED"
    assert alert["resolved_at"] is None
    assert alert["resolved_value"] is None


def test_active_alert_reports_data_unavailable_flag(portal_client, monkeypatch) -> None:
    """ADR-016 section 4 (amended 2026-09-15, migration 242): the API must
    expose the persisted data-unavailable flag so the frontend can show the
    required "Unable to evaluate" / "Latest value: Data unavailable"
    messaging -- this is a pass-through contract check only; the flag's
    origin (analytics.evaluate_alerts()) is not exercised here, see
    test_alert_evaluation_contract.py / the live-execution lifecycle test."""
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [_alert_row(data_unavailable=True)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", rows)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts", params={"state": "ACTIVE"})
    assert response.status_code == 200
    alert = response.json()["alerts"][0]
    assert alert["state"] == "ACTIVE"
    assert alert["data_unavailable"] is True


def test_ended_row_distinguishes_data_unavailable_from_configuration_changed(portal_client, monkeypatch) -> None:
    """The two Ended causes (ADR-016 section 7, amended 2026-09-15) must be
    distinguishable via the controlled ended_reason_code, not just the free-
    text ended_reason."""
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [
            _alert_row(
                state="ENDED",
                ended_at=datetime(2026, 9, 15, 12, 0, tzinfo=timezone.utc),
                ended_reason="Data was unavailable while this alert was active",
                ended_reason_code="DATA_UNAVAILABLE",
            )
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr("src.routers.analytics_api.fetch_site_alerts", rows)

    response = portal_client.get(f"/api/v1/sites/{SITE_ID}/alerts", params={"state": "ENDED"})
    assert response.status_code == 200
    alert = response.json()["alerts"][0]
    assert alert["ended_reason_code"] == "DATA_UNAVAILABLE"
    assert alert["ended_reason_code"] != "CONFIGURATION_CHANGED"


def test_alert_detail_404_when_no_row(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def empty(**kwargs):
        return []

    monkeypatch.setattr("src.routers.analytics_api.fetch_alert_detail", empty)

    response = portal_client.get(f"/api/v1/alerts/{ALERT_ID}")
    assert response.status_code == 404


def test_alert_detail_returns_full_shape(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def one(**kwargs):
        return [_alert_row(previous_occurrence_count=3)]

    monkeypatch.setattr("src.routers.analytics_api.fetch_alert_detail", one)

    response = portal_client.get(f"/api/v1/alerts/{ALERT_ID}")
    assert response.status_code == 200
    body = response.json()
    assert body["alert_id"] == ALERT_ID
    assert body["previous_occurrence_count"] == 3


def test_alert_detail_never_exposes_internal_identifiers(portal_client, monkeypatch) -> None:
    """ADR-016 decision 35: no device IDs, logical point IDs, or other
    internal identifiers -- the response model itself is the guarantee
    (AlertSummary has no such field), verified here as a contract."""
    _login_global_admin(portal_client, monkeypatch)

    async def one(**kwargs):
        return [_alert_row()]

    monkeypatch.setattr("src.routers.analytics_api.fetch_alert_detail", one)

    response = portal_client.get(f"/api/v1/alerts/{ALERT_ID}")
    body = response.json()
    forbidden_keys = {"device_id", "gateway_id", "logical_point_id", "point_id"}
    assert forbidden_keys.isdisjoint(body.keys())
