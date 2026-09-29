"""Contract and functional tests for the Analytics Energy database reads after
migration 280 (ADR-022 Option B):

- analytics.get_portal_analytics_energy_series (migration 278, the
  canonical-read-era series) is dropped; Analytics reads the persisted tiers
  through analytics.get_portal_asset_energy_series (migration 279, covered by
  test_asset_energy_tier_read.py);
- analytics.get_portal_analytics_energy_availability (277, aligned by 280);
- analytics.get_analytics_energy_resolution_floors (280).

Runs against the disposable ems_test database (see conftest.py). Each
functional test builds its own tenant -- without a Grafana organization
mapping -- seeds analytics.energy_consumption_1min and runs the real refresh
chain, inside one transaction that is rolled back.
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

AVAILABILITY_SIG = "analytics.get_portal_analytics_energy_availability(bigint, uuid)"
FLOORS_SIG = "analytics.get_analytics_energy_resolution_floors()"
DROPPED_SIG = "analytics.get_portal_analytics_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)"
AVAILABILITY_SQL = (
    "SELECT asset_id::text, data_point, available_from, available_to "
    "FROM analytics.get_portal_analytics_energy_availability(%s, %s) ORDER BY 1, 2"
)
UTC = timezone.utc
T0 = datetime(2025, 6, 2, 0, 0, tzinfo=UTC)
FIRST_IST_MIDNIGHT = datetime(2025, 6, 1, 18, 30, tzinfo=UTC)   # 2025-06-02 00:00 IST


class Tenant:
    def __init__(self, cur, *, tz: str = "Asia/Kolkata"):
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
            (f"Availability Meter {self.tag}", cur.fetchone()[0]),
        )
        self.model_id = cur.fetchone()[0]
        cur.execute("INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
                    (f"Availability Org {self.tag}", f"AV_ORG_{self.tag}"))
        self.org = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, f"Availability Site {self.tag}", f"AV_SITE_{self.tag}", tz),
        )
        self.site = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, self.site, f"AV GW {self.tag}", f"AV_GW_{self.tag}"),
        )
        self.gateway = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "VALUES (%s, 60, 'WALL_CLOCK', 60, TIMESTAMPTZ '2025-01-01 00:00:00+00', TRUE)",
            (self.site,),
        )
        cur.execute(
            "INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by) "
            "VALUES (%s, 'Availability Test', '$argon2id$placeholder', 'VIEWER', %s, 'ORGANIZATION', 'availability-test') "
            "RETURNING portal_user_id",
            (f"av-{self.tag.lower()}@test", self.org),
        )
        self.user = cur.fetchone()[0]

    def asset(self, name: str, *, lifecycle: str = "ACTIVE", bind_from="2025-01-01 00:00:00+00") -> tuple[str, str]:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (self.org, self.gateway, self.model_id, self.profile_id, f"{name} meter", f"AV_DEV_{slug}_{self.tag}"),
        )
        device = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.assets (organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
            "VALUES (%s, %s, %s, %s, 'NOT_REQUIRED', %s) RETURNING id",
            (self.org, self.site, name, f"AV_ASSET_{slug}_{self.tag}", lifecycle),
        )
        asset = self.cur.fetchone()[0]
        for point in ("ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL"):
            self.cur.execute(
                "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from) "
                "SELECT %s, %s, id, %s, %s::timestamptz FROM metadata.logical_points WHERE name = %s",
                (asset, device, self.org, bind_from, point),
            )
        return str(asset), str(device)

    def seed(self, device: str, start: datetime, end: datetime) -> None:
        self.cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            SELECT g, %s, %s, %s, 0.1, 'GOOD', TRUE, FALSE, FALSE, 0.01, 'GOOD', TRUE, FALSE, FALSE, FALSE
            FROM generate_series(%s::timestamptz, %s::timestamptz - INTERVAL '1 minute', INTERVAL '1 minute') AS g
            """,
            (self.org, self.site, device, start, end),
        )

    def refresh(self, start: datetime, end: datetime) -> None:
        lo, hi = start - timedelta(days=2), end + timedelta(days=2)
        for tier in ("5min", "15min", "hourly", "daily"):
            self.cur.execute(f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)", (lo, hi))

    def availability(self, *, user=None) -> dict:
        self.cur.execute(AVAILABILITY_SQL, (user or self.user, self.site))
        return {(r[0], r[1]): (r[2], r[3]) for r in self.cur.fetchall()}


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_canonical_read_era_series_is_dropped():
    with psycopg.connect(CONNINFO) as connection:
        assert connection.execute("SELECT to_regprocedure(%s)", (DROPPED_SIG,)).fetchone()[0] is None
        assert connection.execute(
            "SELECT to_regprocedure('analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)')"
        ).fetchone()[0] is not None


@pytest.mark.parametrize("sig", [AVAILABILITY_SIG, FLOORS_SIG])
def test_reads_are_ems_app_only_definers_without_grafana_or_canonical_dependency(sig):
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   p.proconfig IS NOT NULL,
                   lower(pg_get_functiondef(p.oid))
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (sig,),
        ).fetchone()
    assert row[:7] == (True, "s", "ems_admin", False, False, True, True)
    for forbidden in ("grafana", "get_canonical_energy_read", "primary_meter", "insert into", "update ", "delete from"):
        assert forbidden not in row[7], forbidden


