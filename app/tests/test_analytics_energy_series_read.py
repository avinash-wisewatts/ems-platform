"""Contract and functional tests for migrations 277 and 278 (ADR-022 steps
B1b and B2): analytics.get_portal_analytics_energy_availability and
analytics.get_portal_analytics_energy_series.

Runs against the disposable ems_test database (see conftest.py). Each test
builds its own tenant, seeds analytics.energy_consumption_1min and runs the
real refresh chain (1min -> 5min -> 15min -> hourly -> daily) so the
canonical Energy read sees genuine tier rows -- all inside one transaction
that is rolled back.
"""

import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

SERIES_SIG = "analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)"
AVAILABILITY_SIG = "analytics.get_portal_analytics_energy_availability(bigint, uuid)"
SERIES_SQL = """
    SELECT asset_id::text, bucket_start, bucket_end, import_kwh, export_kwh,
           import_status, export_status, import_intervals, export_intervals,
           expected_intervals, is_partial, unavailable_reason
    FROM analytics.get_portal_analytics_energy_series(%s, %s, %s::uuid[], %s, %s, %s)
"""
UTC = timezone.utc
# Europe/London leaves BST at 2025-10-26 02:00 local: that local day is 25 hours.
DST_DAY_START = datetime(2025, 10, 25, 23, 0, tzinfo=UTC)   # 2025-10-26 00:00 BST
DST_DAY_END = datetime(2025, 10, 27, 0, 0, tzinfo=UTC)      # 2025-10-27 00:00 GMT
T0 = datetime(2025, 6, 2, 0, 0, tzinfo=UTC)
IMPORT_PER_MIN = Decimal("0.1")
EXPORT_PER_MIN = Decimal("0.01")


def _dec(value) -> Decimal:
    return Decimal(value).quantize(Decimal("0.000001"))


