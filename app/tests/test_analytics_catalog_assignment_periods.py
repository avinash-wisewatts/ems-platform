"""Catalogue response assignment periods (migration 288) -- the pure builder.

The catalogue read returns one row per asset x parameter x qualifier x
assignment period; the API merges them into each data point's
assignment_periods, in time order, with null for an unbounded end.
"""

from datetime import datetime, timezone

from src.analytics_trends_service import build_analytics_catalog_response

UTC = timezone.utc
SITE = {"site_id": "00000000-0000-0000-0000-0000000000a1", "site_name": "Site", "timezone": "Asia/Kolkata"}
ASSET = "00000000-0000-0000-0000-0000000000b1"


def _row(data_point, qualifier, assigned_from, assigned_to, *, asset=ASSET, name="Chiller"):
    return {
        "asset_id": asset, "asset_name": name, "asset_type_id": None, "asset_type_name": None,
        "building_name": None, "floor_name": None, "space_id": None, "space_name": None, "location_path": None,
        "data_point": data_point, "data_point_name": "Active Energy Import", "category": "Energy", "unit": "kWh",
        "qualifier": qualifier, "assigned_from": assigned_from, "assigned_to": assigned_to,
    }


def _periods(response, data_point="ENERGY_IMPORT"):
    point = next(p for p in response.assets[0].data_points if p.data_point == data_point)
    return [(p.assigned_from, p.assigned_to) for p in point.assignment_periods]


def test_each_period_is_listed_in_time_order_with_null_unbounded_ends():
    late = datetime(2026, 9, 20, tzinfo=UTC)
    early = (datetime(2026, 9, 1, tzinfo=UTC), datetime(2026, 9, 5, tzinfo=UTC))
    response = build_analytics_catalog_response(
        site=SITE, rows=[_row("ENERGY_IMPORT", "TOTAL", late, None), _row("ENERGY_IMPORT", "TOTAL", *early)]
    )
    assert _periods(response) == [early, (late, None)]


def test_overlapping_or_touching_periods_are_one():
    a = datetime(2026, 9, 1, tzinfo=UTC)
    b = datetime(2026, 9, 5, tzinfo=UTC)
    c = datetime(2026, 9, 9, tzinfo=UTC)
    response = build_analytics_catalog_response(
        site=SITE,
        rows=[_row("ENERGY_IMPORT", "TOTAL", a, b), _row("ENERGY_IMPORT", "TOTAL", b, c), _row("ENERGY_IMPORT", "TOTAL", a, b)],
    )
    assert _periods(response) == [(a, c)]


def test_an_unbounded_period_absorbs_any_other():
    a = datetime(2026, 9, 1, tzinfo=UTC)
    response = build_analytics_catalog_response(
        site=SITE, rows=[_row("ENERGY_IMPORT", "TOTAL", None, None), _row("ENERGY_IMPORT", "TOTAL", a, None)]
    )
    assert _periods(response) == [(None, None)]


def test_rows_the_registry_cannot_serve_contribute_no_period():
    a = datetime(2026, 9, 1, tzinfo=UTC)
    b = datetime(2026, 9, 5, tzinfo=UTC)
    response = build_analytics_catalog_response(
        site=SITE,
        rows=[_row("ENERGY_IMPORT", "TOTAL", a, b), _row("ENERGY_IMPORT", "NEUTRAL", None, None)],  # not served
    )
    assert _periods(response) == [(a, b)]


def test_a_point_listed_once_per_asset_whatever_its_period_count():
    a = datetime(2026, 9, 1, tzinfo=UTC)
    response = build_analytics_catalog_response(
        site=SITE,
        rows=[_row("ENERGY_IMPORT", "TOTAL", a, datetime(2026, 9, 2, tzinfo=UTC)),
              _row("ENERGY_IMPORT", "TOTAL", datetime(2026, 9, 10, tzinfo=UTC), None)],
    )
    assert [p.data_point for p in response.assets[0].data_points] == ["ENERGY_IMPORT"]
    assert len(_periods(response)) == 2
