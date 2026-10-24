"""Migration 312 (Reports tab): analytics.get_portal_asset_measurements_1m
and the asset-selection create, against the disposable ems_test database.

The 1-minute read must serve exactly the values of the Analytics 1m read
(analytics.get_portal_asset_point_series, migrations 292 / 293) -- GOOD-sample
means, field-mapping units, attribution inside asset_points windows -- for
every point of an asset at once, read per device; report register points
(no 1-minute source); honour the capture policy; and stay portal-scoped.
Every test is one rolled-back transaction.
"""

from __future__ import annotations

from datetime import timedelta
from decimal import Decimal

import psycopg
import pytest

from tests.test_analytics_point_series_read import DAY, LATER, _point_id, _q, _scale, seed_raw, series
from tests.test_asset_energy_tier_read import CONNINFO, Tenant

READ = "analytics.get_portal_asset_measurements_1m"
READ_SIG = f"{READ}(bigint, uuid, uuid, text[], text[], timestamptz, timestamptz, timestamptz)"
CREATE = "analytics.create_portal_report_export_job"
CREATE_SIG = f"{CREATE}(bigint, uuid, timestamptz, timestamptz, text, text, integer, uuid[])"


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


@pytest.fixture
def t(tx):
    return Tenant(tx.cursor())


def read(t: Tenant, asset, specs, start, end, *, as_of=LATER, user=None, site=None):
    """(register indexes, {series index: {minute: value}})."""

    t.cur.execute(
        f"SELECT bucket_start, series_indexes, vals FROM {READ}(%s, %s, %s, %s::text[], %s::text[], %s, %s, %s)",
        (user or t.user, site or t.site, asset, [s[0] for s in specs], [s[1] for s in specs], start, end, as_of),
    )
    rows = t.cur.fetchall()
    registers: set[int] = set()
    values: dict[int, dict] = {}
    for bucket_start, indexes, vals in rows:
        if bucket_start is None:
            registers.update(indexes)
            continue
        for index, value in zip(indexes, vals):
            values.setdefault(index, {})[bucket_start] = value
    return registers, values, rows


def test_function_is_definer_stable_ems_app_only_and_read_only():
    with psycopg.connect(CONNINFO) as connection:
        for sig, volatile in ((READ_SIG, "s"), (CREATE_SIG, "v")):
            row = connection.execute(
                """
                SELECT p.prosecdef, p.provolatile, r.rolname, p.proconfig IS NOT NULL,
                       has_function_privilege('public', p.oid, 'EXECUTE'),
                       has_function_privilege('grafana_reader', p.oid, 'EXECUTE'),
                       has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                       lower(pg_get_functiondef(p.oid))
                FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
                WHERE p.oid = %s::regprocedure
                """,
                (sig,),
            ).fetchone()
            assert row[:7] == (True, volatile, "ems_admin", True, False, False, True), sig
        for forbidden in ("grafana", "insert into", "update ", "delete from", "refresh_continuous"):
            assert forbidden not in connection.execute(
                "SELECT lower(pg_get_functiondef(%s::regprocedure))", (READ_SIG,)
            ).fetchone()[0], forbidden


def test_values_equal_the_analytics_1m_read_for_every_point_of_the_asset(t):
    """Two devices feed one asset; invalid samples, a sample before a
    mid-minute binding start and another asset's sample on the same device
    and point must not count."""

    meter, sensor = t.device("Main meter"), t.device("Room sensor")
    asset, other = t.asset("AHU"), t.asset("Other")
    t.bind(asset, meter, "CURRENT_L1", start=(DAY - timedelta(days=1)).isoformat())
    t.bind(asset, meter, "FREQUENCY", start=(DAY - timedelta(days=1)).isoformat())
    t.bind(asset, sensor, "VOLTAGE_L1", start=(DAY + timedelta(minutes=2, seconds=30)).isoformat())
    current, frequency, voltage = (_point_id(t.cur, n) for n in ("CURRENT_L1", "FREQUENCY", "VOLTAGE_L1"))

    for minute in range(5):
        at = DAY + timedelta(minutes=minute)
        seed_raw(t, meter, current, at + timedelta(seconds=5), 10 + minute)
        seed_raw(t, meter, current, at + timedelta(seconds=35), 20 + minute)
        seed_raw(t, meter, frequency, at + timedelta(seconds=10), Decimal("50.01") + minute)
        seed_raw(t, sensor, voltage, at + timedelta(seconds=20), 230 + minute)   # minute 2: before the binding
    seed_raw(t, meter, current, DAY + timedelta(minutes=1, seconds=50), 99, quality="INVALID_NUMERIC")
    seed_raw(t, meter, frequency, DAY + timedelta(minutes=3, seconds=40), None)   # no numeric value
    # The other asset's device is not this asset's.
    other_meter = t.device("Other meter")
    t.bind(other, other_meter, "CURRENT_L1", start=(DAY - timedelta(days=1)).isoformat())
    seed_raw(t, other_meter, current, DAY + timedelta(seconds=15), 1000)

    specs = [("CURRENT", "L1"), ("FREQUENCY", None), ("VOLTAGE_LINE_NEUTRAL", "L1")]
    start, end = DAY, DAY + timedelta(minutes=5)
    registers, values, _ = read(t, asset, specs, start, end)
    reference = series(t, [(asset, code, qual) for code, qual in specs], start, end, "1m")

    assert registers == set()
    for index in (1, 2, 3):
        expected = {r["bucket_start"]: _q(r["value"]) for r in reference[index] if r["value"] is not None}
        got = {bucket: _q(Decimal(repr(v))) for bucket, v in values.get(index, {}).items()}
        assert got == expected, specs[index - 1]
    assert values[1][DAY] == 15.0                                  # mean of the two GOOD samples
    assert values[1][DAY + timedelta(minutes=1)] == 16.0           # the invalid sample is not counted
    assert sorted(values[3]) == [DAY + timedelta(minutes=m) for m in (3, 4)]   # binding starts 00:02:30


