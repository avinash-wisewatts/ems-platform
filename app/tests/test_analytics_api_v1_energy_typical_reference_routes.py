"""Slice C -- /api/v1 comparable-period historical reference route + service
contract, per the approved "Slice C Historical Comparison Final
Implementation Specification."

Two layers of test here, matching the approved test matrix:

  * Router-level: auth, tenant gate, 404, parameter validation, and an
    explicit architectural guard proving this route never calls the
    consumption endpoint's own fetch function (migration 231) and never
    references migration 235's evidence function -- mirrors the pattern of
    test_analytics_api_v1_energy_evidence_routes.py.

  * Service-level: build_energy_typical_reference_response is exercised
    directly with constructed migration-236-shaped row fixtures, since the
    SQL function's OWN 70%-coverage arithmetic and comparable-period date
    math cannot be exercised without a live database (not available in
    this environment; migration 236 has not been applied anywhere). These
    tests instead prove the PYTHON aggregation layer -- median computation
    (including the approved even/odd tie behaviour), eligible/insufficient
    counting, and evidence pass-through -- is correct given whatever
    `eligible`/counters the SQL layer would have produced.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

import pytest

from src.analytics_api_service import (
    TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS,
    TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS,
    TYPICAL_REFERENCE_REQUESTED_PERIOD_COUNT,
    build_energy_typical_reference_response,
)
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


def _typical_reference(portal_client, **overrides):
    params = {"from": "2026-09-01T00:00:00Z", "to": "2026-09-08T00:00:00Z"}  # 7 whole days
    params.update(overrides)
    return portal_client.get(
        f"/api/v1/sites/{SITE_ID}/energy/consumption/typical-reference", params=params
    )


def _window_row(
    window_index: int,
    *,
    has_data: bool = True,
    total_kwh: float | None = 100.0,
    source_interval_count: int = 10,
    valid_import_intervals: int = 10,
    coverage_percent: float | None = 100.0,
    eligible: bool = True,
    gap: int = 0,
    reset: int = 0,
    rollover: int = 0,
    invalid: int = 0,
) -> dict[str, Any]:
    return {
        "window_index": window_index,
        "window_from": datetime(2026, 8, 1, tzinfo=timezone.utc),
        "window_to": datetime(2026, 8, 8, tzinfo=timezone.utc),
        "has_data": has_data,
        "total_import_kwh": total_kwh,
        "source_interval_count": source_interval_count,
        "valid_import_intervals": valid_import_intervals,
        "coverage_percent": coverage_percent,
        "eligible": eligible,
        "gap_interval_count": gap,
        "reset_interval_count": reset,
        "rollover_interval_count": rollover,
        "invalid_interval_count": invalid,
    }


def _build(rows: list[dict[str, Any]]):
    return build_energy_typical_reference_response(
        site_id=SITE_ID,
        period_length_days=7,
        dt_from=datetime(2026, 9, 1, tzinfo=timezone.utc),
        dt_to=datetime(2026, 9, 8, tzinfo=timezone.utc),
        rows=rows,
    )


# ---------------------------------------------------------------------------
# Locked product constants -- regression guard against silent drift.
# ---------------------------------------------------------------------------

def test_locked_constants_match_the_approved_specification() -> None:
    assert TYPICAL_REFERENCE_REQUESTED_PERIOD_COUNT == 8
    assert TYPICAL_REFERENCE_MIN_ELIGIBLE_PERIODS == 5
    assert TYPICAL_REFERENCE_PERIOD_LENGTHS_DAYS == (1, 7, 30, 90, 365)


# ---------------------------------------------------------------------------
# Service layer -- median / eligibility / evidence aggregation.
# ---------------------------------------------------------------------------

def test_clean_history_8_eligible_median_is_average_of_two_middle_values() -> None:
    totals = [95, 98, 99, 100, 101, 102, 104, 105]
    rows = [_window_row(i + 1, total_kwh=t) for i, t in enumerate(totals)]

    result = _build(rows)

    assert result.eligible_period_count == 8
    assert result.windows_with_data_count == 8
    assert result.sufficient is True
    # sorted: 95,98,99,100,101,102,104,105 -> middle two are 100,101
    assert result.typical_kwh == pytest.approx(100.5)
    assert result.requested_period_count == 8


@pytest.mark.parametrize("eligible_count", [8, 7, 6, 5])
def test_sufficient_at_5_through_8_eligible(eligible_count: int) -> None:
    rows = [
        _window_row(i + 1, eligible=(i < eligible_count), total_kwh=100.0 + i)
        for i in range(8)
    ]

    result = _build(rows)

    assert result.eligible_period_count == eligible_count
    assert result.sufficient is True
    assert result.typical_kwh is not None


def test_exactly_5_eligible_median_is_the_single_middle_value() -> None:
    totals = [80, 90, 100, 110, 120]
    rows = [_window_row(i + 1, total_kwh=t) for i, t in enumerate(totals)]

    result = _build(rows)

    assert result.eligible_period_count == 5
    assert result.sufficient is True
    assert result.typical_kwh == pytest.approx(100.0)  # the single middle value


def test_4_eligible_is_insufficient_never_a_manufactured_value() -> None:
    rows = [_window_row(i + 1, eligible=(i < 4), total_kwh=100.0) for i in range(8)]

    result = _build(rows)

    assert result.eligible_period_count == 4
    assert result.sufficient is False
    assert result.typical_kwh is None


def test_0_eligible_empty_history_is_insufficient() -> None:
    rows = [
        _window_row(i + 1, has_data=False, total_kwh=None, eligible=False, coverage_percent=None)
        for i in range(8)
    ]

    result = _build(rows)

    assert result.windows_with_data_count == 0
    assert result.eligible_period_count == 0
    assert result.sufficient is False
    assert result.typical_kwh is None


def test_windows_with_data_distinguished_from_eligible_windows() -> None:
    # 6 windows have data at all; only 5 of those clear the coverage
    # threshold -- the response must expose both numbers distinctly so the
    # UI can explain "we have some history, but not all of it was usable".
    rows = [
        _window_row(1, has_data=True, eligible=True, total_kwh=100),
        _window_row(2, has_data=True, eligible=True, total_kwh=101),
        _window_row(3, has_data=True, eligible=True, total_kwh=99),
        _window_row(4, has_data=True, eligible=True, total_kwh=102),
        _window_row(5, has_data=True, eligible=True, total_kwh=98),
        _window_row(6, has_data=True, eligible=False, total_kwh=50, coverage_percent=40.0),
        _window_row(7, has_data=False, eligible=False, total_kwh=None, coverage_percent=None),
        _window_row(8, has_data=False, eligible=False, total_kwh=None, coverage_percent=None),
    ]

    result = _build(rows)

    assert result.windows_with_data_count == 6
    assert result.eligible_period_count == 5
    assert result.sufficient is True


# ---------------------------------------------------------------------------
# Median outlier resistance -- explicit regression guard vs. a mean.
# ---------------------------------------------------------------------------

def test_median_resists_a_significant_outlier_unlike_a_mean() -> None:
    totals = [95, 98, 99, 100, 101, 102, 104, 340]  # one obvious outlier
    rows = [_window_row(i + 1, total_kwh=t) for i, t in enumerate(totals)]

    result = _build(rows)

    naive_mean = sum(totals) / len(totals)  # 129.875 -- pulled far upward
    assert result.typical_kwh == pytest.approx(100.5)  # median: (100+101)/2
    assert abs(result.typical_kwh - naive_mean) > 25
    # The outlier does not even need to be dropped from eligibility -- it's
    # a real, well-covered day; it simply has bounded influence on median.
    assert result.eligible_period_count == 8


# ---------------------------------------------------------------------------
# Evidence -- independent, overlapping, never mutually exclusive.
# ---------------------------------------------------------------------------

def test_evidence_counters_are_independent_and_may_overlap_within_one_window() -> None:
    rows = [
        _window_row(
            1,
            source_interval_count=1,
            valid_import_intervals=1,
            gap=1,
            reset=1,
            rollover=1,
            invalid=1,
        ),
        *[_window_row(i + 2, total_kwh=100.0) for i in range(4)],
    ]

    result = _build(rows)

    w1 = result.windows[0]
    assert w1.gap_interval_count == 1
    assert w1.reset_interval_count == 1
    assert w1.rollover_interval_count == 1
    assert w1.invalid_interval_count == 1
    # The four independent indicators sum to more than that one window's
    # own interval count -- proof they are not treated as a partition.
    total_indicators = (
        w1.gap_interval_count
        + w1.reset_interval_count
        + w1.rollover_interval_count
        + w1.invalid_interval_count
    )
    assert total_indicators > w1.source_interval_count
    # Still eligible -- eligibility came from the SQL layer's `eligible`
    # flag (coverage-based), never re-derived from these flags in Python.
    assert w1.eligible is True


def test_eligible_window_with_reset_or_rollover_remains_included() -> None:
    rows = [
        _window_row(1, eligible=True, reset=3, total_kwh=100.0),
        _window_row(2, eligible=True, rollover=2, total_kwh=101.0),
        *[_window_row(i + 3, total_kwh=100.0) for i in range(3)],
    ]

    result = _build(rows)

    assert result.eligible_period_count == 5
    assert result.windows[0].eligible is True
    assert result.windows[0].reset_interval_count == 3
    assert result.windows[1].eligible is True
    assert result.windows[1].rollover_interval_count == 2


def test_never_treats_missing_data_as_zero_consumption() -> None:
    rows = [
        _window_row(1, has_data=False, total_kwh=None, eligible=False, coverage_percent=None),
        *[_window_row(i + 2, total_kwh=100.0) for i in range(7)],
    ]

    result = _build(rows)

    assert result.windows[0].total_kwh is None
    assert result.windows[0].has_data is False
    # The missing window contributes nothing to eligible_period_count and
    # is excluded from the median input entirely, never averaged as 0.
    assert result.eligible_period_count == 7
    totals = [w.total_kwh for w in result.windows[1:]]
    assert result.typical_kwh == pytest.approx(sorted(totals)[3])  # median of 7 populated


# ---------------------------------------------------------------------------
# Router: auth, contract validation, tenant gate.
# ---------------------------------------------------------------------------

def test_typical_reference_requires_authentication(portal_client) -> None:
    response = _typical_reference(portal_client)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthenticated"


@pytest.mark.parametrize("period_days", [1, 7, 30, 90, 365])
def test_supported_period_lengths_are_accepted(
    portal_client, monkeypatch, period_days: int
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [_window_row(i + 1, total_kwh=100.0) for i in range(8)]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_typical_reference", rows
    )

    to = "2026-09-08T00:00:00Z"
    from datetime import timedelta

    start = datetime(2026, 9, 8, tzinfo=timezone.utc) - timedelta(days=period_days)
    response = _typical_reference(
        portal_client, **{"from": start.isoformat().replace("+00:00", "Z"), "to": to}
    )
    assert response.status_code == 200
    assert response.json()["period_length_days"] == period_days


def test_unsupported_period_length_is_rejected(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    # 14 days -- not in the approved {1,7,30,90,365} set.
    response = _typical_reference(
        portal_client,
        **{"from": "2026-08-25T00:00:00Z", "to": "2026-09-08T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_period_length"


def test_non_whole_day_span_is_rejected(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _typical_reference(
        portal_client,
        **{"from": "2026-09-01T00:00:00Z", "to": "2026-09-08T05:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_from_after_to_is_rejected(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = _typical_reference(
        portal_client,
        **{"from": "2026-09-08T00:00:00Z", "to": "2026-09-01T00:00:00Z"},
    )
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_time_range"


def test_inaccessible_site_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    called = {"fetch": False}

    async def no(portal_user_id, site_id):
        return False

    async def rows(**kwargs):
        called["fetch"] = True
        return []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", no)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_typical_reference", rows
    )

    response = _typical_reference(portal_client)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert called["fetch"] is False


def test_empty_history_is_200_with_insufficient_not_an_error(
    portal_client, monkeypatch
) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [
            _window_row(
                i + 1, has_data=False, total_kwh=None, eligible=False, coverage_percent=None
            )
            for i in range(8)
        ]

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_typical_reference", rows
    )

    response = _typical_reference(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["sufficient"] is False
    assert body["typical_kwh"] is None
    assert body["eligible_period_count"] == 0
    assert len(body["windows"]) == 8


def test_endpoint_rejects_post(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    response = portal_client.post(
        f"/api/v1/sites/{SITE_ID}/energy/consumption/typical-reference"
    )
    assert response.status_code == 405


# ---------------------------------------------------------------------------
# Architectural guards: no dependency on migration 231's consumption fetch
# or migration 235's evidence fetch.
# ---------------------------------------------------------------------------

def test_route_does_not_call_consumption_fetch(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)

    async def yes(portal_user_id, site_id):
        return True

    async def rows(**kwargs):
        return [_window_row(i + 1, total_kwh=100.0) for i in range(8)]

    async def consumption_should_not_be_called(**kwargs):
        raise AssertionError(
            "GET .../typical-reference must not call fetch_site_energy_consumption "
            "(migration 231) -- it is a separate, additive read (migration 236)."
        )

    async def evidence_should_not_be_called(**kwargs):
        raise AssertionError(
            "GET .../typical-reference must not call "
            "fetch_site_energy_consumption_evidence (migration 235) -- no dependency "
            "on migration 235 is permitted."
        )

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", yes)
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_typical_reference", rows
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption",
        consumption_should_not_be_called,
    )
    monkeypatch.setattr(
        "src.routers.analytics_api.fetch_site_energy_consumption_evidence",
        evidence_should_not_be_called,
    )

    response = _typical_reference(portal_client)
    assert response.status_code == 200
