"""Analytics v1 (ADR-022, step B1) -- GET /api/v1/sites/{site_id}/analytics/catalog
route contract and response building.

Every route test monkeypatches the two data-access functions the route
uses (fetch_analytics_site / fetch_analytics_catalog, backed by
admin.list_accessible_sites and analytics.get_portal_analytics_catalog --
migration 276), mirroring test_analytics_api_v1_energy_availability_routes.py.
The database behaviour of the catalogue read is covered separately by
test_analytics_catalog_read.py.
"""

from __future__ import annotations

import pytest

from src.analytics_trends_service import (
    ANALYTICS_DATA_POINTS,
    MAX_ASSETS,
    MAX_DATA_POINTS,
    MAX_SERIES,
    build_analytics_catalog_response,
)
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


SITE_ID = "22222222-2222-4222-8222-222222222222"
OTHER_SITE_ID = "33333333-3333-4333-8333-333333333333"
ASSET_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ASSET_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
ASSET_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
SITE = {"site_id": SITE_ID, "site_name": "Coimbatore", "timezone": "Asia/Kolkata"}


def _row(asset_id: str, asset_name: str, data_point: str, qualifier: str = "TOTAL", **extra) -> dict:
    labels = {
        "ENERGY_IMPORT": "Active Energy Import",
        "ENERGY_EXPORT": "Active Energy Export",
        "CURRENT": "Current",
    }
    row = {
        "asset_id": asset_id,
        "asset_name": asset_name,
        "asset_type_id": None,
        "asset_type_name": "AHU",
        "building_name": "Main",
        "floor_name": "Ground",
        "space_id": None,
        "space_name": "Plant Room",
        "location_path": "Main / Ground / Plant Room",
        "data_point": data_point,
        "data_point_name": labels.get(data_point, data_point),
        "category": "Current" if data_point == "CURRENT" else "Energy",
        "unit": "A" if data_point == "CURRENT" else "kWh",
        "qualifier": qualifier,
    }
    row.update(extra)
    return row


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


def _patch(monkeypatch, *, allowed=True, site=SITE, rows=None, calls=None, availability=None, floors=None):
    async def access(portal_user_id, site_id):
        return allowed(site_id) if callable(allowed) else allowed

    async def fetch_site(portal_user_id, site_id):
        if calls is not None:
            calls.append("site")
        return site

    async def fetch_catalog(portal_user_id, site_id):
        if calls is not None:
            calls.append("catalog")
        return rows if rows is not None else []

    async def fetch_availability(portal_user_id, site_id):
        if calls is not None:
            calls.append("availability")
        return availability if availability is not None else []

    monkeypatch.setattr("src.routers.analytics_api.portal_user_can_access_site", access)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_site", fetch_site)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_catalog", fetch_catalog)
    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_availability", fetch_availability)

    async def fetch_floors(site_id, as_of=None):
        if calls is not None:
            calls.append("floors")
        return floors if floors is not None else {r: None for r in ("1m", "15m", "30m", "1h", "1d")}

    monkeypatch.setattr("src.routers.analytics_api.fetch_analytics_energy_resolution_floors", fetch_floors)


def _catalog(portal_client, site_id: str = SITE_ID):
    return portal_client.get(f"/api/v1/sites/{site_id}/analytics/catalog")


# ---------------------------------------------------------------------------
# Route contract
# ---------------------------------------------------------------------------


def test_catalog_requires_authentication(portal_client) -> None:
    assert _catalog(portal_client).status_code == 401


