"""Contract and functional tests for analytics.get_portal_asset_energy_series:
the persisted-tier, portal/organization-scoped asset Energy read (ADR-022
Option B; migration 279, corrected by 281, Data Quality contract by 282).

These tests cover the Energy VALUES and tier composition, which migration 282
leaves unchanged; READ_SQL projects 282's output back onto the 279 shape
(valid + invalid intervals, reasons joined). Tenants default to a UTC site:
since 282 (D24) the UTC hourly tier serves 1h only where local hours are UTC
hours, so tier-composition assertions need such a site. The site-local grid,
interval counts, data state, data bounds and stale are covered by
test_analytics_energy_series_data_quality.py.

Runs against the disposable ems_test database (see conftest.py). Every test
builds its own tenant, seeds analytics.energy_consumption_1min, runs the real
refresh chain (1min -> 5min -> 15min -> hourly -> daily) and sets the tier
checkpoints in telemetry.pipeline_state -- all inside one transaction that is
rolled back. Tenants have NO Grafana organization mapping unless a test needs
the canonical read for a parity comparison.
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

SIG = "analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)"
HELPER = "analytics.energy_direction_status(bigint, bigint, bigint, bigint, bigint, bigint)"
READ_SQL = """
    SELECT asset_id::text, bucket_start, bucket_end, import_kwh, export_kwh,
           import_status, export_status,
           import_valid_intervals + import_invalid_intervals,
           export_valid_intervals + export_invalid_intervals,
           expected_intervals, is_partial, array_to_string(unavailable_reasons, ',')
    FROM analytics.get_portal_asset_energy_series(%s, %s, %s::uuid[], %s, %s, %s, %s)
