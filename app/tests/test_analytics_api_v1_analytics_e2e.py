"""Analytics v1 (ADR-022) end-to-end slice: HTTP -> router -> service ->
analytics.get_portal_analytics_catalog / _energy_availability /
_energy_series -> analytics.get_canonical_energy_read -> Energy tier tables,
against the disposable ems_test database with NO data-layer mocking.

Only authentication is faked (as in every /api/v1 route test); the portal
user it returns is a real admin.portal_users row, so tenant scoping is
enforced by the database exactly as in production. Fixtures are committed
with fixed ids and ON CONFLICT DO NOTHING (the test_analytics_api_v1_contract.py
pattern) and are safe to re-run. The asset's Energy bindings use
effective_from = '-infinity', the shape of the staging parity-bridge rows.
"""

from __future__ import annotations

import asyncio
import os
import sys
from datetime import datetime, timedelta, timezone

import psycopg
import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

ORG = "00000000-0000-0000-0000-0000000000e2"
OTHER_ORG = "00000000-0000-0000-0000-0000000001e2"
SITE = "00000000-0000-0000-0000-0000000002e2"
GATEWAY = "00000000-0000-0000-0000-0000000003e2"
MODEL = "00000000-0000-0000-0000-0000000004e2"
DEVICE = "00000000-0000-0000-0000-0000000005e2"
ASSET = "00000000-0000-0000-0000-0000000006e2"
DRAFT_ASSET = "00000000-0000-0000-0000-0000000007e2"
DRAFT_DEVICE = "00000000-0000-0000-0000-0000000008e2"
GRAFANA_ORG = 9102
USER = "analytics-e2e@test"
OTHER_USER = "analytics-e2e-other@test"
UTC = timezone.utc
T0 = datetime(2026, 3, 2, 0, 0, tzinfo=UTC)
HOURS = 26                      # spans two IST local days
IMPORT_PER_MIN = 0.1
EXPORT_PER_MIN = 0.02