def test_register_points_are_reported_not_read(t):
    asset, device = t.asset("Pump"), t.device("Pump meter")
    for point in ("ENERGY_IMPORT_L1", "ACTIVE_POWER_TOTAL"):
        t.bind(asset, device, point, start=(DAY - timedelta(days=1)).isoformat())
    power = _point_id(t.cur, "ACTIVE_POWER_TOTAL")
    seed_raw(t, device, power, DAY + timedelta(seconds=30), 7000)
    registers, values, rows = read(t, asset, [("ENERGY_IMPORT", "L1"), ("ACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(minutes=2))
    assert registers == {1}
    assert rows[0][0] is None                                      # the register row comes first
    scale, offset, _ = _scale(t.cur, device, power)
    assert values == {2: {DAY: pytest.approx(float(7000 * scale + offset))}}   # in the point's unit


def test_unknown_points_and_unassigned_points_have_no_values(t):
    asset, device = t.asset("Pump"), t.device("Pump meter")
    t.bind(asset, device, "ACTIVE_POWER_TOTAL", start=(DAY - timedelta(days=1)).isoformat())
    seed_raw(t, device, _point_id(t.cur, "FREQUENCY"), DAY + timedelta(seconds=30), 50)   # point not bound
    registers, values, _ = read(t, asset, [("NO_SUCH_POINT", None), ("FREQUENCY", None)], DAY, DAY + timedelta(minutes=2))
    assert (registers, values) == (set(), {})


def test_a_capture_interval_other_than_60_seconds_serves_nothing(tx):
    t = Tenant(tx.cursor(), capture=300)
    asset, device = t.asset("Pump"), t.device("Pump meter")
    t.bind(asset, device, "ACTIVE_POWER_TOTAL", start=(DAY - timedelta(days=1)).isoformat())
    seed_raw(t, device, _point_id(t.cur, "ACTIVE_POWER_TOTAL"), DAY + timedelta(seconds=30), 7)
    registers, values, rows = read(t, asset, [("ACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(minutes=2))
    assert (registers, values, len(rows)) == (set(), {}, 1)


def test_reads_are_portal_scoped(tx):
    t, other = Tenant(tx.cursor()), Tenant(tx.cursor())
    asset, device = t.asset("Pump"), t.device("Pump meter")
    t.bind(asset, device, "ACTIVE_POWER_TOTAL", start=(DAY - timedelta(days=1)).isoformat())
    seed_raw(t, device, _point_id(t.cur, "ACTIVE_POWER_TOTAL"), DAY + timedelta(seconds=30), 7)
    specs = [("ACTIVE_POWER", "TOTAL")]
    assert list(read(t, asset, specs, DAY, DAY + timedelta(minutes=1))[1][1]) == [DAY]
    # Another organization's user, or this asset asked for under another site: nothing at all.
    assert read(t, asset, specs, DAY, DAY + timedelta(minutes=1), user=other.user)[2] == []
    assert read(other, asset, specs, DAY, DAY + timedelta(minutes=1))[2] == []
    # An inactive asset: nothing.
    t.cur.execute("UPDATE metadata.assets SET lifecycle_status = 'DECOMMISSIONED' WHERE id = %s", (asset,))
    assert read(t, asset, specs, DAY, DAY + timedelta(minutes=1))[2] == []


def test_more_than_fifteen_days_is_refused(t):
    asset = t.asset("Pump")
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        read(t, asset, [("ACTIVE_POWER", "TOTAL")], DAY - timedelta(days=15, minutes=1), DAY)


# ---------------------------------------------------------------------------
# Jobs keep their selected assets.
# ---------------------------------------------------------------------------


def _create(t: Tenant, asset_ids, *, user=None):
    t.cur.execute(
        f"SELECT id, asset_ids FROM {CREATE}(%s, %s, %s, %s, 'auto', '1m', 3, %s::uuid[])",
        (user or t.user, t.site, DAY, DAY + timedelta(days=14), asset_ids),
    )
    return t.cur.fetchall()


def test_create_stores_the_selected_assets(t):
    a, b = t.asset("A"), t.asset("B")
    rows = _create(t, [b, a, b])
    assert len(rows) == 1
    assert sorted(str(x) for x in rows[0][1]) == sorted([a, b])


def test_create_refuses_an_asset_that_is_not_an_accessible_asset_of_the_site(tx):
    t, other = Tenant(tx.cursor()), Tenant(tx.cursor())
    a = t.asset("A")
    assert _create(t, [a, other.asset("Elsewhere")]) == []
    assert _create(t, [a, "00000000-0000-0000-0000-000000000312"]) == []
    assert _create(t, []) == []
    assert _create(t, [t.asset("Retired", lifecycle="DECOMMISSIONED")]) == []
    assert _create(t, [a], user=other.user) == []
