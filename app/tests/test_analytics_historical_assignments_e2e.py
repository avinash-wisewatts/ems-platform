"""Analytics with a closed (historical) assignment, end to end -- HTTP to the
ems_test database, no data-layer mocking (migration 288).

A closed asset_points binding stays in the catalogue with its assignment
period; the series serves data inside the period and reports
NO_DATA / NOT_ASSIGNED_IN_RANGE outside it (unchanged series behaviour).
Reuses the fixtures of test_analytics_api_v1_analytics_e2e (same site,
users and telemetry pattern) on a separate site of the same organization
(so the shared e2e site's assertions are unaffected), with one asset whose
Energy Import was assigned only for [T0, T0 + 12 h).
"""

from __future__ import annotations

from datetime import timedelta

import psycopg
import pytest

from tests.test_analytics_api_v1_analytics_e2e import (  # noqa: F401 -- fixtures
    CONNINFO,
    HOURS,
    IMPORT_PER_MIN,
    MODEL,
    ORG,
    OTHER_ORG,
    OTHER_USER,
    T0,
    USER,
    _login_as,
    live_client,
    users,
)

HIST_SITE = "00000000-0000-0000-0000-0000000010e2"
HIST_GATEWAY = "00000000-0000-0000-0000-0000000011e2"
HIST_DEVICE = "00000000-0000-0000-0000-0000000009e2"
HIST_ASSET = "00000000-0000-0000-0000-000000000ae2"
CLOSED_AT = T0 + timedelta(hours=12)