@pytest.fixture(scope="module")
def users() -> dict[str, int]:
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        profile = cur.fetchone()
        if profile is None:
            pytest.skip("ENERGY_METER_ENISCOPE_V1 profile is not seeded in this database")
        for org, code in ((ORG, "AE2E_ORG"), (OTHER_ORG, "AE2E_OTHER_ORG")):
            cur.execute(
                "INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (org, code.replace("_", " ").title(), code),
            )
        cur.execute(
            "INSERT INTO metadata.sites (id, organization_id, name, code, timezone) "
            "VALUES (%s, %s, 'Analytics E2E Site', 'AE2E_SITE', 'Asia/Kolkata') ON CONFLICT (id) DO NOTHING",
            (SITE, ORG),
        )
        cur.execute(
            "INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) "
            "VALUES (%s, %s, %s, 'Analytics E2E GW', 'AE2E_GW') ON CONFLICT (id) DO NOTHING",
            (GATEWAY, ORG, SITE),
        )
        cur.execute(
            "INSERT INTO metadata.device_models (id, vendor, model, device_type, device_category_id) "
            "SELECT %s, 'WiseWatts Test', 'Analytics E2E Meter', 'Energy Meter', id "
            "FROM config.device_categories WHERE lower(name) = 'energy meter' ON CONFLICT (id) DO NOTHING",
            (MODEL,),
        )
        for device, name in ((DEVICE, "AE2E_DEV"), (DRAFT_DEVICE, "AE2E_DRAFT_DEV")):
            cur.execute(
                "INSERT INTO metadata.devices (id, organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s) ON CONFLICT (id) DO NOTHING",
                (device, ORG, GATEWAY, MODEL, profile[0], name, name),
            )
        for asset, name, lifecycle in ((ASSET, "E2E Chiller", "ACTIVE"), (DRAFT_ASSET, "E2E Draft", "DRAFT")):
            cur.execute(
                "INSERT INTO metadata.assets (id, organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
                "VALUES (%s, %s, %s, %s, %s, 'NOT_REQUIRED', %s) ON CONFLICT (id) DO NOTHING",
                (asset, ORG, SITE, name, name.upper().replace(" ", "_"), lifecycle),
            )
        for asset, device in ((ASSET, DEVICE), (DRAFT_ASSET, DRAFT_DEVICE)):
            cur.execute(
                "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from) "
                "SELECT %s, %s, lp.id, %s, '-infinity' FROM metadata.logical_points AS lp "
                "WHERE lp.name IN ('ENERGY_IMPORT_TOTAL', 'ENERGY_EXPORT_TOTAL') "
                "AND NOT EXISTS (SELECT 1 FROM metadata.asset_points ap WHERE ap.asset_id = %s AND ap.logical_point_id = lp.id)",
                (asset, device, ORG, asset),
            )
        cur.execute(
            "INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active) "
            "VALUES (%s, %s, TRUE) ON CONFLICT (grafana_org_id) DO NOTHING",
            (GRAFANA_ORG, ORG),
        )
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "SELECT %s, 60, 'WALL_CLOCK', 60, TIMESTAMPTZ '2026-01-01 00:00:00+00', TRUE "
            "WHERE NOT EXISTS (SELECT 1 FROM config.telemetry_capture_policies WHERE site_id = %s)",
            (SITE, SITE),
        )
        cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            SELECT g, %s, %s, %s, %s, 'GOOD', TRUE, FALSE, FALSE, %s, 'GOOD', TRUE, FALSE, FALSE, FALSE
            FROM generate_series(%s::timestamptz, %s::timestamptz - INTERVAL '1 minute', INTERVAL '1 minute') AS g
            ON CONFLICT DO NOTHING
            """,
            (ORG, SITE, DEVICE, IMPORT_PER_MIN, EXPORT_PER_MIN, T0, T0 + timedelta(hours=HOURS)),
        )
        for tier in ("5min", "15min", "hourly", "daily"):
            cur.execute(
                f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)",
                (T0 - timedelta(days=2), T0 + timedelta(hours=HOURS) + timedelta(days=2)),
            )
        ids = {}
        for username, org in ((USER, ORG), (OTHER_USER, OTHER_ORG)):
            cur.execute(
                "INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by) "
                "VALUES (%s, %s, '$argon2id$placeholder', 'VIEWER', %s, 'ORGANIZATION', 'analytics-e2e') "
                "ON CONFLICT (username) DO NOTHING",
                (username, username, org),
            )
            cur.execute("SELECT portal_user_id FROM admin.portal_users WHERE username = %s", (username,))
            ids[username] = cur.fetchone()[0]
        conn.commit()
    return ids


@pytest.fixture
def live_client():
    """TestClient entered as a context manager, so the application lifespan
    opens the real database pool (conftest's portal_client deliberately does
    not -- every other route test mocks the data layer)."""

    from fastapi.testclient import TestClient

    from src.main import app

    backend_options = {}
    if sys.platform == "win32":
        # psycopg's async driver cannot run on Windows' default Proactor
        # loop; CI (Linux) uses the default loop unchanged.
        backend_options["loop_factory"] = asyncio.SelectorEventLoop

    with TestClient(app, follow_redirects=False, backend_options=backend_options) as client:
        yield client


def _login_as(portal_client, monkeypatch, portal_user_id: int, organization_id: str) -> None:
    async def fake_authenticate(username: str, password: str) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=portal_user_id, username=username, display_name="Analytics E2E",
                role_code="VIEWER", organization_id=organization_id, access_scope_mode="ORGANIZATION",
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr("src.main.authenticate_portal_user", fake_authenticate)
    response = portal_client.post(
        "/login", data={"username": "e2e@test", "password": "valid-password", "next_path": "/"}
    )
    assert response.status_code == 303


def _series(portal_client, resolution, start, end, *selections):
    params = [("from", start.isoformat()), ("to", end.isoformat()), ("resolution", resolution)]
    params += [("selection", s) for s in selections]
    return portal_client.get(f"/api/v1/sites/{SITE}/analytics/series", params=params)


def test_catalog_end_to_end(live_client, monkeypatch, users) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    response = live_client.get(f"/api/v1/sites/{SITE}/analytics/catalog")
    assert response.status_code == 200
    body = response.json()
    assert body["site_timezone"] == "Asia/Kolkata"
    assert [a["asset_name"] for a in body["assets"]] == ["E2E Chiller"]   # DRAFT asset excluded
    points = body["assets"][0]["data_points"]
    assert [p["data_point"] for p in points] == ["ENERGY_IMPORT", "ENERGY_EXPORT"]
    imp = points[0]
    # 2026-03-02 00:00 IST is the local day containing T0 (05:30 IST).
    assert imp["available_from"] == "2026-03-01T18:30:00Z"
    assert imp["available_to"] == (T0 + timedelta(hours=HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    assert "attribution_basis" not in response.text and "PARITY_BRIDGE" not in response.text


def test_series_end_to_end_every_resolution_agrees(live_client, monkeypatch, users) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    end = T0 + timedelta(hours=HOURS)
    totals = {}
    for resolution, start, stop in (
        ("15m", T0, end), ("30m", T0, end), ("1h", T0, end),
        ("1m", T0, T0 + timedelta(hours=2)),
        ("1d", T0, end),
    ):
        response = _series(live_client, resolution, start, stop,
                           f"{ASSET}:ENERGY_IMPORT", f"{ASSET}:ENERGY_EXPORT", f"{DRAFT_ASSET}:ENERGY_IMPORT")
        assert response.status_code == 200, (resolution, response.text)
        body = response.json()
        assert body["resolution"] == resolution
        imp, exp, draft = body["series"]
        assert (imp["status"], exp["status"], draft["status"]) == ("OK", "OK", "NOT_AVAILABLE")
        totals[resolution] = (imp["summary"]["total"], exp["summary"]["total"])
        if resolution in ("15m", "30m", "1h", "1m"):
            assert imp["summary"]["coverage_ratio"] == 1.0
            assert {p["evidence_status"] for p in imp["points"]} == {"GOOD"}

    full = (IMPORT_PER_MIN * 60 * HOURS, EXPORT_PER_MIN * 60 * HOURS)
    for resolution in ("15m", "30m", "1h", "1d"):
        assert totals[resolution] == pytest.approx(full), resolution
    assert totals["1m"] == pytest.approx((IMPORT_PER_MIN * 120, EXPORT_PER_MIN * 120))


def test_series_1h_is_utc_grid_and_1d_is_ist_local_days(live_client, monkeypatch, users) -> None:
    _login_as(live_client, monkeypatch, users[USER], ORG)
    end = T0 + timedelta(hours=HOURS)
    hourly = _series(live_client, "1h", T0, end, f"{ASSET}:ENERGY_IMPORT").json()["series"][0]["points"]
    assert hourly[0]["bucket_start"] == "2026-03-02T00:00:00Z"
    assert len(hourly) == HOURS

    daily = _series(live_client, "1d", T0, end, f"{ASSET}:ENERGY_IMPORT").json()["series"][0]["points"]
    assert [(p["bucket_start"], p["bucket_end"]) for p in daily] == [
        ("2026-03-01T18:30:00Z", "2026-03-02T18:30:00Z"),
        ("2026-03-02T18:30:00Z", "2026-03-03T18:30:00Z"),
    ]
    # T0 is 05:30 IST: the first local day holds 18.5 h of data, the second 7.5 h.
    assert [p["value"] for p in daily] == pytest.approx([IMPORT_PER_MIN * 60 * 18.5, IMPORT_PER_MIN * 60 * 7.5])
    assert [p["coverage_ratio"] for p in daily] == pytest.approx([18.5 / 24, 7.5 / 24])


def test_other_tenant_cannot_read_the_site(live_client, monkeypatch, users) -> None:
    _login_as(live_client, monkeypatch, users[OTHER_USER], OTHER_ORG)
    assert live_client.get(f"/api/v1/sites/{SITE}/analytics/catalog").status_code == 404
    response = _series(live_client, "1h", T0, T0 + timedelta(hours=2), f"{ASSET}:ENERGY_IMPORT")
    assert response.status_code == 404