# ---------------------------------------------------------------------------
# Resolution floors
# ---------------------------------------------------------------------------


def test_resolution_floors_follow_the_live_retention_policies():
    with psycopg.connect(CONNINFO) as connection:
        floors = dict(connection.execute(
            "SELECT resolution, earliest_available FROM analytics.get_analytics_energy_resolution_floors()"
        ).fetchall())
        policies = dict(connection.execute(
            """
            SELECT hypertable_name, now() - (config ->> 'drop_after')::interval
            FROM timescaledb_information.jobs
            WHERE hypertable_schema = 'analytics' AND proc_name = 'policy_retention'
              AND hypertable_name IN ('energy_consumption_1min', 'energy_consumption_15min',
                                      'energy_consumption_hourly', 'energy_consumption_daily')
            """
        ).fetchall())
    assert set(floors) == {"1m", "15m", "30m", "1h", "1d"}
    assert floors["1m"] == policies.get("energy_consumption_1min")
    assert floors["15m"] == floors["30m"] == policies.get("energy_consumption_15min")
    assert floors["1h"] == policies.get("energy_consumption_hourly")
    assert floors["1d"] == policies.get("energy_consumption_daily")   # None: the daily tier has no retention
    assert floors["1m"] > floors["15m"] > floors["1h"]


# ---------------------------------------------------------------------------
# Availability
# ---------------------------------------------------------------------------


def test_availability_is_bounded_by_data_and_binding_windows_without_grafana(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.asset("Avail")
        empty_asset, _ = t.asset("No Data Yet")
        _draft, draft_device = t.asset("Draft Avail", lifecycle="DRAFT")
        t.seed(device, T0, T0 + timedelta(days=1, hours=2))
        t.seed(draft_device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(days=1, hours=2))
        cur.execute("SELECT count(*) FROM metadata.grafana_organization_map WHERE organization_id = %s", (t.org,))
        assert cur.fetchone()[0] == 0
        got = t.availability()
        other = Tenant(cur)
        cross = t.availability(user=other.user)

    assert set(got) == {(asset, "ENERGY_EXPORT"), (asset, "ENERGY_IMPORT"),
                        (empty_asset, "ENERGY_EXPORT"), (empty_asset, "ENERGY_IMPORT")}
    assert got[(asset, "ENERGY_IMPORT")] == (FIRST_IST_MIDNIGHT, T0 + timedelta(days=1, hours=2))
    assert got[(empty_asset, "ENERGY_IMPORT")] == (None, None)
    assert cross == {}


def test_availability_end_reaches_the_raw_tail_beyond_the_persisted_15m_tier(tx):
    """The Analytics read serves 15-minute rows newer than the persisted tier
    from raw data, so availability must end at the freshest raw minute."""

    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.asset("Fresh")
        t.seed(device, T0, T0 + timedelta(hours=2))
        t.refresh(T0, T0 + timedelta(hours=2))
        t.seed(device, T0 + timedelta(hours=2), T0 + timedelta(hours=2, minutes=7))   # raw only, not refreshed
        got = t.availability()

    assert got[(asset, "ENERGY_IMPORT")][1] == T0 + timedelta(hours=2, minutes=7)


def test_availability_start_survives_raw_retention(tx):
    """The start comes from the daily tier (no retention), consistent with the
    1d series, even after raw and persisted 15-minute rows are gone."""

    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.asset("Old History")
        t.seed(device, T0, T0 + timedelta(days=1))
        t.refresh(T0, T0 + timedelta(days=1))
        for table in ("energy_consumption_1min", "energy_consumption_5min", "energy_consumption_15min"):
            cur.execute(f"DELETE FROM analytics.{table} WHERE device_id = %s", (device,))
        got = t.availability()

    frm, to = got[(asset, "ENERGY_IMPORT")]
    assert frm == FIRST_IST_MIDNIGHT
    assert to is not None and to > frm


def test_availability_respects_binding_start(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        start = T0 + timedelta(hours=6)
        asset, device = t.asset("Late Binding", bind_from=start.isoformat())
        t.seed(device, T0, T0 + timedelta(hours=12))
        t.refresh(T0, T0 + timedelta(hours=12))
        got = t.availability()

    assert got[(asset, "ENERGY_IMPORT")] == (start, T0 + timedelta(hours=12))


def test_parity_bridge_binding_is_used_and_left_unchanged(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.asset("Bridged", bind_from="-infinity")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        cur.execute("SELECT effective_from::text FROM metadata.asset_points WHERE asset_id = %s", (asset,))
        before = cur.fetchall()
        got = t.availability()
        cur.execute("SELECT effective_from::text FROM metadata.asset_points WHERE asset_id = %s", (asset,))
        after = cur.fetchall()

    assert got[(asset, "ENERGY_IMPORT")] == (FIRST_IST_MIDNIGHT, T0 + timedelta(hours=1))
    assert before == after == [("-infinity",), ("-infinity",)]