@pytest.fixture(scope="module")
def historical(users) -> str:
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        profile = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.sites (id, organization_id, name, code, timezone) "
            "VALUES (%s, %s, 'Analytics E2E Historical Site', 'AE2E_HIST_SITE', 'Asia/Kolkata') ON CONFLICT (id) DO NOTHING",
            (HIST_SITE, ORG),
        )
        cur.execute(
            "INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) "
            "VALUES (%s, %s, %s, 'Analytics E2E Historical GW', 'AE2E_HIST_GW') ON CONFLICT (id) DO NOTHING",
            (HIST_GATEWAY, ORG, HIST_SITE),
        )
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "SELECT %s, 60, 'WALL_CLOCK', 60, TIMESTAMPTZ '2026-01-01 00:00:00+00', TRUE "
            "WHERE NOT EXISTS (SELECT 1 FROM config.telemetry_capture_policies WHERE site_id = %s)",
            (HIST_SITE, HIST_SITE),
        )
        cur.execute(
            "INSERT INTO metadata.devices (id, organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, 'AE2E_HIST_DEV', 'AE2E_HIST_DEV') ON CONFLICT (id) DO NOTHING",
            (HIST_DEVICE, ORG, HIST_GATEWAY, MODEL, profile),
        )
        cur.execute(
            "INSERT INTO metadata.assets (id, organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
            "VALUES (%s, %s, %s, 'E2E Historical', 'E2E_HISTORICAL', 'NOT_REQUIRED', 'ACTIVE') ON CONFLICT (id) DO NOTHING",
            (HIST_ASSET, ORG, HIST_SITE),
        )
        # Energy Import assigned only for [T0, T0 + 12 h): a closed assignment.
        cur.execute(
            "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to) "
            "SELECT %s, %s, lp.id, %s, %s, %s FROM metadata.logical_points AS lp "
            "WHERE lp.name = 'ENERGY_IMPORT_TOTAL' "
            "AND NOT EXISTS (SELECT 1 FROM metadata.asset_points ap WHERE ap.asset_id = %s AND ap.logical_point_id = lp.id)",
            (HIST_ASSET, HIST_DEVICE, ORG, T0, CLOSED_AT, HIST_ASSET),
        )
        cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            SELECT g, %s, %s, %s, %s, 'GOOD', TRUE, FALSE, FALSE, 0, 'GOOD', TRUE, FALSE, FALSE, FALSE
            FROM generate_series(%s::timestamptz, %s::timestamptz - INTERVAL '1 minute', INTERVAL '1 minute') AS g
            ON CONFLICT DO NOTHING
            """,
            (ORG, HIST_SITE, HIST_DEVICE, IMPORT_PER_MIN, T0, T0 + timedelta(hours=HOURS)),
        )
        for tier in ("5min", "15min", "hourly", "daily"):
            cur.execute(
                f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)",
                (T0 - timedelta(days=2), T0 + timedelta(hours=HOURS) + timedelta(days=2)),
            )
        conn.commit()
    return HIST_ASSET


def _series(client, resolution, start, end, *selections):
    params = [("from", start.isoformat()), ("to", end.isoformat()), ("resolution", resolution)]
    params += [("selection", s) for s in selections]
    return client.get(f"/api/v1/sites/{HIST_SITE}/analytics/series", params=params)


def _catalog_points(client) -> dict[str, list[dict]]:
    response = client.get(f"/api/v1/sites/{HIST_SITE}/analytics/catalog")
    assert response.status_code == 200, response.text
    return {a["asset_id"]: a["data_points"] for a in response.json()["assets"]}


def test_closed_assignment_stays_in_the_catalogue_with_its_period(live_client, monkeypatch, users, historical) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    points = _catalog_points(live_client)
    assert [p["data_point"] for p in points[historical]] == ["ENERGY_IMPORT"]
    assert points[historical][0]["assignment_periods"] == [
        {"assigned_from": "2026-03-02T00:00:00Z", "assigned_to": "2026-03-02T12:00:00Z"}
    ]


def test_current_assignment_is_unchanged_one_unbounded_period(live_client, monkeypatch, users, historical) -> None:
    from tests.test_analytics_api_v1_analytics_e2e import ASSET, SITE

    _login_as(live_client, monkeypatch, users[USER], ORG)
    response = live_client.get(f"/api/v1/sites/{SITE}/analytics/catalog")
    assert response.status_code == 200, response.text
    points = {a["asset_id"]: a["data_points"] for a in response.json()["assets"]}
    # The parity-bridge '-infinity' start and the open end are both null.
    assert [(p["data_point"], p["assignment_periods"]) for p in points[ASSET]] == [
        ("ENERGY_IMPORT", [{"assigned_from": None, "assigned_to": None}]),
        ("ENERGY_EXPORT", [{"assigned_from": None, "assigned_to": None}]),
    ]


def test_range_inside_the_assignment_period_is_ok(live_client, monkeypatch, users, historical) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    response = _series(live_client, "15m", T0, T0 + timedelta(hours=6), f"{historical}:ENERGY_IMPORT")
    assert response.status_code == 200, response.text
    series = response.json()["series"][0]
    assert series["status"] == "OK"
    assert series["summary"]["total"] == pytest.approx(IMPORT_PER_MIN * 60 * 6)
    assert {p["data_state"] for p in series["points"]} == {"MEASURED"}


def test_range_outside_the_assignment_period_is_not_assigned_in_range(live_client, monkeypatch, users, historical) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    response = _series(live_client, "15m", CLOSED_AT + timedelta(hours=2), CLOSED_AT + timedelta(hours=8),
                       f"{historical}:ENERGY_IMPORT")
    assert response.status_code == 200, response.text
    series = response.json()["series"][0]
    assert series["status"] == "NO_DATA"
    assert series["status_reasons"] == ["NOT_ASSIGNED_IN_RANGE"]
    assert all(p["value"] is None for p in series["points"])


def test_range_straddling_the_close_serves_only_the_assigned_part(live_client, monkeypatch, users, historical) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    response = _series(live_client, "15m", CLOSED_AT - timedelta(hours=3), CLOSED_AT + timedelta(hours=3),
                       f"{historical}:ENERGY_IMPORT")
    assert response.status_code == 200, response.text
    series = response.json()["series"][0]
    assert series["status"] == "OK"
    before = [p for p in series["points"] if p["bucket_start"] < "2026-03-02T12:00:00Z"]
    after = [p for p in series["points"] if p["bucket_start"] >= "2026-03-02T12:00:00Z"]
    assert {p["data_state"] for p in before} == {"MEASURED"}
    assert {p["data_state"] for p in after} == {"NOT_ASSIGNED"}
    assert all(p["value"] is None for p in after)
    # Telemetry after the close exists for the device but is never attributed.
    assert series["summary"]["total"] == pytest.approx(IMPORT_PER_MIN * 60 * 3)


def test_other_tenant_cannot_see_the_historical_assignment(live_client, monkeypatch, users, historical) -> None:
    _login_as(live_client, monkeypatch, users[OTHER_USER], OTHER_ORG)
    assert live_client.get(f"/api/v1/sites/{HIST_SITE}/analytics/catalog").status_code == 404
    response = _series(live_client, "15m", T0, T0 + timedelta(hours=6), f"{historical}:ENERGY_IMPORT")
    assert response.status_code == 404