"""
UTC = timezone.utc
T0 = datetime(2025, 6, 2, 0, 0, tzinfo=UTC)
DAY1 = datetime(2025, 6, 1, 23, 0, tzinfo=UTC)          # 2025-06-02 00:00 BST
DST_DAY_START = datetime(2025, 10, 25, 23, 0, tzinfo=UTC)  # 2025-10-26 00:00 BST (25 h day)
DST_DAY_END = datetime(2025, 10, 27, 0, 0, tzinfo=UTC)
FAR = datetime(2099, 1, 1, tzinfo=UTC)


def _d(value) -> Decimal:
    return Decimal(value).quantize(Decimal("0.000001"))


class Tenant:
    def __init__(self, cur, *, tz: str = "UTC", capture: int = 60, grafana_map: bool = False):
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
            (f"Tier Read Meter {self.tag}", cur.fetchone()[0]),
        )
        self.model_id = cur.fetchone()[0]
        cur.execute("INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
                    (f"Tier Read Org {self.tag}", f"TR_ORG_{self.tag}"))
        self.org = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, f"Tier Read Site {self.tag}", f"TR_SITE_{self.tag}", tz),
        )
        self.site = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (self.org, self.site, f"TR GW {self.tag}", f"TR_GW_{self.tag}"),
        )
        self.gateway = cur.fetchone()[0]
        self.grafana_org = None
        if grafana_map:
            cur.execute("SELECT COALESCE(MAX(grafana_org_id), 800000) + 1 FROM metadata.grafana_organization_map")
            self.grafana_org = cur.fetchone()[0]
            cur.execute(
                "INSERT INTO metadata.grafana_organization_map (grafana_org_id, organization_id, is_active) VALUES (%s, %s, TRUE)",
                (self.grafana_org, self.org),
            )
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "VALUES (%s, %s, 'WALL_CLOCK', 60, TIMESTAMPTZ '2025-01-01 00:00:00+00', TRUE)",
            (self.site, capture),
        )
        cur.execute(
            "INSERT INTO admin.portal_users (username, display_name, password_hash, role_code, organization_id, access_scope_mode, created_by) "
            "VALUES (%s, 'Tier Read Test', '$argon2id$placeholder', 'VIEWER', %s, 'ORGANIZATION', 'tier-read-test') RETURNING portal_user_id",
            (f"tr-{self.tag.lower()}@test", self.org),
        )
        self.user = cur.fetchone()[0]

    def device(self, name: str) -> str:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            "INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (self.org, self.gateway, self.model_id, self.profile_id, name, f"TR_DEV_{slug}_{self.tag}"),
        )
        return str(self.cur.fetchone()[0])

    def asset(self, name: str, *, lifecycle: str = "ACTIVE") -> str:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            "INSERT INTO metadata.assets (organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
            "VALUES (%s, %s, %s, %s, 'NOT_REQUIRED', %s) RETURNING id",
            (self.org, self.site, name, f"TR_ASSET_{slug}_{self.tag}", lifecycle),
        )
        return str(self.cur.fetchone()[0])

    def bind(self, asset: str, device: str, point: str, start="2025-01-01 00:00:00+00", end=None) -> None:
        self.cur.execute(
            "INSERT INTO metadata.asset_points (asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to) "
            "SELECT %s, %s, id, %s, %s::timestamptz, %s FROM metadata.logical_points WHERE name = %s",
            (asset, device, self.org, start, end, point),
        )

    def bind_both(self, asset: str, device: str, **kw) -> None:
        self.bind(asset, device, "ENERGY_IMPORT_TOTAL", **kw)
        self.bind(asset, device, "ENERGY_EXPORT_TOTAL", **kw)

    def simple_asset(self, name: str, *, lifecycle: str = "ACTIVE", start="2025-01-01 00:00:00+00") -> tuple[str, str]:
        device = self.device(f"{name} meter")
        asset = self.asset(name, lifecycle=lifecycle)
        self.bind_both(asset, device, start=start)
        return asset, device

    def seed(self, device: str, start: datetime, end: datetime, imp="0.1", exp="0.01") -> None:
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
            (self.org, self.site, device, Decimal(imp), Decimal(exp), start, end),
        )

    def refresh(self, start: datetime, end: datetime) -> None:
        lo, hi = start - timedelta(days=2), end + timedelta(days=2)
        for tier in ("5min", "15min", "hourly", "daily"):
            self.cur.execute(f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)", (lo, hi))

    def read(self, assets, start, end, resolution, *, user=None, as_of=None):
        self.cur.execute(READ_SQL, (user or self.user, self.site, list(assets), start, end, resolution, as_of))
        return self.cur.fetchall()


def checkpoints(cur, *, c15=FAR, ch=FAR, cd=FAR) -> None:
    for name, value in (("energy_consumption_15min", c15), ("energy_consumption_hourly", ch),
                        ("energy_consumption_daily", cd)):
        cur.execute(
            "INSERT INTO telemetry.pipeline_state (pipeline_name, last_received_at) VALUES (%s, %s) "
            "ON CONFLICT (pipeline_name) DO UPDATE SET last_received_at = EXCLUDED.last_received_at",
            (name, value),
        )


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_read_is_portal_scoped_and_never_grafana_keyed():
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   lower(pg_get_functiondef(p.oid))
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (SIG,),
        ).fetchone()
        helper_public = connection.execute(
            "SELECT has_function_privilege('public', %s::regprocedure, 'EXECUTE')", (HELPER,)
        ).fetchone()[0]
    assert row[:6] == (True, "s", "ems_admin", False, False, True)
    body = row[6]
    for forbidden in ("grafana", "get_canonical_energy_read", "v_energy_reporting", "primary_meter",
                      "insert into", "update ", "delete from"):
        assert forbidden not in body, forbidden
    for required in ("energy_consumption_15min", "energy_consumption_hourly", "energy_consumption_daily",
                     "v_energy_semantic_rollup_15min", "resolve_asset_energy_source_windows",
                     "portal_user_can_access_site"):
        assert required in body, required
    assert helper_public is False


@pytest.mark.parametrize(
    ("counters", "expected"),
    [
        ((1, 1, 1, 1, 1, 1), "INVALID_INTERVALS"),
        ((1, 0, 1, 1, 1, 1), "RESET_DETECTED"),
        ((1, 0, 0, 1, 1, 1), "GAPS_DETECTED"),
        ((1, 0, 0, 0, 1, 1), "RECONSTRUCTED_TIMING"),
        ((1, 0, 0, 0, 0, 1), "ROLLOVER_DETECTED"),
        ((0, 0, 0, 0, 0, 0), "INVALID_INTERVALS"),
        ((0, 0, 0, 0, 3, 0), "RECONSTRUCTED_TIMING"),
        ((15, 0, 0, 0, 0, 0), "GOOD"),
    ],
)
def test_status_helper_has_the_canonical_precedence(counters, expected):
    with psycopg.connect(CONNINFO) as connection:
        got = connection.execute(f"SELECT {HELPER.split('(')[0]}(%s, %s, %s, %s, %s, %s)", counters).fetchone()[0]
    assert got == expected


# ---------------------------------------------------------------------------
# Tiers and composition
# ---------------------------------------------------------------------------


def test_15m_30m_1h_from_persisted_tiers(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Chiller")
        t.seed(device, T0, T0 + timedelta(hours=2))
        t.refresh(T0, T0 + timedelta(hours=2))
        checkpoints(cur)
        got = {res: t.read([asset], T0, T0 + timedelta(hours=2), res) for res in ("15m", "30m", "1h")}

    for res, minutes, n in (("15m", 15, 8), ("30m", 30, 4), ("1h", 60, 2)):
        rows = got[res]
        assert [r[1] for r in rows] == [T0 + timedelta(minutes=minutes * i) for i in range(n)], res
        assert {_d(r[3]) for r in rows} == {_d(Decimal("0.1") * minutes)}
        assert {_d(r[4]) for r in rows} == {_d(Decimal("0.01") * minutes)}
        assert {(r[5], r[6], r[7], r[8], r[9], r[10], r[11]) for r in rows} == {
            ("GOOD", "GOOD", minutes, minutes, minutes, False, None)
        }


def test_hourly_rows_are_used_up_to_the_hourly_checkpoint_and_15m_after_it(tx):
    """Proves the source of each hour: 15-minute rows before the hourly
    checkpoint are deleted (so those hours can only come from the hourly
    tier), hourly rows after it are deleted (so those can only come from
    15m)."""

    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Composition")
        t.seed(device, T0, T0 + timedelta(hours=3))
        t.refresh(T0, T0 + timedelta(hours=3))
        ch = T0 + timedelta(hours=2)
        checkpoints(cur, ch=ch)
        cur.execute("DELETE FROM analytics.energy_consumption_15min WHERE device_id = %s AND bucket_start < %s", (device, ch))
        cur.execute("DELETE FROM analytics.energy_consumption_hourly WHERE device_id = %s AND bucket_start >= %s", (device, ch))
        rows = t.read([asset], T0, T0 + timedelta(hours=3), "1h")

    assert [_d(r[3]) for r in rows] == [_d("6.0")] * 3
    assert [r[7] for r in rows] == [60, 60, 60]


def test_15m_tail_after_the_checkpoint_comes_from_the_semantic_rollup(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Tail")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        c15 = T0 + timedelta(minutes=30)
        checkpoints(cur, c15=c15)
        cur.execute("DELETE FROM analytics.energy_consumption_15min WHERE device_id = %s AND bucket_start >= %s", (device, c15))
        rows = t.read([asset], T0, T0 + timedelta(hours=1), "15m")

    assert [_d(r[3]) for r in rows] == [_d("1.5")] * 4


def test_15m_checkpoint_inside_a_bucket_serves_that_bucket_from_the_fresh_path(tx):
    """Migration 281 regression (staging PT-5, 2026-09-27): the 15-minute
    checkpoint can fall inside a bucket, whose persisted row is then partial.
    Here the checkpoint is T0+40 min, inside [T0+30, T0+45); the persisted row
    for that bucket is made partial (as the pipeline leaves it) and must not be
    used -- the bucket comes from the semantic rollup with all 15 intervals,
    and buckets that had ended at the checkpoint still come from the
    persisted tier."""

    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Mid-bucket checkpoint")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        straddling = T0 + timedelta(minutes=30)
        checkpoints(cur, c15=T0 + timedelta(minutes=40), ch=T0)
        cur.execute(
            "UPDATE analytics.energy_consumption_15min "
            "SET import_consumption_kwh = 1.0, valid_import_intervals = 10, source_interval_count = 10 "
            "WHERE device_id = %s AND bucket_start = %s",
            (device, straddling),
        )
        cur.execute(
            "UPDATE analytics.energy_consumption_15min SET import_consumption_kwh = 1.4 "
            "WHERE device_id = %s AND bucket_start = %s",
            (device, T0),
        )
        q = t.read([asset], T0, T0 + timedelta(hours=1), "15m")
        h = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert [r[1] for r in q] == [T0 + timedelta(minutes=15 * i) for i in range(4)]
    # T0 had ended at the checkpoint: still the persisted row (altered to 1.4 to prove it).
    assert _d(q[0][3]) == _d("1.4")
    # The straddling bucket and the newer one come from the fresh path: complete.
    assert [(_d(r[3]), r[7]) for r in q[2:]] == [(_d("1.5"), 15), (_d("1.5"), 15)]
    assert _d(q[1][3]) == _d("1.5")
    # The hour is summed from those 15-minute rows (hourly checkpoint at T0).
    assert (_d(h[0][3]), h[0][7]) == (_d("5.9"), 60)


def test_nothing_processed_yet_is_served_entirely_from_the_rollup(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Unprocessed")
        t.seed(device, T0, T0 + timedelta(hours=1))   # raw only: no refresh chain
        checkpoints(cur, c15=None, ch=None, cd=None)
        rows = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert _d(rows[0][3]) == _d("6.0")


@pytest.mark.parametrize("source", ["daily", "fifteen"])
def test_1d_dst_day_is_25_hours_from_either_source(tx, source):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.simple_asset("DST")
        t.seed(device, DST_DAY_START, DST_DAY_END)
        t.refresh(DST_DAY_START, DST_DAY_END)
        if source == "daily":
            checkpoints(cur)
            cur.execute("DELETE FROM analytics.energy_consumption_15min WHERE device_id = %s", (device,))
        else:
            checkpoints(cur, cd=DST_DAY_START)
            cur.execute("UPDATE analytics.energy_consumption_daily SET import_consumption_kwh = 999 WHERE device_id = %s",
                        (device,))
        rows = t.read([asset], DST_DAY_START + timedelta(hours=5), DST_DAY_START + timedelta(hours=6), "1d")

    assert len(rows) == 1
    day = rows[0]
    assert (day[1], day[2]) == (DST_DAY_START, DST_DAY_END)
    assert day[9] == 1500
    assert _d(day[3]) == _d(Decimal("0.1") * 1500)
    assert day[7] == 1500


def test_unprocessed_partial_daily_row_is_never_used(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.simple_asset("Stale Daily")
        day2 = DAY1 + timedelta(days=1)
        t.seed(device, DAY1, day2 + timedelta(days=1))
        t.refresh(DAY1, day2 + timedelta(days=1))
        checkpoints(cur, cd=day2 + timedelta(hours=3))   # day 1 processed, day 2 not
        cur.execute("UPDATE analytics.energy_consumption_daily SET import_consumption_kwh = 1 WHERE device_id = %s AND bucket_start = %s",
                    (device, day2))
        rows = t.read([asset], DAY1, day2 + timedelta(days=1), "1d")

    assert [_d(r[3]) for r in rows] == [_d("144.0"), _d("144.0")]


# ---------------------------------------------------------------------------
# Attribution and source boundaries
# ---------------------------------------------------------------------------


def test_binding_change_inside_a_15m_bucket_incoming_source_owns_it(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        a_dev, b_dev = t.device("A meter"), t.device("B meter")
        asset = t.asset("Switch15")
        switch = T0 + timedelta(minutes=7)
        t.bind_both(asset, a_dev, end=switch)
        t.bind_both(asset, b_dev, start=switch)
        t.seed(a_dev, T0, T0 + timedelta(hours=1), imp="0.1")
        t.seed(b_dev, T0, T0 + timedelta(hours=1), imp="0.3")
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        q = t.read([asset], T0, T0 + timedelta(hours=1), "15m")
        h = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert [_d(r[3]) for r in q] == [_d("4.5")] * 4           # B owns the straddling bucket
    assert _d(h[0][3]) == _d("18.0")                          # hour summed from attributed 15m, not a whole hourly row


def test_binding_change_inside_a_day_is_summed_from_15m(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        a_dev, b_dev = t.device("A day meter"), t.device("B day meter")
        asset = t.asset("SwitchDay")
        switch = DAY1 + timedelta(hours=12)
        t.bind_both(asset, a_dev, end=switch)
        t.bind_both(asset, b_dev, start=switch)
        t.seed(a_dev, DAY1, DAY1 + timedelta(days=1), imp="0.1")
        t.seed(b_dev, DAY1, DAY1 + timedelta(days=1), imp="0.3")
        t.refresh(DAY1, DAY1 + timedelta(days=1))
        checkpoints(cur)
        d = t.read([asset], DAY1, DAY1 + timedelta(days=1), "1d")

    assert _d(d[0][3]) == _d(Decimal("0.1") * 720 + Decimal("0.3") * 720)


def test_import_and_export_resolve_independently(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        imp_dev, exp_dev = t.device("Import meter"), t.device("Export meter")
        asset = t.asset("Split")
        t.bind(asset, imp_dev, "ENERGY_IMPORT_TOTAL")
        t.bind(asset, exp_dev, "ENERGY_EXPORT_TOTAL")
        t.seed(imp_dev, T0, T0 + timedelta(hours=1), imp="0.1", exp="0.5")
        t.seed(exp_dev, T0, T0 + timedelta(hours=1), imp="0.7", exp="0.02")
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        rows = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert (_d(rows[0][3]), _d(rows[0][4])) == (_d("6.0"), _d("1.2"))


def test_reconstructed_counters_set_status_and_are_not_measured(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Reconstructed")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        cur.execute(
            "UPDATE analytics.energy_consumption_15min SET valid_import_intervals = 12, import_reconstructed_intervals = 3 "
            "WHERE device_id = %s AND bucket_start = %s", (device, T0))
        cur.execute(
            "UPDATE analytics.energy_consumption_hourly SET valid_import_intervals = 57, import_reconstructed_intervals = 3 "
            "WHERE device_id = %s AND bucket_start = %s", (device, T0))
        q = t.read([asset], T0, T0 + timedelta(hours=1), "15m")
        half = t.read([asset], T0, T0 + timedelta(hours=1), "30m")
        h = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert (q[0][5], q[0][7], q[0][6]) == ("RECONSTRUCTED_TIMING", 12, "GOOD")
    assert [r[5] for r in q[1:]] == ["GOOD"] * 3
    assert (half[0][5], half[0][7]) == ("RECONSTRUCTED_TIMING", 27)
    assert (h[0][5], h[0][7]) == ("RECONSTRUCTED_TIMING", 57)


# ---------------------------------------------------------------------------
# Capture, retention, timezone
# ---------------------------------------------------------------------------


def test_capture_reasons(tx):
    with tx.cursor() as cur:
        coarse = Tenant(cur, capture=300)
        coarse_asset, _ = coarse.simple_asset("Coarse")
        changing = Tenant(cur)
        changing_asset, _ = changing.simple_asset("Changing")
        cur.execute("UPDATE config.telemetry_capture_policies SET effective_to = %s WHERE site_id = %s",
                    (T0 + timedelta(hours=1), changing.site))
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "VALUES (%s, 300, 'WALL_CLOCK', 60, %s, TRUE)", (changing.site, T0 + timedelta(hours=1)))
        one_minute = coarse.read([coarse_asset], T0, T0 + timedelta(hours=1), "1m")
        fifteen = coarse.read([coarse_asset], T0, T0 + timedelta(hours=1), "15m")
        crossing = changing.read([changing_asset], T0, T0 + timedelta(hours=2), "1h")

    # Migration 282 names the cause (281 reported both as RESOLUTION_UNAVAILABLE).
    assert [(r[1], r[11]) for r in one_minute] == [(None, "CAPTURE_INTERVAL_TOO_COARSE")]
    assert len(fifteen) == 4 and {r[11] for r in fifteen} == {None}
    assert [(r[1], r[11]) for r in crossing] == [(None, "CAPTURE_POLICY_CHANGE")]


def test_1m_is_raw_and_only_within_raw_retention(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Raw")
        recent = datetime.now(UTC).replace(second=0, microsecond=0) - timedelta(days=2)
        t.seed(device, recent, recent + timedelta(minutes=10))
        within = t.read([asset], recent, recent + timedelta(minutes=10), "1m")
        outside = t.read([asset], T0, T0 + timedelta(minutes=10), "1m")   # 2025: beyond 180-day raw retention

    assert len(within) == 10
    assert {_d(r[3]) for r in within} == {_d("0.1")}
    assert {(r[7], r[9]) for r in within} == {(1, 1)}
    assert [(r[1], r[11]) for r in outside] == [(None, "BEFORE_RETENTION_FLOOR")]


def test_persisted_history_survives_raw_retention(tx):
    """Intended improvement over the canonical read: once raw rows are gone,
    hourly and daily history is still served from the persisted tiers."""

    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.simple_asset("History")
        t.seed(device, DAY1, DAY1 + timedelta(days=1))
        t.refresh(DAY1, DAY1 + timedelta(days=1))
        checkpoints(cur)
        for table in ("energy_consumption_1min", "energy_consumption_5min"):
            cur.execute(f"DELETE FROM analytics.{table} WHERE device_id = %s", (device,))
        d = t.read([asset], DAY1, DAY1 + timedelta(days=1), "1d")
        h = t.read([asset], DAY1, DAY1 + timedelta(hours=2), "1h")

    assert _d(d[0][3]) == _d("144.0")
    assert [_d(r[3]) for r in h] == [_d("6.0"), _d("6.0")]


def test_daily_row_in_another_timezone_marks_1d_unavailable(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.simple_asset("Timezone")
        t.seed(device, DAY1, DAY1 + timedelta(days=1))
        t.refresh(DAY1, DAY1 + timedelta(days=1))
        checkpoints(cur)
        cur.execute("UPDATE analytics.energy_consumption_daily SET site_timezone = 'UTC' WHERE device_id = %s", (device,))
        d = t.read([asset], DAY1, DAY1 + timedelta(days=1), "1d")
        h = t.read([asset], DAY1, DAY1 + timedelta(hours=1), "1h")

    assert [(r[1], r[11]) for r in d] == [(None, "TIMEZONE_MISMATCH")]
    assert h[0][11] is None and _d(h[0][3]) == _d("6.0")


# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------


def test_unmapped_organization_is_served(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, grafana_map=False)
        asset, device = t.simple_asset("No Grafana")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        cur.execute("SELECT count(*) FROM metadata.grafana_organization_map WHERE organization_id = %s", (t.org,))
        assert cur.fetchone()[0] == 0
        rows = t.read([asset], T0, T0 + timedelta(hours=1), "1h")

    assert _d(rows[0][3]) == _d("6.0") and rows[0][11] is None


def test_tenant_isolation_and_active_only(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        active, device = t.simple_asset("Active")
        draft, _ = t.simple_asset("Draft", lifecycle="DRAFT")
        commissioning, _ = t.simple_asset("Commissioning", lifecycle="COMMISSIONING")
        other = Tenant(cur)
        foreign, _ = other.simple_asset("Foreign")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        own = t.read([active, draft, commissioning, foreign], T0, T0 + timedelta(hours=1), "1h")
        cross = t.read([active], T0, T0 + timedelta(hours=1), "1h", user=other.user)

    assert {r[0] for r in own} == {active}
    assert cross == []


def test_parity_bridge_binding_is_served_and_left_unchanged(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Bridged", start="-infinity")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        cur.execute("SELECT effective_from::text, effective_to::text FROM metadata.asset_points WHERE asset_id = %s ORDER BY 1", (asset,))
        before = cur.fetchall()
        rows = t.read([asset], T0, T0 + timedelta(hours=1), "1d")
        cur.execute("SELECT effective_from::text, effective_to::text FROM metadata.asset_points WHERE asset_id = %s ORDER BY 1", (asset,))
        after = cur.fetchall()

    assert rows[0][11] is None and _d(rows[0][3]) == _d("6.0")
    assert before == after == [("-infinity", None), ("-infinity", None)]


def test_grid_is_gap_filled_and_open_bucket_is_partial(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Open")
        start = datetime.now(UTC).replace(minute=0, second=0, microsecond=0) - timedelta(hours=1)
        t.seed(device, start, start + timedelta(minutes=30))
        t.refresh(start, start + timedelta(minutes=30))
        checkpoints(cur)
        rows = t.read([asset], start, start + timedelta(hours=3), "1h")

    assert len(rows) == 3
    assert _d(rows[0][3]) == _d("3.0") and rows[0][7] == 30 and rows[0][9] == 60
    assert rows[1][10] is True                     # the current hour has not ended
    assert rows[2][3] is None and rows[2][7] == 0 and rows[2][10] is True


def test_invalid_arguments(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, _ = t.simple_asset("Args")
        cur.execute("SAVEPOINT s")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            t.read([asset], T0, T0 + timedelta(hours=1), "5m")
        cur.execute("ROLLBACK TO SAVEPOINT s")
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            t.read([asset], T0, T0, "1h")
        cur.execute("ROLLBACK TO SAVEPOINT s")


# ---------------------------------------------------------------------------
# Parity with the canonical read (mapped tenant)
# ---------------------------------------------------------------------------


def test_parity_with_canonical_read_15m_and_1d(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata", grafana_map=True)
        asset, device = t.simple_asset("Parity")
        start = datetime(2025, 6, 1, 18, 30, tzinfo=UTC)      # 2025-06-02 00:00 IST
        t.seed(device, start, start + timedelta(days=2), imp="0.13", exp="0.007")
        t.refresh(start, start + timedelta(days=2))
        checkpoints(cur)
        mine15 = t.read([asset], start, start + timedelta(days=2), "15m")
        cur.execute(
            "SELECT interval_start, import_consumption_kwh, export_consumption_kwh, import_quality_status, export_quality_status, "
            "valid_import_intervals + invalid_import_intervals, valid_export_intervals + invalid_export_intervals "
            "FROM analytics.get_canonical_energy_read(%s, %s, %s, %s, '15m', 'strict') ORDER BY 1",
            (t.grafana_org, asset, start, start + timedelta(days=2)))
        canon15 = cur.fetchall()
        mine1d = t.read([asset], start, start + timedelta(days=2), "1d")
        cur.execute(
            "SELECT interval_start, import_consumption_kwh, export_consumption_kwh, valid_import_intervals + invalid_import_intervals "
            "FROM analytics.get_canonical_energy_read(%s, %s, %s, %s, '1d', 'strict') ORDER BY 1",
            (t.grafana_org, asset, start, start + timedelta(days=2)))
        canon1d = cur.fetchall()

    assert [(r[1], r[3], r[4], r[5], r[6], r[7], r[8]) for r in mine15] == canon15
    assert [(r[1], r[3], r[4], r[7]) for r in mine1d] == canon1d
