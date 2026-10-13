"""T1.3a -- read-side stale-demand guard for the portal current-demand API.

analytics.demand_state is rewritten only when job 1078's finalization window
advances (~once per demand interval), so its latest row can belong to an
interval that has already ended. These tests pin that such a row is never
returned as the current value, and that the latest completed interval from
analytics.demand_intervals is returned alongside instead.

Builder tests exercise the guard directly; route tests prove both portal
endpoints apply it; fetcher tests pin the bounded, tenant-scoped SQL used for
the last completed interval. No database connection is used.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import pytest

from src import analytics_api_service as svc
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
ASSET_ID = "88888888-8888-4888-8888-888888888888"
UTC = timezone.utc
IST = timezone(timedelta(hours=5, minutes=30))

# The live interval [10:15, 10:30) UTC and the interval before it.
LIVE_START = datetime(2026, 10, 13, 10, 15, tzinfo=UTC)
LIVE_END = datetime(2026, 10, 13, 10, 30, tzinfo=UTC)
PREV_START = datetime(2026, 10, 13, 10, 0, tzinfo=UTC)


def _state_row(start: datetime, end: datetime, **overrides: Any) -> dict[str, Any]:
    row = {
        "interval_start": start,
        "interval_end": end,
        "current_demand_kw": 42.5,
        "current_demand_kva": 44.1,
        "quality_status": "PROVISIONAL",
        "coverage_percent": 93.0,
    }
    row.update(overrides)
    return row


def _completed_row(start: datetime, end: datetime, **overrides: Any) -> dict[str, Any]:
    row = {
        "interval_start": start,
        "interval_end": end,
        "demand_kw": 40.0,
        "peak_power_kw": 55.0,
        "quality_status": "VALID",
        "coverage_percent": 100.0,
    }
    row.update(overrides)
    return row


def _site(row, last_completed_row, now) -> svc.CurrentDemandResponse:
    return svc.build_current_demand_response(
        site_id=UUID(SITE_ID), row=row, last_completed_row=last_completed_row, now=now
    )


def _asset(row, last_completed_row, now) -> svc.AssetCurrentDemandResponse:
    return svc.build_asset_current_demand_response(
        asset_id=UUID(ASSET_ID), row=row, last_completed_row=last_completed_row, now=now
    )


def _assert_no_current_value(response) -> None:
    assert response.has_data is False
    assert response.interval_start is None
    assert response.interval_end is None
    assert response.current_demand_kw is None
    assert response.current_demand_kva is None
    assert response.quality_status is None
    assert response.coverage_percent is None


BUILDERS = pytest.mark.parametrize("build", [_site, _asset], ids=["site", "asset"])


# ---------------------------------------------------------------------------
# Current interval.
# ---------------------------------------------------------------------------

@BUILDERS
def test_current_interval_is_returned(build) -> None:
    now = LIVE_START + timedelta(minutes=7)
    last = _completed_row(PREV_START, LIVE_START)

    response = build(_state_row(LIVE_START, LIVE_END), last, now)

    assert response.has_data is True
    assert response.current_status == "CURRENT"
    assert response.evaluated_at == now
    assert response.interval_start == LIVE_START
    assert response.interval_end == LIVE_END
    assert response.current_demand_kw == 42.5
    assert response.current_demand_kva == 44.1
    assert response.quality_status == "PROVISIONAL"
    assert response.coverage_percent == 93.0
    # The last completed interval is reported alongside the current one.
    assert response.last_completed_interval is not None
    assert response.last_completed_interval.interval_start == PREV_START
    assert response.last_completed_interval.interval_end == LIVE_START


@BUILDERS
def test_interval_start_is_inclusive(build) -> None:
    response = build(_state_row(LIVE_START, LIVE_END), None, LIVE_START)
    assert response.current_status == "CURRENT"
    assert response.has_data is True


@BUILDERS
def test_kva_only_current_value_is_current(build) -> None:
    """A kVA-basis policy can produce a kVA value without a kW value."""
    row = _state_row(LIVE_START, LIVE_END, current_demand_kw=None)
    response = build(row, None, LIVE_START + timedelta(minutes=1))
    assert response.current_status == "CURRENT"
    assert response.current_demand_kw is None
    assert response.current_demand_kva == 44.1


# ---------------------------------------------------------------------------
# Stale: the latest demand_state row is for an interval that has ended.
# ---------------------------------------------------------------------------

@BUILDERS
def test_previous_interval_is_never_returned_as_current(build) -> None:
    """The CI-2 case: the provisional row for [10:00, 10:15) is still the
    latest demand_state row at 10:20, before job 1078 rewrites it."""
    now = LIVE_START + timedelta(minutes=5)
    stale = _state_row(PREV_START, LIVE_START)
    last = _completed_row(PREV_START - timedelta(minutes=15), PREV_START)

    response = build(stale, last, now)

    assert response.current_status == "STALE"
    _assert_no_current_value(response)
    assert response.last_completed_interval is not None
    assert response.last_completed_interval.interval_start == PREV_START - timedelta(minutes=15)
    assert response.last_completed_interval.demand_kw == 40.0
    assert response.last_completed_interval.quality_status == "VALID"


@BUILDERS
def test_interval_end_is_exclusive(build) -> None:
    response = build(_state_row(LIVE_START, LIVE_END), None, LIVE_END)
    assert response.current_status == "STALE"
    _assert_no_current_value(response)


@BUILDERS
def test_much_older_interval_is_stale(build) -> None:
    old_start = LIVE_START - timedelta(days=2)
    response = build(_state_row(old_start, old_start + timedelta(minutes=15)), None, LIVE_START)
    assert response.current_status == "STALE"
    _assert_no_current_value(response)


@BUILDERS
def test_future_interval_is_not_current(build) -> None:
    """Clock skew between writer and reader: a row for an interval that has
    not started yet is not the current interval either."""
    response = build(
        _state_row(LIVE_END, LIVE_END + timedelta(minutes=15)), None, LIVE_END - timedelta(seconds=1)
    )
    assert response.current_status == "STALE"
    _assert_no_current_value(response)


# ---------------------------------------------------------------------------
# Missing and incomplete data.
# ---------------------------------------------------------------------------

@BUILDERS
def test_missing_row_with_no_completed_interval(build) -> None:
    response = build(None, None, LIVE_START)
    assert response.current_status == "MISSING"
    _assert_no_current_value(response)
    assert response.last_completed_interval is None


@BUILDERS
def test_missing_row_still_reports_last_completed_interval(build) -> None:
    response = build(None, _completed_row(PREV_START, LIVE_START), LIVE_START + timedelta(minutes=2))
    assert response.current_status == "MISSING"
    _assert_no_current_value(response)
    assert response.last_completed_interval is not None
    assert response.last_completed_interval.interval_end == LIVE_START


@BUILDERS
def test_current_interval_without_a_value_is_no_value(build) -> None:
    """demand_state can hold NO_DATA (or another non-calculable status) for
    the current interval with no kW/kVA; that is not a current value."""
    row = _state_row(
        LIVE_START,
        LIVE_END,
        current_demand_kw=None,
        current_demand_kva=None,
        quality_status="NO_DATA",
        coverage_percent=None,
    )
    response = build(row, None, LIVE_START + timedelta(minutes=3))
    assert response.current_status == "NO_VALUE"
    _assert_no_current_value(response)


@BUILDERS
def test_incomplete_last_completed_interval_keeps_its_status(build) -> None:
    last = _completed_row(
        PREV_START, LIVE_START, demand_kw=31.7, quality_status="INCOMPLETE", coverage_percent=74.0
    )
    response = build(_state_row(PREV_START, LIVE_START), last, LIVE_START + timedelta(minutes=1))

    assert response.current_status == "STALE"
    point = response.last_completed_interval
    assert point is not None
    assert point.quality_status == "INCOMPLETE"
    assert point.demand_kw == 31.7
    assert point.coverage_percent == 74.0


@BUILDERS
def test_no_data_last_completed_interval_keeps_null_value(build) -> None:
    last = _completed_row(
        PREV_START,
        LIVE_START,
        demand_kw=None,
        peak_power_kw=None,
        quality_status="NO_DATA",
        coverage_percent=None,
    )
    response = build(None, last, LIVE_START + timedelta(minutes=1))
    point = response.last_completed_interval
    assert point is not None
    assert point.quality_status == "NO_DATA"
    assert point.demand_kw is None
    assert point.coverage_percent is None


# ---------------------------------------------------------------------------
# Timestamps and site-local interval boundaries.
# ---------------------------------------------------------------------------

@BUILDERS
def test_site_local_midnight_boundary(build) -> None:
    """IST site: the first interval of the local day [00:00, 00:15) IST is
    [18:30, 18:45) UTC on the previous UTC day. Instants compare correctly
    whatever offset the database returns them in."""
    local_start = datetime(2026, 10, 13, 0, 0, tzinfo=IST)
    local_end = datetime(2026, 10, 13, 0, 15, tzinfo=IST)
    assert local_start == datetime(2026, 10, 12, 18, 30, tzinfo=UTC)

    inside_utc = datetime(2026, 10, 12, 18, 31, tzinfo=UTC)
    current = build(_state_row(local_start, local_end), None, inside_utc)
    assert current.current_status == "CURRENT"
    assert current.interval_start == local_start

    # The last interval of the previous local day, read just after local
    # midnight, is stale.
    prev_day_last = _state_row(local_start - timedelta(minutes=15), local_start)
    stale = build(prev_day_last, None, datetime(2026, 10, 13, 0, 1, tzinfo=IST))
    assert stale.current_status == "STALE"


@BUILDERS
def test_iso_string_instants_are_accepted(build) -> None:
    row = _state_row("2026-10-13T15:45:00+05:30", "2026-10-13T16:00:00+05:30")
    response = build(row, None, datetime(2026, 10, 13, 10, 20, tzinfo=UTC))
    assert response.current_status == "CURRENT"
    assert response.interval_start == LIVE_START


@BUILDERS
def test_naive_evaluation_instant_is_rejected(build) -> None:
    with pytest.raises(ValueError):
        build(_state_row(LIVE_START, LIVE_END), None, datetime(2026, 10, 13, 10, 20))


def test_demand_now_is_timezone_aware() -> None:
    assert svc.demand_now().tzinfo is not None


# ---------------------------------------------------------------------------
# Last completed interval SQL: tenant-scoped series function, bounded.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("fetcher", "function_name", "scope_id"),
    [
        (svc.fetch_site_last_completed_demand_interval, "get_portal_site_demand_series", SITE_ID),
        (svc.fetch_asset_last_completed_demand_interval, "get_portal_asset_demand_series", ASSET_ID),
    ],
    ids=["site", "asset"],
)
async def test_last_completed_fetch_is_bounded_and_scoped(
    fetcher, function_name, scope_id, monkeypatch
) -> None:
    captured: dict[str, Any] = {}

    async def fake_read_rows(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
        captured["sql"] = sql
        captured["params"] = params
        return [_completed_row(PREV_START, LIVE_START)]

    monkeypatch.setattr(svc, "_read_rows", fake_read_rows)
    now = LIVE_START + timedelta(minutes=4)

    row = await fetcher(500, UUID(scope_id), now)

    sql = " ".join(captured["sql"].split())
    assert f"FROM analytics.{function_name}(%s, %s, %s, %s)" in sql
    assert "WHERE interval_end <= %s" in sql
    assert "ORDER BY interval_start DESC LIMIT 1" in sql
    assert "demand_state" not in sql
    assert captured["params"] == (
        500,
        scope_id,
        now - svc.LAST_COMPLETED_DEMAND_LOOKBACK,
        now,
        now,
    )
    assert row is not None and row["interval_start"] == PREV_START


async def test_last_completed_fetch_returns_none_when_empty(monkeypatch) -> None:
    async def fake_read_rows(sql: str, params: tuple[Any, ...]) -> list[dict[str, Any]]:
        return []

    monkeypatch.setattr(svc, "_read_rows", fake_read_rows)
    assert await svc.fetch_site_last_completed_demand_interval(500, UUID(SITE_ID), LIVE_START) is None


# ---------------------------------------------------------------------------
# Routes: both portal endpoints apply the guard.
# ---------------------------------------------------------------------------

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


ROUTES = pytest.mark.parametrize(
    ("path", "access_fn", "fetch_prefix"),
    [
        (f"/api/v1/sites/{SITE_ID}/demand/current", "portal_user_can_access_site", "fetch_site"),
        (
            f"/api/v1/sites/{SITE_ID}/assets/{ASSET_ID}/demand/current",
            "portal_user_can_access_asset",
            "fetch_asset",
        ),
    ],
    ids=["site", "asset"],
)


def _patch_route(monkeypatch, access_fn, fetch_prefix, state_row, completed_row, now) -> dict:
    seen: dict[str, Any] = {}

    async def yes(portal_user_id, scope_id):
        return True

    async def fetch_current(portal_user_id, scope_id):
        return state_row

    async def fetch_last_completed(portal_user_id, scope_id, evaluated_at):
        seen["now"] = evaluated_at
        return completed_row

    monkeypatch.setattr(f"src.routers.analytics_api.{access_fn}", yes)
    monkeypatch.setattr(f"src.routers.analytics_api.{fetch_prefix}_current_demand", fetch_current)
    monkeypatch.setattr(
        f"src.routers.analytics_api.{fetch_prefix}_last_completed_demand_interval",
        fetch_last_completed,
    )
    monkeypatch.setattr("src.routers.analytics_api.demand_now", lambda: now)
    return seen


@ROUTES
def test_route_suppresses_stale_interval(portal_client, monkeypatch, path, access_fn, fetch_prefix) -> None:
    _login_global_admin(portal_client, monkeypatch)
    now = LIVE_START + timedelta(minutes=5)
    seen = _patch_route(
        monkeypatch,
        access_fn,
        fetch_prefix,
        _state_row(PREV_START, LIVE_START),
        _completed_row(PREV_START - timedelta(minutes=15), PREV_START, quality_status="INCOMPLETE"),
        now,
    )

    response = portal_client.get(path)

    assert response.status_code == 200
    body = response.json()
    assert body["has_data"] is False
    assert body["current_status"] == "STALE"
    assert body["current_demand_kw"] is None
    assert body["interval_start"] is None
    assert body["last_completed_interval"]["interval_start"] == "2026-10-13T09:45:00Z"
    assert body["last_completed_interval"]["interval_end"] == "2026-10-13T10:00:00Z"
    assert body["last_completed_interval"]["quality_status"] == "INCOMPLETE"
    # The same instant drives both the guard and the last-completed read.
    assert seen["now"] == now
    assert body["evaluated_at"] == "2026-10-13T10:20:00Z"


@ROUTES
def test_route_returns_current_interval(portal_client, monkeypatch, path, access_fn, fetch_prefix) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch_route(
        monkeypatch,
        access_fn,
        fetch_prefix,
        _state_row(LIVE_START, LIVE_END),
        _completed_row(PREV_START, LIVE_START),
        LIVE_START + timedelta(minutes=9),
    )

    body = portal_client.get(path).json()

    assert body["has_data"] is True
    assert body["current_status"] == "CURRENT"
    assert body["current_demand_kw"] == 42.5
    assert body["interval_start"] == "2026-10-13T10:15:00Z"
    assert body["interval_end"] == "2026-10-13T10:30:00Z"
    assert body["last_completed_interval"]["interval_end"] == "2026-10-13T10:15:00Z"


@ROUTES
def test_route_missing_everything(portal_client, monkeypatch, path, access_fn, fetch_prefix) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch_route(monkeypatch, access_fn, fetch_prefix, None, None, LIVE_START)

    body = portal_client.get(path).json()

    assert body["has_data"] is False
    assert body["current_status"] == "MISSING"
    assert body["last_completed_interval"] is None
