"""Analytics v1 (ADR-022, step B2) -- GET /api/v1/sites/{site_id}/analytics/series
route contract, request validation and response building.

Route tests monkeypatch the data-access functions the route uses
(fetch_analytics_site, fetch_analytics_catalog, fetch_analytics_energy_series).
The database reads themselves are covered by test_analytics_energy_series_read.py.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

import src.analytics_trends_service as trends
from src.analytics_api_service import ApiContractError
from src.analytics_trends_service import (
    DataPointDefinition,
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


def _energy_row(asset_id, hour, imp, exp, *, imp_n=60, exp_n=60, expected=60,
                imp_status="GOOD", exp_status="GOOD", partial=False) -> dict:
    start = T0 + timedelta(hours=hour)
    return {
        "asset_id": asset_id, "bucket_start": start, "bucket_end": start + timedelta(hours=1),
        "import_kwh": None if imp is None else Decimal(str(imp)),
        "export_kwh": None if exp is None else Decimal(str(exp)),
        "import_status": imp_status if imp is not None else None,
        "export_status": exp_status if exp is not None else None,
        "import_intervals": imp_n, "export_intervals": exp_n, "expected_intervals": expected,
        "is_partial": partial, "unavailable_reason": None,
    }


def _marker(asset_id, reason) -> dict:
    return {
        "asset_id": asset_id, "bucket_start": None, "bucket_end": None, "import_kwh": None,
        "export_kwh": None, "import_status": None, "export_status": None, "import_intervals": None,
        "export_intervals": None, "expected_intervals": None, "is_partial": None,
        "unavailable_reason": reason,
    }


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


def _patch(monkeypatch, *, allowed=True, catalog=None, energy=None, calls=None, floors=None):
    calls = calls if calls is not None else []

    async def access(portal_user_id, site_id):
        calls.append("access")
        return allowed

    async def fetch_site(portal_user_id, site_id):
        return SITE

    async def fetch_catalog(portal_user_id, site_id):
        calls.append("catalog")
        return CATALOG if catalog is None else catalog

    async def fetch_energy(portal_user_id, site_id, asset_ids, dt_from, dt_to, resolution):
        calls.append(("energy", tuple(str(a) for a in asset_ids), resolution))
        return energy or []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", access)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_site", fetch_site)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_catalog", fetch_catalog)
    async def fetch_floors():
        calls.append("floors")
        return floors if floors is not None else {r: None for r in ("1m", "15m", "30m", "1h", "1d")}

    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_series", fetch_energy)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_resolution_floors", fetch_floors)
    return calls


def _series(portal_client, *selections, **params):
    query = {"from": FROM, "to": TO, "resolution": "1h", **params}
    query_list = [(k, v) for k, v in query.items() if v is not None]
    query_list += [("selection", s) for s in selections]
    return portal_client.get(f"/api/v1/sites/{SITE_ID}/analytics/series", params=query_list)


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
    response = _series(portal_client, f"{ASSET_A}:CURRENT")
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
    assert ("energy", (ASSET_A,), "1h") in calls


def test_no_energy_read_when_nothing_is_available(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch)
    response = _series(portal_client, f"{ASSET_X}:ENERGY_IMPORT")
    assert response.status_code == 200
    assert not any(isinstance(c, tuple) for c in calls)


def test_energy_series_values_coverage_evidence_and_summary(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[
        _energy_row(ASSET_A, 0, 1.5, 0.2, imp_n=60, exp_n=30),
        _energy_row(ASSET_A, 1, 4.5, None, imp_n=45, exp_n=0, imp_status="GAPS_DETECTED", partial=True),
    ])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_A}:ENERGY_EXPORT")
    body = response.json()
    imp, exp = body["series"]

    assert (imp["label"], imp["unit"], imp["chart_kind"], imp["aggregation"], imp["qualifier"]) == (
        "Active Energy Import", "kWh", "bar", "sum", "TOTAL",
    )
    assert [p["value"] for p in imp["points"]] == [1.5, 4.5]
    assert [p["coverage_ratio"] for p in imp["points"]] == [1.0, 0.75]
    assert [p["evidence_status"] for p in imp["points"]] == ["GOOD", "GAPS_DETECTED"]
    assert [p["is_partial"] for p in imp["points"]] == [False, True]
    assert {(p["min"], p["max"], p["quality"]) for p in imp["points"]} == {(None, None, None)}
    assert imp["summary"] == {
        "total": 6.0, "average": 3.0, "min": 1.5, "min_at": "2026-09-20T00:00:00Z",
        "max": 4.5, "max_at": "2026-09-20T01:00:00Z", "coverage_ratio": 0.875,
    }

    assert [p["value"] for p in exp["points"]] == [0.2, None]
    assert [p["evidence_status"] for p in exp["points"]] == ["GOOD", None]
    assert exp["summary"]["total"] == pytest.approx(0.2)
    assert exp["summary"]["coverage_ratio"] == 0.25


def test_all_empty_buckets_is_no_data(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[
        _energy_row(ASSET_A, 0, None, None, imp_n=0, exp_n=0),
        _energy_row(ASSET_A, 1, None, None, imp_n=0, exp_n=0),
    ])
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()["series"][0]
    assert series["status"] == "NO_DATA"
    assert len(series["points"]) == 2
    assert series["summary"]["total"] is None
    assert series["summary"]["coverage_ratio"] == 0.0


@pytest.mark.parametrize(
    ("reason", "status"),
    [
        ("RESOLUTION_UNAVAILABLE", "RESOLUTION_UNAVAILABLE"),
        ("CAPTURE_POLICY_CHANGE", "DATA_UNAVAILABLE"),
        ("NO_TENANT_MAPPING", "DATA_UNAVAILABLE"),
        ("ENERGY_READ_FAILED", "DATA_UNAVAILABLE"),
    ],
)
def test_unavailable_reasons_map_to_customer_statuses(portal_client, monkeypatch, reason, status) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_marker(ASSET_A, reason)])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT")
    series = response.json()["series"][0]
    assert series["status"] == status
    assert series["points"] == []
    assert reason not in response.text or reason == status


def test_three_phase_on_a_system_only_point_returns_the_system_series(portal_client, monkeypatch) -> None:
    """Reference mockup: under 3 phase, a point without per-phase values is
    shown as its System series."""

    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    body = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", phase="three_phase").json()
    assert body["phase"] == "three_phase"
    assert [(s["qualifier"], s["status"]) for s in body["series"]] == [("TOTAL", "OK")]


def test_response_shape_is_stable(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)])
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", resolution=None)
    body = response.json()
    assert set(body) == {"site_id", "site_timezone", "from", "to", "requested_resolution",
                         "resolution", "phase", "series"}
    assert (body["requested_resolution"], body["resolution"], body["phase"]) == ("auto", "15m", "system")
    assert set(body["series"][0]) == {"asset_id", "asset_name", "data_point", "label", "qualifier", "unit",
                                      "chart_kind", "aggregation", "status", "points", "summary"}
    assert set(body["series"][0]["points"][0]) == {"bucket_start", "bucket_end", "value", "min", "max",
                                                   "coverage_ratio", "evidence_status", "quality", "is_partial"}
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


# ---------------------------------------------------------------------------
# Retention floors (migration 280)
# ---------------------------------------------------------------------------


def test_request_before_the_resolution_retention_floor_is_resolution_unavailable(portal_client, monkeypatch) -> None:
    """A request starting before its resolution's Energy tier retention floor
    is RESOLUTION_UNAVAILABLE -- and the Energy tiers are not read."""

    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)],
                   floors={"1m": None, "15m": None, "30m": None, "1d": None,
                           "1h": T0 + timedelta(minutes=1)})
    response = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT", f"{ASSET_X}:ENERGY_IMPORT")
    assert response.status_code == 200
    series = response.json()["series"]
    assert [(s["asset_id"], s["status"]) for s in series] == [
        (ASSET_A, "RESOLUTION_UNAVAILABLE"),
        (ASSET_X, "NOT_AVAILABLE"),
    ]
    assert series[0]["points"] == [] and series[0]["label"] == "Active Energy Import"
    assert "floors" in calls
    assert not any(isinstance(c, tuple) for c in calls)


def test_request_at_or_after_the_floor_is_served(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch, energy=[_energy_row(ASSET_A, 0, 1.0, 0.1)],
                   floors={"1m": None, "15m": None, "30m": None, "1d": None, "1h": T0})
    series = _series(portal_client, f"{ASSET_A}:ENERGY_IMPORT").json()["series"][0]
    assert series["status"] == "OK"
    assert ("energy", (ASSET_A,), "1h") in calls


def test_floors_are_not_read_when_nothing_is_available(portal_client, monkeypatch) -> None:
    _login(portal_client, monkeypatch)
    calls = _patch(monkeypatch)
    assert _series(portal_client, f"{ASSET_X}:ENERGY_IMPORT").status_code == 200
    assert "floors" not in calls