def test_catalog_inaccessible_site_is_404_without_reading(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    calls: list[str] = []
    _patch(monkeypatch, allowed=False, calls=calls)

    response = _catalog(portal_client)
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"
    assert calls == []


def test_catalog_tenant_isolation(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, allowed=lambda site_id: str(site_id) == SITE_ID)

    assert _catalog(portal_client, SITE_ID).status_code == 200
    assert _catalog(portal_client, OTHER_SITE_ID).status_code == 404


def test_catalog_returns_energy_pilot_shape(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, rows=[
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT"),
        _row(ASSET_A, "Chiller 1", "ENERGY_EXPORT"),
    ])

    response = _catalog(portal_client)
    assert response.status_code == 200
    body = response.json()
    assert body["site_id"] == SITE_ID
    assert body["site_name"] == "Coimbatore"
    assert body["site_timezone"] == "Asia/Kolkata"
    assert body["limits"] == {"max_data_points": 5, "max_assets": 10, "max_series": 25}
    assert [a["asset_name"] for a in body["assets"]] == ["Chiller 1"]
    points = body["assets"][0]["data_points"]
    assert [p["data_point"] for p in points] == ["ENERGY_IMPORT", "ENERGY_EXPORT"]
    assert points[0] == {
        "data_point": "ENERGY_IMPORT",
        # Customer label from the registry (D73), not the parameter name.
        "label": "Energy",
        "category": "Energy",
        "unit": "kWh",
        "chart_kind": "bar",
        "aggregation": "sum",
        "phases": {"system": True, "three_phase": False},
        "available_from": None,
        "available_to": None,
    }


def test_catalog_never_exposes_attribution_basis(portal_client, monkeypatch) -> None:
    """Parity-bridge status is internal read-model metadata only (ADR-022
    decision 4) -- even if a row carried it, the response must not."""

    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, rows=[_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT", attribution_basis="PARITY_BRIDGE")])

    text = _catalog(portal_client).text
    assert "attribution_basis" not in text
    assert "PARITY_BRIDGE" not in text
    assert "CONFIRMED" not in text


def test_catalog_field_names_are_stable_contract(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, rows=[_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT")])

    body = _catalog(portal_client).json()
    assert set(body) == {"site_id", "site_name", "site_timezone", "limits", "resolutions", "assets"}
    assert set(body["assets"][0]) == {
        "asset_id", "asset_name", "asset_type_id", "asset_type_name", "building_name",
        "floor_name", "space_id", "space_name", "location_path", "data_points",
    }
    assert set(body["resolutions"][0]) == {"resolution", "max_window_seconds", "default_window_seconds",
                                           "available_from"}


def test_catalog_accessible_site_without_assignments_is_empty_not_error(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, rows=[])

    response = _catalog(portal_client)
    assert response.status_code == 200
    assert response.json()["assets"] == []


def test_catalog_site_missing_from_accessible_sites_is_404(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch, site=None)

    assert _catalog(portal_client).status_code == 404


def test_catalog_is_get_only(portal_client, monkeypatch) -> None:
    _login_global_admin(portal_client, monkeypatch)
    _patch(monkeypatch)

    assert portal_client.post(f"/api/v1/sites/{SITE_ID}/analytics/catalog").status_code == 405


# ---------------------------------------------------------------------------
# Response building (no HTTP, no DB)
# ---------------------------------------------------------------------------


def test_registry_is_the_energy_only_pilot() -> None:
    assert set(ANALYTICS_DATA_POINTS) == {"ENERGY_IMPORT", "ENERGY_EXPORT"}
    for definition in ANALYTICS_DATA_POINTS.values():
        assert (definition.chart_kind, definition.aggregation, definition.qualifiers) == ("bar", "sum", ("TOTAL",))
    assert (MAX_DATA_POINTS, MAX_ASSETS, MAX_SERIES) == (5, 10, 25)


def test_resolutions_follow_adr_019_windows() -> None:
    response = build_analytics_catalog_response(site=SITE, rows=[])
    windows = {r.resolution: (r.max_window_seconds, r.default_window_seconds) for r in response.resolutions}
    day = 86400
    assert list(windows) == ["1m", "15m", "30m", "1h", "1d"]
    assert windows == {
        "1m": (3 * day, 36 * 3600),
        "15m": (30 * day, 15 * day),
        "30m": (60 * day, 30 * day),
        "1h": (180 * day, 90 * day),
        "1d": (1095 * day, int(547.5 * day)),
    }


def test_non_registry_parameters_are_not_offered() -> None:
    response = build_analytics_catalog_response(site=SITE, rows=[
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT"),
        _row(ASSET_A, "Chiller 1", "CURRENT", "L1"),
        _row(ASSET_B, "AHU 2", "CURRENT", "TOTAL"),
    ])
    assert [a.asset_name for a in response.assets] == ["Chiller 1"]
    assert [p.data_point for p in response.assets[0].data_points] == ["ENERGY_IMPORT"]


def test_per_phase_energy_is_not_offered_in_v1() -> None:
    """The canonical Energy read resolves only *_TOTAL points: an asset whose
    only Energy binding is per-phase has nothing chartable in v1."""

    response = build_analytics_catalog_response(site=SITE, rows=[
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT", "L1"),
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT", "L2"),
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT", "L3"),
        _row(ASSET_B, "AHU 2", "ENERGY_IMPORT", "TOTAL"),
        _row(ASSET_B, "AHU 2", "ENERGY_IMPORT", "L1"),
    ])
    assert [a.asset_name for a in response.assets] == ["AHU 2"]
    phases = response.assets[0].data_points[0].phases
    assert (phases.system, phases.three_phase) == (True, False)


def test_assets_sorted_by_name_and_points_by_registry_order() -> None:
    response = build_analytics_catalog_response(site=SITE, rows=[
        _row(ASSET_C, "boiler", "ENERGY_EXPORT"),
        _row(ASSET_B, "AHU 2", "ENERGY_EXPORT"),
        _row(ASSET_B, "AHU 2", "ENERGY_IMPORT"),
        _row(ASSET_A, "Chiller 1", "ENERGY_IMPORT"),
    ])
    assert [a.asset_name for a in response.assets] == ["AHU 2", "boiler", "Chiller 1"]
    assert [p.data_point for p in response.assets[0].data_points] == ["ENERGY_IMPORT", "ENERGY_EXPORT"]


def test_asset_fields_are_carried_for_grouping() -> None:
    response = build_analytics_catalog_response(site=SITE, rows=[_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT")])
    asset = response.assets[0]
    assert (asset.asset_type_name, asset.space_name, asset.location_path) == (
        "AHU", "Plant Room", "Main / Ground / Plant Room",
    )


def test_catalog_attaches_availability_bounds_per_data_point(portal_client, monkeypatch) -> None:
    """B1b: the date picker is bounded per data point; a point with no data
    yet reports null bounds (never a fabricated date)."""

    _login_global_admin(portal_client, monkeypatch)
    _patch(
        monkeypatch,
        rows=[_row(ASSET_A, "Chiller 1", "ENERGY_IMPORT"), _row(ASSET_A, "Chiller 1", "ENERGY_EXPORT")],
        availability=[
            {"asset_id": ASSET_A, "data_point": "ENERGY_IMPORT",
             "available_from": "2026-08-28T18:30:00Z", "available_to": "2026-09-27T10:30:00Z"},
            {"asset_id": ASSET_A, "data_point": "ENERGY_EXPORT", "available_from": None, "available_to": None},
        ],
    )

    points = _catalog(portal_client).json()["assets"][0]["data_points"]
    assert (points[0]["available_from"], points[0]["available_to"]) == (
        "2026-08-28T18:30:00Z", "2026-09-27T10:30:00Z",
    )
    assert (points[1]["available_from"], points[1]["available_to"]) == (None, None)