class Tenant:
    """One organization/site/gateway/grafana-map with helpers for assets."""

    def __init__(self, cur, *, tz: str, capture: int = 60, grafana_map: bool = True):
        self.cur = cur
        self.tag = uuid.uuid4().hex[:8].upper()
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        row = cur.fetchone()
        if row is None:
            pytest.skip("ENERGY_METER_ENISCOPE_V1 profile is not seeded in this database")
        self.profile_id = row[0]
        cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'")
        cur.execute(
            "INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id) "
            "VALUES ('WiseWatts Test', %s, 'Energy Meter', %s) RETURNING id",
            (f"Analytics Series Meter {self.tag}", cur.fetchone()[0]),
        )
        self.model_id = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
            (f"Analytics Series Org {self.tag}", f"AS_ORG_{self.tag}"),
        )
        self.org = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, f"Analytics Series Site {self.tag}", f"AS_SITE_{self.tag}", tz),
        )
        self.site = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, self.site, f"AS GW {self.tag}", f"AS_GW_{self.tag}"),
        )
        self.gateway = cur.fetchone()[0]
        if grafana_map:
            cur.execute("SELECT COALESCE(MAX(grafana_org_id), 800000) + 1 FROM metadata.grafana_organization_map")
            cur.execute(
                "INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active) VALUES (%s, %s, TRUE)",
                (cur.fetchone()[0], self.org),
            )
        cur.execute(
            """
            INSERT INTO config.telemetry_capture_policies
                (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
            VALUES (%s, %s, 'WALL_CLOCK', 60, TIMESTAMPTZ '2025-01-01 00:00:00+00', TRUE)
            """,
            (self.site, capture),
        )
        cur.execute(
            "INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by) "
            "VALUES (%s, 'Analytics Series Test', '$argon2id$placeholder', 'VIEWER', %s, 'ORGANIZATION', 'analytics-series-test') "
            "RETURNING portal_user_id",
            (f"as-{self.tag.lower()}@test", self.org),
        )
        self.user = cur.fetchone()[0]

    def asset(self, name: str, *, lifecycle: str = "ACTIVE", bind_from="2025-01-01 00:00:00+00") -> tuple[str, str]:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (self.org, self.gateway, self.model_id, self.profile_id, f"{name} meter", f"AS_DEV_{slug}_{self.tag}"),
        )
        device = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.assets (organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
            "VALUES (%s, %s, %s, %s, 'NOT_REQUIRED', %s) RETURNING id",
            (self.org, self.site, name, f"AS_ASSET_{slug}_{self.tag}", lifecycle),
        )
        asset = self.cur.fetchone()[0]
        for point in ("ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL"):
            self.cur.execute(
                "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from) "
                "SELECT %s, %s, id, %s, %s::timestamptz FROM metadata.logical_points WHERE name = %s",
                (asset, device, self.org, bind_from, point),
            )
        return str(asset), str(device)

    def seed_minutes(self, device: str, start: datetime, end: datetime) -> None:
        self.cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            SELECT g, %s, %s, %s, %s, 'GOOD', TRUE, FALSE, FALSE, %s, 'GOOD', TRUE, FALSE, FALSE, FALSE
            FROM generate_series(%s::timestamptz, %s::timestamptz - INTERVAL '1 minute', INTERVAL '1 minute') AS g
            """,
            (self.org, self.site, device, IMPORT_PER_MIN, EXPORT_PER_MIN, start, end),
        )

    def refresh(self, start: datetime, end: datetime) -> None:
        lo, hi = start - timedelta(days=2), end + timedelta(days=2)
        for tier in ("5min", "15min", "hourly", "daily"):
            self.cur.execute(f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)", (lo, hi))

    def series(self, assets, start, end, resolution, *, user=None):
        self.cur.execute(SERIES_SQL, (user or self.user, self.site, list(assets), start, end, resolution))
        return self.cur.fetchall()


def _set_daily_frontier(cur, value) -> None:
    cur.execute(
        "UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = 'energy_consumption_daily'",
        (value,),
    )


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Catalog contract
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [SERIES_SIG, AVAILABILITY_SIG])
def test_functions_are_portal_scoped_read_only_definers(sig):
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   lower(pg_get_functiondef(p.oid))
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (sig,),
        ).fetchone()
    assert row[:5] == (True, "s", "ems_admin", False, True)
    body = row[5]
    for forbidden in ("insert into", "update ", "delete from", "primary_meter", "v_energy_reporting_hourly"):
        assert forbidden not in body, forbidden
    assert "portal_user_can_access_site" in body


# ---------------------------------------------------------------------------
# Series: UTC grids
# ---------------------------------------------------------------------------


def test_15m_30m_1h_are_sums_of_canonical_15m_on_the_utc_grid(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("Chiller")
        t.seed_minutes(device, T0, T0 + timedelta(hours=2))
        t.refresh(T0, T0 + timedelta(hours=2))
        rows = {res: t.series([asset], T0, T0 + timedelta(hours=2), res) for res in ("15m", "30m", "1h")}

    for res, width, n in (("15m", 15, 8), ("30m", 30, 4), ("1h", 60, 2)):
        got = rows[res]
        assert len(got) == n, res
        assert [r[1] for r in got] == [T0 + timedelta(minutes=width * i) for i in range(n)]
        assert all(r[2] - r[1] == timedelta(minutes=width) for r in got)
        assert {_dec(r[3]) for r in got} == {_dec(IMPORT_PER_MIN * width)}
        assert {_dec(r[4]) for r in got} == {_dec(EXPORT_PER_MIN * width)}
        assert {(r[5], r[6]) for r in got} == {("GOOD", "GOOD")}
        assert {(r[7], r[8], r[9]) for r in got} == {(width, width, width)}
        assert {r[10] for r in got} == {False}
        assert {r[11] for r in got} == {None}
    assert sum(r[3] for r in rows["1h"]) == sum(r[3] for r in rows["15m"])


def test_1h_is_the_utc_hour_grid_not_site_local_hours(tx):
    """ADR-019 D3 / ADR-022 decision 9: an IST (UTC+05:30) site's Analytics
    hours start on the UTC hour, i.e. at :30 local time."""

    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("AHU")
        t.seed_minutes(device, T0, T0 + timedelta(hours=3))
        t.refresh(T0, T0 + timedelta(hours=3))
        got = t.series([asset], T0 + timedelta(minutes=20), T0 + timedelta(hours=2, minutes=10), "1h")

    # Range edges are not clipped: overlapping UTC hours are returned whole (D4).
    assert [r[1] for r in got] == [T0, T0 + timedelta(hours=1), T0 + timedelta(hours=2)]
    assert all(r[1].astimezone(UTC).minute == 0 for r in got)
    assert {_dec(r[3]) for r in got} == {_dec(IMPORT_PER_MIN * 60)}


def test_1m_uses_native_buckets(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("Pump")
        t.seed_minutes(device, T0, T0 + timedelta(minutes=10))
        t.refresh(T0, T0 + timedelta(minutes=10))
        got = t.series([asset], T0, T0 + timedelta(minutes=10), "1m")

    assert len(got) == 10
    assert {_dec(r[3]) for r in got} == {_dec(IMPORT_PER_MIN)}
    assert {(r[7], r[9]) for r in got} == {(1, 1)}


def test_grid_is_gap_filled_with_empty_buckets(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("Boiler")
        t.seed_minutes(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        got = t.series([asset], T0, T0 + timedelta(hours=2), "15m")

    assert len(got) == 8
    filled, empty = got[:4], got[4:]
    assert all(r[3] is not None for r in filled)
    assert all(r[3] is None and r[4] is None and r[5] is None for r in empty)
    assert {(r[7], r[8], r[9]) for r in empty} == {(0, 0, 15)}


# ---------------------------------------------------------------------------
# Series: 1 day
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("frontier", ["after", "before"])
def test_1d_dst_day_is_25_hours_from_either_source(tx, frontier):
    """The 2025-10-26 Europe/London day is 25 hours. Finalized days come
    from canonical 1d, later days from canonical 15m; both must give the
    same local-day bucket, total and expected interval count."""

    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.asset("Chiller DST")
        t.seed_minutes(device, DST_DAY_START, DST_DAY_END)
        t.refresh(DST_DAY_START, DST_DAY_END)
        _set_daily_frontier(cur, DST_DAY_END + timedelta(days=1) if frontier == "after" else DST_DAY_START)
        # A range inside the day still returns the whole local day (D4).
        got = t.series([asset], DST_DAY_START + timedelta(hours=5), DST_DAY_START + timedelta(hours=6), "1d")

    assert len(got) == 1
    day = got[0]
    assert (day[1], day[2]) == (DST_DAY_START, DST_DAY_END)
    assert day[2] - day[1] == timedelta(hours=25)
    assert day[9] == 1500
    assert _dec(day[3]) == _dec(IMPORT_PER_MIN * 1500)
    assert _dec(day[4]) == _dec(EXPORT_PER_MIN * 1500)
    assert day[10] is False


def test_1d_spans_finalized_and_open_days(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.asset("Two Days")
        day1 = datetime(2025, 6, 1, 23, 0, tzinfo=UTC)   # 2025-06-02 00:00 BST
        day2 = day1 + timedelta(days=1)
        day3 = day2 + timedelta(days=1)
        t.seed_minutes(device, day1, day3)
        t.refresh(day1, day3)
        _set_daily_frontier(cur, day2 + timedelta(hours=3))   # day 1 finalized, day 2 not
        got = t.series([asset], day1, day3, "1d")

    assert [r[1] for r in got] == [day1, day2]
    assert [r[9] for r in got] == [1440, 1440]
    assert [_dec(r[3]) for r in got] == [_dec(IMPORT_PER_MIN * 1440)] * 2


# ---------------------------------------------------------------------------
# Series: scope and unavailable reasons
# ---------------------------------------------------------------------------


def test_parity_bridge_binding_is_served_and_left_unchanged(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("Bridged", bind_from="-infinity")
        t.seed_minutes(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        cur.execute("SELECT effective_from::text FROM metadata.asset_points WHERE asset_id = %s", (asset,))
        before = cur.fetchall()
        got = t.series([asset], T0, T0 + timedelta(hours=1), "1h")
        cur.execute("SELECT effective_from::text FROM metadata.asset_points WHERE asset_id = %s", (asset,))
        after = cur.fetchall()

    assert _dec(got[0][3]) == _dec(IMPORT_PER_MIN * 60)
    assert before == after == [("-infinity",), ("-infinity",)]


def test_non_active_other_site_and_other_tenant_assets_are_not_served(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        active, device = t.asset("Active")
        draft, _ = t.asset("Draft", lifecycle="DRAFT")
        commissioning, _ = t.asset("Commissioning", lifecycle="COMMISSIONING")
        other = Tenant(cur, tz="Asia/Kolkata")
        foreign, _ = other.asset("Foreign")
        t.seed_minutes(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        own = t.series([active, draft, commissioning, foreign], T0, T0 + timedelta(hours=1), "1h")
        cross = t.series([active], T0, T0 + timedelta(hours=1), "1h", user=other.user)

    assert {r[0] for r in own} == {active}
    assert cross == []


def test_unavailable_reasons_are_reported_per_asset(tx):
    with tx.cursor() as cur:
        coarse = Tenant(cur, tz="Asia/Kolkata", capture=300)
        coarse_asset, _ = coarse.asset("Coarse")
        unmapped = Tenant(cur, tz="Asia/Kolkata", grafana_map=False)
        unmapped_asset, _ = unmapped.asset("Unmapped")
        changing = Tenant(cur, tz="Asia/Kolkata")
        changing_asset, _ = changing.asset("Changing")
        cur.execute(
            "UPDATE config.telemetry_capture_policies SET effective_to = %s WHERE site_id = %s",
            (T0 + timedelta(hours=1), changing.site),
        )
        cur.execute(
            """
            INSERT INTO config.telemetry_capture_policies
                (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
            VALUES (%s, 300, 'WALL_CLOCK', 60, %s, TRUE)
            """,
            (changing.site, T0 + timedelta(hours=1)),
        )
        results = {
            "coarse_1m": coarse.series([coarse_asset], T0, T0 + timedelta(hours=1), "1m"),
            "coarse_15m": coarse.series([coarse_asset], T0, T0 + timedelta(hours=1), "15m"),
            "unmapped": unmapped.series([unmapped_asset], T0, T0 + timedelta(hours=1), "1h"),
            "changing": changing.series([changing_asset], T0, T0 + timedelta(hours=2), "1h"),
        }

    assert [(r[1], r[11]) for r in results["coarse_1m"]] == [(None, "RESOLUTION_UNAVAILABLE")]
    assert results["coarse_15m"][0][11] is None and len(results["coarse_15m"]) == 4
    assert [(r[1], r[11]) for r in results["unmapped"]] == [(None, "NO_TENANT_MAPPING")]
    assert [(r[1], r[11]) for r in results["changing"]] == [(None, "CAPTURE_POLICY_CHANGE")]


def test_invalid_arguments_are_rejected(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, _ = t.asset("Args")
        cur.execute("SAVEPOINT a")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            t.series([asset], T0, T0 + timedelta(hours=1), "5m")
        cur.execute("ROLLBACK TO SAVEPOINT a")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            t.series([asset], T0, T0, "1h")
        cur.execute("ROLLBACK TO SAVEPOINT a")


# ---------------------------------------------------------------------------
# Availability (B1b)
# ---------------------------------------------------------------------------


def test_availability_is_bounded_by_data_and_binding_windows(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.asset("Avail")
        empty_asset, _ = t.asset("No Data Yet")
        draft, draft_device = t.asset("Draft Avail", lifecycle="DRAFT")
        t.seed_minutes(device, T0, T0 + timedelta(days=1, hours=2))
        t.seed_minutes(draft_device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(days=1, hours=2))
        cur.execute(
            "SELECT asset_id::text, data_point, available_from, available_to "
            "FROM analytics.get_portal_analytics_energy_availability(%s, %s) ORDER BY 1, 2",
            (t.user, t.site),
        )
        rows = cur.fetchall()
        other = Tenant(cur, tz="Asia/Kolkata")
        cur.execute(
            "SELECT count(*) FROM analytics.get_portal_analytics_energy_availability(%s, %s)",
            (other.user, t.site),
        )
        cross = cur.fetchone()[0]

    by_asset = {(r[0], r[1]): (r[2], r[3]) for r in rows}
    assert set(by_asset) == {(asset, "ENERGY_EXPORT"), (asset, "ENERGY_IMPORT"),
                             (empty_asset, "ENERGY_EXPORT"), (empty_asset, "ENERGY_IMPORT")}
    first_local_midnight = datetime(2025, 6, 1, 18, 30, tzinfo=UTC)  # 2025-06-02 00:00 IST
    frm, to = by_asset[(asset, "ENERGY_IMPORT")]
    assert frm == first_local_midnight
    assert to == T0 + timedelta(days=1, hours=2)
    assert by_asset[(empty_asset, "ENERGY_IMPORT")] == (None, None)
    assert cross == 0


def test_availability_respects_binding_start(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        start = T0 + timedelta(hours=6)
        asset, device = t.asset("Late Binding", bind_from=start.isoformat())
        t.seed_minutes(device, T0, T0 + timedelta(hours=12))
        t.refresh(T0, T0 + timedelta(hours=12))
        cur.execute(
            "SELECT available_from FROM analytics.get_portal_analytics_energy_availability(%s, %s) "
            "WHERE data_point = 'ENERGY_IMPORT'",
            (t.user, t.site),
        )
        assert cur.fetchone()[0] == start
