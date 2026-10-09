"""Analytics v1 (ADR-022) -- GET /api/v1/sites/{site_id}/analytics/series
route contract, request validation and response building, including the
Data Quality contract (migration 282; Data Quality decisions 1-22).

Route tests monkeypatch the data-access functions the route uses
(fetch_analytics_site, fetch_analytics_catalog, fetch_analytics_as_of,
fetch_analytics_energy_resolution_floors, fetch_analytics_energy_series).
The database reads themselves are covered by test_asset_energy_tier_read.py
and test_analytics_energy_series_data_quality.py.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

import src.analytics_trends_service as trends
from src.analytics_api_service import ApiContractError
from src.analytics_trends_service import (
    DataPointDefinition,
    SeriesRequest,
    Selection,
    apply_floor_aware_auto,
    parse_series_request,
    resolve_auto_resolution,
)
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
ASSET_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ASSET_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ASSET_X = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"   # not in the site's catalogue
SITE = {"site_id": SITE_ID, "site_name": "Coimbatore", "timezone": "Asia/Kolkata"}
T0 = datetime(2026, 9, 20, 0, 0, tzinfo=timezone.utc)
FROM, TO = "2026-09-20T00:00:00Z", "2026-09-20T02:00:00Z"
AS_OF = datetime(2026, 9, 28, 12, 0, tzinfo=timezone.utc)
NO_FLOORS = {r: None for r in ("1m", "15m", "30m", "1h", "1d")}


def _catalog_row(asset_id: str, name: str, data_point: str, qualifier: str = "TOTAL") -> dict:
    labels = {"ENERGY_IMPORT": "Active Energy Import", "ENERGY_EXPORT": "Active Energy Export"}
    return {
        "asset_id": asset_id, "asset_name": name, "asset_type_id": None, "asset_type_name": "AHU",
        "building_name": None, "floor_name": None, "space_id": None, "space_name": None,
        "location_path": None, "data_point": data_point, "data_point_name": labels.get(data_point, data_point),
        "category": "Energy", "unit": "kWh", "qualifier": qualifier,
    }


CATALOG = [
    _catalog_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT"),
    _catalog_row(ASSET_A, "Chiller 1", "ENERGY_EXPORT"),
    _catalog_row(ASSET_B, "AHU 2", "ENERGY_IMPORT"),
]


def _direction(prefix: str, *, kwh, valid, invalid=0, reconstructed=0, gap=0, reset=0, rollover=0,
               status="GOOD", data_state=None, assigned_expected=None) -> dict:
    return {
        f"{prefix}_kwh": None if kwh is None else Decimal(str(kwh)),
        f"{prefix}_status": status if kwh is not None else None,
        f"{prefix}_valid_intervals": valid, f"{prefix}_invalid_intervals": invalid,
        f"{prefix}_reconstructed_intervals": reconstructed, f"{prefix}_gap_intervals": gap,
        f"{prefix}_reset_intervals": reset, f"{prefix}_rollover_intervals": rollover,
        f"{prefix}_assigned_expected_intervals": valid + invalid + reconstructed if assigned_expected is None else assigned_expected,
        f"{prefix}_data_state": data_state or ("MEASURED" if kwh is not None else "GAP"),
    }


def _series_fields(*, first=T0 - timedelta(days=30), last=AS_OF - timedelta(minutes=2),
                   in_range=True, stale=False) -> dict:
    out = {}
    for prefix in ("import", "export"):
        out.update({
            f"{prefix}_first_data_at": first, f"{prefix}_last_data_at": last,
            f"{prefix}_assigned_in_range": in_range, f"{prefix}_stale": stale,
        })
    return out


def _energy_row(asset_id, hour, imp, exp, *, imp_n=60, exp_n=60, expected=60, imp_kw=None, exp_kw=None,
                series=None) -> dict:
    start = T0 + timedelta(hours=hour)
    row = {
        "asset_id": asset_id, "bucket_start": start, "bucket_end": start + timedelta(hours=1),
        "expected_intervals": expected, "is_partial": start + timedelta(hours=1) > AS_OF,
        "unavailable_reasons": None,
    }
    row.update(_direction("import", kwh=imp, valid=imp_n, **(imp_kw or {})))
    row.update(_direction("export", kwh=exp, valid=exp_n, **(exp_kw or {})))
    row.update(series or _series_fields())
    return row


def _marker(asset_id, *reasons) -> dict:
    return {"asset_id": asset_id, "bucket_start": None, "bucket_end": None, "unavailable_reasons": list(reasons)}


def _login(portal_client, monkeypatch: pytest.MonkeyPatch) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=500, username="admin@example.com", display_name="Platform Admin",
                role_code="ADMIN", access_scope_mode="GLOBAL",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post(
        "/login", data={"username": "admin@example.com", "password": "valid-password", "next_path": "/"}
    )
    assert response.status_code == 303


def _patch(monkeypatch, *, allowed=True, catalog=None, energy=None, calls=None, floors=None, as_of=AS_OF,
           points=None, point_floors=None):
    calls = calls if calls is not None else []

    async def access(portal_user_id, site_id):
        calls.append("access")
        return allowed

    async def fetch_site(portal_user_id, site_id):
        return SITE

    async def fetch_as_of():
        calls.append("as_of")
        return as_of

    async def fetch_catalog(portal_user_id, site_id):
        calls.append("catalog")
        return CATALOG if catalog is None else catalog

    async def fetch_energy(portal_user_id, site_id, asset_ids, dt_from, dt_to, resolution, read_as_of):
        calls.append(("energy", tuple(str(a) for a in asset_ids), resolution, read_as_of))
        return energy or []

    async def fetch_floors(site_id, read_as_of=None):
        calls.append(("floors", read_as_of))
        return floors if floors is not None else NO_FLOORS

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", access)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_site", fetch_site)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_as_of", fetch_as_of)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_catalog", fetch_catalog)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_series", fetch_energy)
    async def fetch_points(portal_user_id, site_id, specs, dt_from, dt_to, resolution, read_as_of):
        if specs:
            calls.append(("points", tuple((str(s.asset_id), s.data_point, s.qualifier) for s in specs), resolution))
        return points(specs, resolution) if callable(points) else (points or [])

    async def fetch_point_floors(read_as_of=None):
        calls.append(("point_floors", read_as_of))
        return point_floors if point_floors is not None else {"mean": dict(NO_FLOORS), "delta": dict(NO_FLOORS)}

    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_resolution_floors", fetch_floors)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_point_series", fetch_points)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_point_resolution_floors", fetch_point_floors)
    return calls


def _series(portal_client, *selections, **params):
    query = {"from": FROM, "to": TO, "resolution": "1h", **params}
    query_list = [(k, v) for k, v in query.items() if v is not None]
    query_list += [("selection", s) for s in selections]
    return portal_client.get(f"/api/v1/sites/{SITE_ID}/analytics/series", params=query_list)


def _energy_calls(calls):
    return [c for c in calls if isinstance(c, tuple) and c[0] == "energy"]


# ---------------------------------------------------------------------------
# Route contract
# ---------------------------------------------------------------------------


def test_series_requires_authentication(portal_client) -> None:
    assert _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").status_code == 401


def test_series_inaccessible_site_is_404_without_reading(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, allowed=False)
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert calls == ["access"]


def test_contract_is_validated_before_access_or_reads(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch)
    # Apparent Power is assigned on staging but deliberately not in the
    # B3 registry (Product Owner scope, 2026-10-09).
    response = _series(portal_client, f"{ASSET_A}:APPARENT_POWER")
    assert response.status_code == 422
    assert response.json()["error"] == "unknown_data_point"
    assert calls == []


@pytest.mark.parametrize(
    ("params", "selections", "code"),
    [
        ({"resolution": "5m"}, [f"{ASSET_A}:ENERGY_IMPORT"], "invalid_resolution"),
        ({"phase": "per_phase"}, [f"{ASSET_A}:ENERGY_IMPORT"], "invalid_phase"),
        ({"from": TO, "to": FROM}, [f"{ASSET_A}:ENERGY_IMPORT"], "invalid_time_range"),
        ({"from": "yesterday"}, [f"{ASSET_A}:ENERGY_IMPORT"], "invalid_time_range"),
        ({"resolution": "1m", "to": "2026-09-23T00:00:01Z"}, [f"{ASSET_A}:ENERGY_IMPORT"], "time_range_too_large"),
        ({"resolution": "15m", "to": "2026-10-20T00:00:01Z"}, [f"{ASSET_A}:ENERGY_IMPORT"], "time_range_too_large"),
        ({}, [], "invalid_selection"),
        ({}, ["not-a-pair"], "invalid_selection"),
        ({}, [f"{ASSET_A}ENERGY_IMPORT"], "invalid_selection"),
        ({}, ["zzz:ENERGY_IMPORT"], "invalid_selection"),
        ({}, [f"{ASSET_A}:"], "invalid_selection"),
        ({}, [f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_A}:ENERGY_IMPORT"], "duplicate_selection"),
    ],
)
def test_contract_errors(portal_client, monkeypatch, params, selections, code) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch)
    response = _series(portal_client, *selections, **params)
    assert response.status_code == 422
    assert response.json()["error"] == code


def test_too_many_assets(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch)
    selections = [f"{i:08x}-0000-4000-8000-000000000000:ENERGY_IMPORT" for i in range(11)]
    response = _series(portal_client, *selections)
    assert response.status_code == 422
    assert response.json()["error"] == "too_many_assets"


def test_ten_assets_two_points_is_within_limits(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, catalog=[])
    selections = [
        f"{i:08x}-0000-4000-8000-000000000000:{point}"
        for i in range(10) for point in ("ENERGY_IMPORT", "ENERGY_EXPORT")
    ]
    response = _series(portal_client, *selections)
    assert response.status_code == 200
    assert len(response.json()["series"]) == 20


def test_unavailable_selections_are_not_available_and_not_read(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1), _energy_row(ASSET_A, 1, 2.0, 0.2)])
    response = _series(
        portal_client, f"{ASSET_X}:ENERGY_IMPORT", f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_B}:ENERGY_EXPORT",
    )
    assert response.status_code == 200
    series = response.json()["series"]
    assert [(s["asset_id"], s["data_point"], s["status"]) for s in series] == [
        (ASSET_X, "ENERGY_IMPORT", "NOT_AVAILABLE"),
        (ASSET_A, "ENERGY_IMPORT", "OK"),
        (ASSET_B, "ENERGY_EXPORT", "NOT_AVAILABLE"),   # AHU 2 has no Export assignment
    ]
    assert series[0]["points"] == [] and series[0]["asset_name"] is None
    assert series[0]["status_reasons"] == []
    assert _energy_calls(calls) == [("energy", (ASSET_A,), "1h", AS_OF)]


def test_no_energy_read_when_nothing_is_available(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch)
    response = _series(portal_client, f"{ASSET_X}:ENERGY_IMPORT")
    assert response.status_code == 200
    assert _energy_calls(calls) == []
    assert response.json()["as_of"] == "2026-09-28T12:00:00Z"


def test_one_as_of_is_read_once_and_passed_to_every_read(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()
    assert calls.count("as_of") == 1
    assert ("floors", AS_OF) in calls
    assert _energy_calls(calls) == [("energy", (ASSET_A,), "1h", AS_OF)]
    assert body["as_of"] == "2026-09-28T12:00:00Z"


def test_energy_series_values_evidence_counts_and_summary(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[
        _energy_row(ASSET_A, 0, 1.5, 0.2, imp_n=60, exp_n=30),
        _energy_row(ASSET_A, 1, 4.5, None, imp_n=44, exp_n=0,
                    imp_kw={"invalid": 1, "gap": 2, "status": "INVALID_INTERVALS", "assigned_expected": 60}),
    ])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_A}:ENERGY_EXPORT")
    body = response.json()
    imp, exp = body["series"]

    assert (imp["label"], imp["unit"], imp["chart_kind"], imp["aggregation"], imp["qualifier"]) == (
        "Energy", "kWh", "bar", "sum", "TOTAL",
    )
    assert exp["label"] == "Energy Export"
    assert [p["value"] for p in imp["points"]] == [1.5, 4.5]
    assert [p["valid_intervals"] for p in imp["points"]] == [60, 44]
    assert [p["invalid_intervals"] for p in imp["points"]] == [0, 1]
    assert [p["assigned_expected_intervals"] for p in imp["points"]] == [60, 60]
    assert [p["expected_intervals"] for p in imp["points"]] == [60, 60]
    # Every condition present, not only the worst; evidence_status kept for compatibility.
    assert [p["evidence_flags"] for p in imp["points"]] == [[], ["INVALID_INTERVALS", "GAPS_DETECTED"]]
    assert [p["evidence_status"] for p in imp["points"]] == ["GOOD", "INVALID_INTERVALS"]
    assert [p["bucket_state"] for p in imp["points"]] == ["COMPLETE", "COMPLETE"]
    assert [p["is_partial"] for p in imp["points"]] == [False, False]
    assert {(p["min"], p["max"], p["quality"]) for p in imp["points"]} == {(None, None, None)}
    assert imp["summary"] == {
        "total": 6.0, "average": 3.0, "min": 1.5, "min_at": "2026-09-20T00:00:00Z",
        "max": 4.5, "max_at": "2026-09-20T01:00:00Z",
    }
    assert imp["stale"] is False and imp["status_reasons"] == []

    assert [p["value"] for p in exp["points"]] == [0.2, None]
    assert [p["data_state"] for p in exp["points"]] == ["MEASURED", "GAP"]
    assert [p["evidence_status"] for p in exp["points"]] == ["GOOD", None]
    assert exp["summary"]["total"] == pytest.approx(0.2)


def test_coverage_ratio_is_not_in_the_response(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT")
    assert "coverage_ratio" not in response.text


def test_bucket_state_follows_as_of(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    as_of = T0 + timedelta(minutes=90)
    rows = [_energy_row(ASSET_A, h, v, None) for h, v in ((0, 1.0), (1, 0.5), (2, None))]
    rows[2]["import_data_state"] = "FUTURE"
    _patch(monkeypatch, energy=rows, as_of=as_of)
    points = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", to="2026-09-20T03:00:00Z").json()["series"][0]["points"]
    assert [p["bucket_state"] for p in points] == ["COMPLETE", "IN_PROGRESS", "FUTURE"]
    assert [p["is_partial"] for p in points] == [False, True, True]
    assert points[2]["data_state"] == "FUTURE"


def test_summary_average_min_max_use_completed_periods_only(portal_client, monkeypatch) -> None:
    # The in-progress hour (0.5 kWh so far) counts toward Total but is never
    # the minimum and does not lower the average; the future hour is ignored.
    _login(portal_client, monkeypatch)
    as_of = T0 + timedelta(minutes=150)
    rows = [_energy_row(ASSET_A, h, v, None) for h, v in ((0, 1.0), (1, 3.0), (2, 0.5), (3, None))]
    rows[3]["import_data_state"] = "FUTURE"
    _patch(monkeypatch, energy=rows, as_of=as_of)
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", to="2026-09-20T04:00:00Z").json()["series"][0]
    assert [p["bucket_state"] for p in series["points"]] == ["COMPLETE", "COMPLETE", "IN_PROGRESS", "FUTURE"]
    assert series["summary"] == {
        "total": 4.5, "average": 2.0, "min": 1.0, "min_at": "2026-09-20T00:00:00Z",
        "max": 3.0, "max_at": "2026-09-20T01:00:00Z",
    }


def test_summary_with_only_an_in_progress_period_has_a_total_and_nothing_else(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    as_of = T0 + timedelta(minutes=30)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 0.4, None)], as_of=as_of)
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", to="2026-09-20T01:00:00Z").json()["series"][0]
    assert series["status"] == "OK"
    assert series["points"][0]["bucket_state"] == "IN_PROGRESS"
    assert series["summary"] == {"total": 0.4, "average": None, "min": None, "min_at": None, "max": None, "max_at": None}


def test_stale_and_data_bounds_are_passed_through(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    last = T0 + timedelta(minutes=70)
    fields = _series_fields(first=T0 - timedelta(days=2), last=last, stale=True)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1, series=fields),
                                _energy_row(ASSET_A, 1, 0.2, 0.0, series=fields)])
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()["series"][0]
    assert (series["status"], series["stale"]) == ("OK", True)
    assert series["first_data_at"] == "2026-09-18T00:00:00Z"
    assert series["last_data_at"] == "2026-09-20T01:10:00Z"
    assert "threshold" not in str(series) and "schedule" not in str(series)


# ---------------------------------------------------------------------------
# NO_DATA reasons and unavailability
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("fields", "range_", "reason"),
    [
        ({"in_range": False}, (FROM, TO), "NOT_ASSIGNED_IN_RANGE"),
        ({"first": None, "last": None}, (FROM, TO), "NO_DATA_EVER"),
        ({}, ("2026-09-29T00:00:00Z", "2026-09-29T02:00:00Z"), "RANGE_IN_FUTURE"),
        ({"first": T0 + timedelta(hours=5)}, (FROM, TO), "RANGE_BEFORE_DATA"),
        ({"first": T0 - timedelta(days=9), "last": T0 - timedelta(days=1)}, (FROM, TO), "RANGE_AFTER_LATEST_DATA"),
        ({"first": T0 - timedelta(days=9), "last": AS_OF - timedelta(minutes=2)}, (FROM, TO), "NO_DATA_IN_RANGE"),
    ],
)
def test_no_data_reasons(portal_client, monkeypatch, fields, range_, reason) -> None:
    _login(portal_client, monkeypatch)
    series_fields = _series_fields(**fields)
    _patch(monkeypatch, energy=[
        _energy_row(ASSET_A, 0, None, None, imp_n=0, exp_n=0, series=series_fields),
        _energy_row(ASSET_A, 1, None, None, imp_n=0, exp_n=0, series=series_fields),
    ])
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", **{"from": range_[0], "to": range_[1]}).json()["series"][0]
    assert series["status"] == "NO_DATA"
    assert series["status_reasons"] == [reason]
    assert len(series["points"]) == 2
    assert series["summary"]["total"] is None


@pytest.mark.parametrize(
    ("reasons", "status"),
    [
        (["BEFORE_RETENTION_FLOOR"], "RESOLUTION_UNAVAILABLE"),
        (["CAPTURE_INTERVAL_TOO_COARSE"], "RESOLUTION_UNAVAILABLE"),
        (["CAPTURE_POLICY_CHANGE"], "DATA_UNAVAILABLE"),
        (["CAPTURE_POLICY_GAP"], "DATA_UNAVAILABLE"),
        (["CAPTURE_POLICY_GAP", "CAPTURE_POLICY_CHANGE"], "DATA_UNAVAILABLE"),
        (["TIMEZONE_MISMATCH"], "DATA_UNAVAILABLE"),
    ],
)
def test_unavailable_reasons_map_to_statuses_and_are_all_returned(portal_client, monkeypatch, reasons, status) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_marker(ASSET_A, *reasons)])
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()["series"][0]
    assert series["status"] == status
    assert series["status_reasons"] == reasons
    assert series["points"] == []


def test_three_phase_on_a_system_only_point_returns_the_system_series(portal_client, monkeypatch) -> None:
    """3-phase fallback is phase = three_phase with qualifier TOTAL; no
    separate fallback field (Data Quality decision 14)."""

    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", phase="three_phase").json()
    assert body["phase"] == "three_phase"
    assert [(s["qualifier"], s["status"]) for s in body["series"]] == [("TOTAL", "OK")]
    assert "phase_fallback" not in body["series"][0]


def test_response_shape_is_stable(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", resolution=None)
    body = response.json()
    assert set(body) == {"site_id", "site_timezone", "as_of", "from", "to", "requested_resolution",
                         "resolution", "phase", "series"}
    assert (body["requested_resolution"], body["resolution"], body["phase"]) == ("auto", "15m", "system")
    assert set(body["series"][0]) == {"asset_id", "asset_name", "data_point", "label", "qualifier", "unit",
                                      "chart_kind", "aggregation", "status", "status_reasons",
                                      "resolution_available_from", "first_data_at", "last_data_at", "stale",
                                      "points", "summary"}
    assert set(body["series"][0]["points"][0]) == {
        "bucket_start", "bucket_end", "value", "min", "max", "bucket_state", "data_state",
        "expected_intervals", "assigned_expected_intervals", "valid_intervals", "invalid_intervals",
        "reconstructed_intervals", "evidence_flags", "evidence_status", "quality", "is_partial"}
    assert set(body["series"][0]["summary"]) == {"total", "average", "min", "min_at", "max", "max_at"}
    assert "attribution_basis" not in response.text and "PARITY_BRIDGE" not in response.text


def test_series_is_get_only(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch)
    assert portal_client.post(f"/api/v1/sites/{SITE_ID}/analytics/series").status_code == 405


# ---------------------------------------------------------------------------
# Request validation (no HTTP)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("days", "expected"),
    [(0.5, "15m"), (4.99, "15m"), (5, "1h"), (29.9, "1h"), (30, "1d"), (400, "1d")],
)
def test_auto_resolution_follows_adr_019(days, expected) -> None:
    assert resolve_auto_resolution(timedelta(days=days)) == expected


def test_auto_resolution_is_bounded_by_the_resolved_window() -> None:
    request = parse_series_request(
        range_from="2020-01-01T00:00:00Z", range_to="2022-12-31T00:00:00Z",
        resolution=None, phase=None, selections=[f"{ASSET_A}:ENERGY_IMPORT"],
    )
    assert request.resolution == "1d"
    with pytest.raises(ApiContractError) as excinfo:
        parse_series_request(
            range_from="2020-01-01T00:00:00Z", range_to="2023-01-02T00:00:00Z",
            resolution=None, phase=None, selections=[f"{ASSET_A}:ENERGY_IMPORT"],
        )
    assert excinfo.value.code == "time_range_too_large"


def test_limits_on_data_points_and_expanded_series(monkeypatch) -> None:
    """The v1 registry cannot reach these limits; exercise them with a
    wider registry so they are enforced before non-Energy points arrive."""

    fake = {f"POINT_{i}": DataPointDefinition("line", "mean", ("TOTAL", "L1", "L2", "L3")) for i in range(6)}
    monkeypatch.setattr(trends, "ANALYTICS_DATA_POINTS", fake)
    base = dict(range_from=FROM, range_to=TO, resolution="1h")

    with pytest.raises(ApiContractError) as excinfo:
        parse_series_request(**base, phase="system", selections=[f"{ASSET_A}:POINT_{i}" for i in range(6)])
    assert excinfo.value.code == "too_many_data_points"

    nine = [f"{i:08x}-0000-4000-8000-000000000000:POINT_0" for i in range(9)]
    assert parse_series_request(**base, phase="system", selections=nine).phase == "system"
    with pytest.raises(ApiContractError) as excinfo:
        parse_series_request(**base, phase="three_phase", selections=nine)   # 27 series
    assert excinfo.value.code == "too_many_series"


def _request(resolution: str, requested: str = "auto", start=T0) -> SeriesRequest:
    return SeriesRequest(dt_from=start, dt_to=start + timedelta(days=1), requested_resolution=requested,
                         resolution=resolution, phase="system",
                         selections=(Selection(asset_id=ASSET_A, data_point="ENERGY_IMPORT"),))


@pytest.mark.parametrize(
    ("resolution", "floors", "expected"),
    [
        ("15m", NO_FLOORS, "15m"),
        ("15m", {**NO_FLOORS, "15m": T0 + timedelta(minutes=1)}, "1h"),
        ("15m", {**NO_FLOORS, "15m": T0 + timedelta(minutes=1), "1h": T0 + timedelta(minutes=1)}, "1d"),
        ("1h", {**NO_FLOORS, "1h": T0 + timedelta(minutes=1)}, "1d"),
        # Even 1d cannot serve it: Auto stays on 1d (reported as RESOLUTION_UNAVAILABLE).
        ("1h", {**NO_FLOORS, "1h": T0 + timedelta(minutes=1), "1d": T0 + timedelta(minutes=1)}, "1d"),
    ],
)
def test_auto_is_floor_aware(resolution, floors, expected) -> None:
    assert apply_floor_aware_auto(_request(resolution), floors).resolution == expected


def test_an_explicit_resolution_is_never_changed_by_the_floors() -> None:
    floors = {**NO_FLOORS, "1h": T0 + timedelta(minutes=1)}
    assert apply_floor_aware_auto(_request("1h", requested="1h"), floors).resolution == "1h"


# ---------------------------------------------------------------------------
# Retention floors (migrations 280 / 282)
# ---------------------------------------------------------------------------


def test_request_before_the_resolution_retention_floor_is_resolution_unavailable(portal_client, monkeypatch) -> None:
    """An explicit resolution starting before its retention floor is
    RESOLUTION_UNAVAILABLE with the floor -- and the Energy tiers are not read."""

    _login(portal_client, monkeypatch)
    floor = T0 + timedelta(minutes=1)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)], floors={**NO_FLOORS, "1h": floor})
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_X}:ENERGY_IMPORT")
    assert response.status_code == 200
    series = response.json()["series"]
    assert [(s["asset_id"], s["status"]) for s in series] == [
        (ASSET_A, "RESOLUTION_UNAVAILABLE"),
        (ASSET_X, "NOT_AVAILABLE"),
    ]
    assert series[0]["status_reasons"] == ["BEFORE_RETENTION_FLOOR"]
    assert series[0]["resolution_available_from"] == "2026-09-20T00:01:00Z"
    assert series[0]["points"] == [] and series[0]["label"] == "Energy"
    assert ("floors", AS_OF) in calls
    assert _energy_calls(calls) == []


def test_request_at_or_after_the_floor_is_served(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)], floors={**NO_FLOORS, "1h": T0})
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()["series"][0]
    assert series["status"] == "OK"
    assert _energy_calls(calls) == [("energy", (ASSET_A,), "1h", AS_OF)]


def test_auto_before_its_floor_is_served_at_a_coarser_resolution(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)],
                   floors={**NO_FLOORS, "15m": T0 + timedelta(minutes=1)})
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", resolution=None).json()
    assert (body["requested_resolution"], body["resolution"]) == ("auto", "1h")
    assert body["series"][0]["status"] == "OK"
    assert _energy_calls(calls) == [("energy", (ASSET_A,), "1h", AS_OF)]


def test_floors_are_not_read_when_nothing_is_available(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch)
    assert _series(portal_client, f"{ASSET_X}:ENERGY_IMPORT").status_code == 200
    assert not any(isinstance(c, tuple) and c[0] == "floors" for c in calls)


# ---------------------------------------------------------------------------
# B3: measurements and per-phase Energy (migration 292 reads mocked)
# ---------------------------------------------------------------------------


def _measure_row(asset_id, code, qualifier, name, unit, *, cat_qualifier=None) -> dict:
    row = _catalog_row(asset_id, name, code, qualifier if cat_qualifier is None else cat_qualifier)
    row.update({"data_point_name": code.replace("_", " ").title(), "category": "Power", "unit": unit})
    return row


B3_CATALOG = CATALOG + [
    *(_catalog_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT", q) for q in ("L1", "L2", "L3")),
    *(_measure_row(ASSET_A, "ACTIVE_POWER", q, "Chiller 1", "kW") for q in ("TOTAL", "L1", "L2", "L3")),
    *(_measure_row(ASSET_A, "VOLTAGE_LINE_LINE", q, "Chiller 1", "V") for q in ("AVG", "L12", "L23", "L31")),
    _measure_row(ASSET_A, "FREQUENCY", None, "Chiller 1", "Hz"),
    _measure_row(ASSET_B, "ACTIVE_POWER", "TOTAL", "AHU 2", "kW"),
]


def _point_rows(index, *, values=(12.5, None), quality=("GOOD", "GAP"), reasons=None, kind="mean", start=T0) -> list[dict]:
    if reasons:
        return [{"series_index": index, "bucket_start": None, "bucket_end": None, "unavailable_reasons": reasons,
                 "source_kind": kind}]
    rows = []
    for i, value in enumerate(values):
        s = start + timedelta(hours=i)
        rows.append({
            "series_index": index, "source_kind": kind, "bucket_start": s, "bucket_end": s + timedelta(hours=1),
            "value": None if value is None else Decimal(str(value)),
            "min_value": None if value is None else Decimal(str(value - 1)),
            "max_value": None if value is None else Decimal(str(value + 1)),
            "valid_intervals": 60 if value is not None else 0, "invalid_intervals": 0, "gap_intervals": 0,
            "reset_intervals": 0, "rollover_intervals": 0, "expected_intervals": 60,
            "assigned_expected_intervals": 60, "data_state": "MEASURED" if value is not None else "GAP",
            "quality": quality[i] if kind == "mean" else None, "unavailable_reasons": [],
            "first_data_at": T0 - timedelta(days=1), "last_data_at": AS_OF - timedelta(minutes=1),
            "assigned_in_range": True,
        })
    return rows


def _points_by_spec(rows_for):
    """Return rows for each requested spec index via rows_for(index, spec)."""

    def fetch(specs, resolution):
        out = []
        for i, spec in enumerate(specs, start=1):
            out += rows_for(i, spec)
        return out

    return fetch


def _point_calls(calls):
    return [c for c in calls if isinstance(c, tuple) and c[0] == "points"]


def test_measurement_system_series_is_a_mean_line_without_total(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG, points=_points_by_spec(lambda i, s: _point_rows(i)))
    body = _series(portal_client, f"{ASSET_A}:ACTIVE_POWER").json()
    s = body["series"][0]
    assert (s["status"], s["qualifier"], s["chart_kind"], s["aggregation"], s["unit"], s["label"]) == (
        "OK", "TOTAL", "line", "mean", "kW", "Power")
    assert [(p["value"], p["min"], p["max"], p["quality"], p["evidence_status"]) for p in s["points"]] == [
        (12.5, 11.5, 13.5, "GOOD", None), (None, None, None, "GAP", None)]
    assert s["summary"]["total"] is None and s["summary"]["average"] == 12.5
    assert s["stale"] is None
    assert _point_calls(calls) == [("points", ((ASSET_A, "ACTIVE_POWER", "TOTAL"),), "1h")]
    assert _energy_calls(calls) == []


def test_avg_and_unqualified_system_points_are_reported_as_total(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG, points=_points_by_spec(lambda i, s: _point_rows(i)))
    body = _series(portal_client, f"{ASSET_A}:VOLTAGE_LINE_LINE", f"{ASSET_A}:FREQUENCY").json()
    assert [(s["data_point"], s["qualifier"], s["status"]) for s in body["series"]] == [
        ("VOLTAGE_LINE_LINE", "TOTAL", "OK"), ("FREQUENCY", "TOTAL", "OK")]
    assert _point_calls(calls) == [("points", ((ASSET_A, "VOLTAGE_LINE_LINE", "AVG"), (ASSET_A, "FREQUENCY", None)), "1h")]


def test_three_phase_expands_where_every_phase_is_assigned(portal_client, monkeypatch) -> None:
    """Chiller 1 has P1-P3 and V12/V23/V31; AHU 2 has only System power (the
    fallback); Frequency has no phases (System)."""

    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG, points=_points_by_spec(lambda i, s: _point_rows(i)))
    body = _series(
        portal_client, f"{ASSET_A}:ACTIVE_POWER", f"{ASSET_B}:ACTIVE_POWER", f"{ASSET_A}:VOLTAGE_LINE_LINE",
        f"{ASSET_A}:FREQUENCY", phase="three_phase",
    ).json()
    assert [(s["asset_id"], s["data_point"], s["qualifier"]) for s in body["series"]] == [
        (ASSET_A, "ACTIVE_POWER", "L1"), (ASSET_A, "ACTIVE_POWER", "L2"), (ASSET_A, "ACTIVE_POWER", "L3"),
        (ASSET_B, "ACTIVE_POWER", "TOTAL"),
        (ASSET_A, "VOLTAGE_LINE_LINE", "L12"), (ASSET_A, "VOLTAGE_LINE_LINE", "L23"), (ASSET_A, "VOLTAGE_LINE_LINE", "L31"),
        (ASSET_A, "FREQUENCY", "TOTAL"),
    ]
    assert {s["status"] for s in body["series"]} == {"OK"}
    specs = _point_calls(calls)[0][1]
    assert specs[3] == (ASSET_B, "ACTIVE_POWER", "TOTAL") and specs[7] == (ASSET_A, "FREQUENCY", None)


def test_per_phase_energy_reads_the_register_tier_from_15m(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG,
                   points=_points_by_spec(lambda i, s: _point_rows(i, values=(1.5, 2.0), kind="delta")))
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", phase="three_phase").json()
    assert [(s["qualifier"], s["chart_kind"], s["aggregation"], s["summary"]["total"]) for s in body["series"]] == [
        ("L1", "bar", "sum", 3.5), ("L2", "bar", "sum", 3.5), ("L3", "bar", "sum", 3.5)]
    point = body["series"][0]["points"][0]
    assert (point["min"], point["max"], point["quality"], point["evidence_status"]) == (None, None, None, "GOOD")
    assert _energy_calls(calls) == []


def test_per_phase_energy_at_1m_falls_back_to_system_energy(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", phase="three_phase", resolution="1m",
                   to="2026-09-20T01:00:00Z").json()
    assert [s["qualifier"] for s in body["series"]] == ["TOTAL"]
    assert _point_calls(calls) == []
    assert [c[0] for c in _energy_calls(calls)] == ["energy"]


def test_a_point_series_the_database_did_not_return_is_not_available(portal_client, monkeypatch) -> None:
    """No rows for a spec (e.g. an asset the user cannot access) is
    NOT_AVAILABLE, indistinguishable from an unknown asset."""

    _login(portal_client, monkeypatch)
    _patch(monkeypatch, catalog=B3_CATALOG,
           points=_points_by_spec(lambda i, s: [] if s.asset_id.hex.startswith("bbbb") else _point_rows(i)))
    body = _series(portal_client, f"{ASSET_A}:ACTIVE_POWER", f"{ASSET_B}:ACTIVE_POWER").json()
    assert [(s["asset_id"], s["status"], s["asset_name"]) for s in body["series"]] == [
        (ASSET_A, "OK", "Chiller 1"), (ASSET_B, "NOT_AVAILABLE", None)]


def test_measurement_no_data_and_retention_floor_statuses(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    floor = T0 + timedelta(days=1)

    def rows(i, spec):
        if spec.data_point == "FREQUENCY":
            return _point_rows(i, reasons=["BEFORE_RETENTION_FLOOR"])
        empty = _point_rows(i, values=(None,), quality=("GAP",))
        for r in empty:
            r.update(first_data_at=None, last_data_at=None)
        return empty

    _patch(monkeypatch, catalog=B3_CATALOG, points=_points_by_spec(rows),
           point_floors={"mean": {**NO_FLOORS, "1h": floor}, "delta": dict(NO_FLOORS)})
    body = _series(portal_client, f"{ASSET_A}:ACTIVE_POWER", f"{ASSET_A}:FREQUENCY").json()
    power, frequency = body["series"]
    assert (power["status"], power["status_reasons"]) == ("NO_DATA", ["NO_DATA_EVER"])
    assert (frequency["status"], frequency["status_reasons"]) == ("RESOLUTION_UNAVAILABLE", ["BEFORE_RETENTION_FLOOR"])
    assert frequency["resolution_available_from"] == "2026-09-21T00:00:00Z"


def test_auto_respects_the_latest_floor_across_sources(portal_client, monkeypatch) -> None:
    """Energy could serve 15m, but the measurement source cannot: Auto picks
    a resolution both can serve."""

    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)],
                   points=_points_by_spec(lambda i, s: _point_rows(i)),
                   point_floors={"mean": {**NO_FLOORS, "15m": T0 + timedelta(minutes=1)}, "delta": dict(NO_FLOORS)})
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_A}:ACTIVE_POWER", resolution=None).json()
    assert (body["requested_resolution"], body["resolution"]) == ("auto", "1h")
    assert _energy_calls(calls)[0][2] == "1h" and _point_calls(calls)[0][2] == "1h"


def test_series_limit_counts_registry_phases(portal_client, monkeypatch) -> None:
    """3 Phase counts three series per phased data point before any read."""

    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, catalog=B3_CATALOG)
    assets = [f"{i:08x}-aaaa-4aaa-8aaa-aaaaaaaaaaaa" for i in range(1, 10)]
    response = _series(portal_client, *(f"{a}:ACTIVE_POWER" for a in assets), phase="three_phase")
    assert response.status_code == 422 and response.json()["error"] == "too_many_series"   # 27 > 25
    assert calls == []
