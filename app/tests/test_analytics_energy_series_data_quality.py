"""Migration 282: the Analytics Data Quality contract of
analytics.get_portal_asset_energy_series and the site-aware
analytics.get_analytics_energy_resolution_floors.

Covers the site-local 30m/1h grid (D24), per-direction interval counts,
assigned expected intervals, data state, first/last data bounds, the
device's first-ever INITIAL reading, stale, and the site-aware retention
floors. Energy VALUES and tier composition are covered, unchanged, by
test_asset_energy_tier_read.py.

Runs against the disposable ems_test database; every test is one rolled-back
transaction.
"""

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, FAR, T0, Tenant, _d, checkpoints

SIG = "analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text, timestamptz)"
OLD_SIG = "analytics.get_portal_asset_energy_series(bigint, uuid, uuid[], timestamptz, timestamptz, text)"
FLOORS_SIG = "analytics.get_analytics_energy_resolution_floors(uuid, timestamptz)"
UTC = timezone.utc
STAGE_SQL = """
    SELECT SUM(si) + MAX(eo)
    FROM (
        SELECT j.proc_name, MAX(j.schedule_interval) AS si, MAX((j.config ->> 'end_offset')::interval) AS eo
        FROM timescaledb_information.jobs AS j
        WHERE (j.proc_schema, j.proc_name) IN (('telemetry', 'run_normalization_job'),
                                               ('telemetry', 'run_energy_routing_job'),
                                               ('analytics', 'run_energy_consumption_1min_job'))
           OR (j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = 'ca_energy_1min')
        GROUP BY j.proc_schema, j.proc_name
    ) AS st
"""


def dq(t: Tenant, assets, start, end, resolution, *, as_of=None, user=None) -> list[dict]:
    t.cur.execute(
        f"SELECT * FROM {SIG.split('(')[0]}(%s, %s, %s::uuid[], %s, %s, %s, %s)",
        (user or t.user, t.site, list(assets), start, end, resolution, as_of),
    )
    names = [c.name for c in t.cur.description]
    return [dict(zip(names, row)) for row in t.cur.fetchall()]


def seed_rows(t: Tenant, device: str, minutes, *, quality="GOOD", valid=True, imp="0.1", exp="0.01"):
    """Insert native 1-minute rows at the given UTC instants."""

    for m in minutes:
        t.cur.execute(
            """
            INSERT INTO analytics.energy_consumption_1min (
                bucket_start, organization_id, site_id, device_id,
                import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, import_rollover_detected,
                export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, export_rollover_detected,
                gap_detected)
            VALUES (%s, %s, %s, %s, %s, %s, %s, FALSE, FALSE, %s, %s, %s, FALSE, FALSE, FALSE)
            """,
            (m, t.org, t.site, device,
             Decimal(imp) if valid else None, quality, valid,
             Decimal(exp) if valid else None, quality, valid),
        )


def minutes(start: datetime, end: datetime, *, skip=()) -> list[datetime]:
    out, t = [], start
    while t < end:
        if t not in skip:
            out.append(t)
        t += timedelta(minutes=1)
    return out


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


# ---------------------------------------------------------------------------
# Contract / security
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [SIG, FLOORS_SIG])
def test_functions_are_definer_stable_ems_app_only_and_never_grafana_keyed(sig):
    with psycopg.connect(CONNINFO) as connection:
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
        old = connection.execute("SELECT to_regprocedure(%s)", (OLD_SIG,)).fetchone()[0]
        old_floors = connection.execute(
            "SELECT to_regprocedure('analytics.get_analytics_energy_resolution_floors()')"
        ).fetchone()[0]
    assert row[:7] == (True, "s", "ems_admin", True, False, False, True)
    for forbidden in ("grafana", "get_canonical_energy_read", "v_energy_reporting", "primary_meter",
                      "pipeline_reconciliation", "insert into", "update ", "delete from"):
        assert forbidden not in row[7], forbidden
    assert old is None
    assert old_floors is not None


def test_stale_reads_live_job_settings_not_checkpoints_or_operator_margin():
    with psycopg.connect(CONNINFO) as connection:
        body = connection.execute("SELECT lower(pg_get_functiondef(%s::regprocedure))", (SIG,)).fetchone()[0]
    assert "timescaledb_information.jobs" in body
    assert "resolve_site_capture_bucket" in body
    for forbidden in ("pipeline_health", "cagg_overshoot", "120 seconds"):
        assert forbidden not in body


# ---------------------------------------------------------------------------
# D24: site-local grid
# ---------------------------------------------------------------------------


def test_ist_1h_is_on_local_hours_and_sums_the_15_minute_rows(tx):
    """IST (+05:30): local hours start on :30 UTC. Each is the sum of its four
    15-minute rows; the UTC hourly tier is never used (proved by corrupting it)."""

    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kolkata")
        asset, device = t.simple_asset("IST hours")
        t.seed(device, T0, T0 + timedelta(hours=3))
        t.refresh(T0, T0 + timedelta(hours=3))
        checkpoints(cur)
        cur.execute("UPDATE analytics.energy_consumption_hourly SET import_consumption_kwh = 999 WHERE device_id = %s", (device,))
        hours = dq(t, [asset], T0, T0 + timedelta(hours=3), "1h", as_of=FAR)
        quarters = dq(t, [asset], T0 - timedelta(minutes=30), T0 + timedelta(hours=3, minutes=30), "15m", as_of=FAR)
        halves = dq(t, [asset], T0, T0 + timedelta(hours=3), "30m", as_of=FAR)
        day = dq(t, [asset], T0, T0 + timedelta(hours=3), "1d", as_of=FAR)

    # 05:30 IST .. 08:30 IST -> local hours 05:00 .. 08:00 (whole buckets).
    assert [r["bucket_start"] for r in hours] == [T0 + timedelta(minutes=30 + 60 * i) - timedelta(hours=1) for i in range(4)]
    assert all((r["bucket_end"] - r["bucket_start"]) == timedelta(hours=1) for r in hours)
    assert [_d(r["import_kwh"]) for r in hours] == [_d("3.0"), _d("6.0"), _d("6.0"), _d("3.0")]
    by_hour = {}
    for q in quarters:
        key = next(h["bucket_start"] for h in hours if h["bucket_start"] <= q["bucket_start"] < h["bucket_end"])
        by_hour[key] = by_hour.get(key, Decimal(0)) + (q["import_kwh"] or 0)
    assert {k: _d(v) for k, v in by_hour.items()} == {h["bucket_start"]: _d(h["import_kwh"]) for h in hours}
    # IST 30m is on the UTC 30-minute grid (05:30 is a multiple of 30 minutes).
    assert [r["bucket_start"] for r in halves] == [T0 + timedelta(minutes=30 * i) for i in range(6)]
    assert _d(sum(r["import_kwh"] for r in hours)) == _d(day[0]["import_kwh"]) == _d("18.0")


def test_kathmandu_30m_and_1h_use_local_boundaries(tx):
    """+05:45: local 30m and 1h boundaries are not UTC boundaries."""

    with tx.cursor() as cur:
        t = Tenant(cur, tz="Asia/Kathmandu")
        asset, device = t.simple_asset("Kathmandu")
        t.seed(device, T0, T0 + timedelta(hours=2))
        t.refresh(T0, T0 + timedelta(hours=2))
        checkpoints(cur)
        halves = dq(t, [asset], T0, T0 + timedelta(hours=2), "30m", as_of=FAR)
        hours = dq(t, [asset], T0, T0 + timedelta(hours=2), "1h", as_of=FAR)

    # T0 is 05:45 local: 30m buckets start at 05:30 local (T0 - 15 min), 1h at 05:00 (T0 - 45 min).
    assert [r["bucket_start"] for r in halves] == [T0 - timedelta(minutes=15) + timedelta(minutes=30 * i) for i in range(5)]
    assert [r["bucket_start"] for r in hours] == [T0 - timedelta(minutes=45) + timedelta(hours=i) for i in range(3)]
    assert [_d(r["import_kwh"]) for r in hours] == [_d("1.5"), _d("6.0"), _d("4.5")]
    assert _d(sum(r["import_kwh"] or 0 for r in halves)) == _d("12.0")


@pytest.mark.parametrize(
    ("day_start", "hours_in_day", "repeated_local_hour"),
    [
        (datetime(2025, 10, 25, 23, 0, tzinfo=UTC), 25, 1),   # 2025-10-26 Europe/London: 01:00 twice
        (datetime(2025, 3, 30, 0, 0, tzinfo=UTC), 23, None),  # 2025-03-30: 01:00 -> 02:00 skipped
    ],
)
def test_dst_days_have_23_or_25_local_hours_and_the_same_daily_total(tx, day_start, hours_in_day, repeated_local_hour):
    with tx.cursor() as cur:
        t = Tenant(cur, tz="Europe/London")
        asset, device = t.simple_asset("DST")
        end = day_start + timedelta(hours=hours_in_day)
        t.seed(device, day_start, end)
        t.refresh(day_start, end)
        checkpoints(cur)
        hours = dq(t, [asset], day_start, end, "1h", as_of=FAR)
        day = dq(t, [asset], day_start, end, "1d", as_of=FAR)

    assert len(hours) == hours_in_day
    assert len({r["bucket_start"] for r in hours}) == hours_in_day
    assert {_d(r["import_kwh"]) for r in hours} == {_d("6.0")}
    assert _d(day[0]["import_kwh"]) == _d(Decimal("6.0") * hours_in_day)
    if repeated_local_hour is not None:
        cur_local = [r["bucket_start"].astimezone(timezone(timedelta(0))) for r in hours]
        with psycopg.connect(CONNINFO) as connection:
            labels = [connection.execute("SELECT extract(hour FROM %s AT TIME ZONE 'Europe/London')::int", (b,)).fetchone()[0]
                      for b in cur_local]
        assert labels.count(repeated_local_hour) == 2


# ---------------------------------------------------------------------------
# Bucket state / data state / expected intervals
# ---------------------------------------------------------------------------


def test_in_progress_and_future_buckets_at_as_of(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Now")
        # The device's first-ever reading (INITIAL by construction) precedes the range.
        seed_rows(t, device, [T0 - timedelta(minutes=1)], quality="INITIAL", valid=False)
        t.seed(device, T0, T0 + timedelta(minutes=90))
        t.refresh(T0, T0 + timedelta(minutes=90))
        checkpoints(cur)
        rows = dq(t, [asset], T0, T0 + timedelta(hours=3), "1h", as_of=T0 + timedelta(minutes=90))

    assert [r["is_partial"] for r in rows] == [False, True, True]
    assert [r["import_data_state"] for r in rows] == ["MEASURED", "MEASURED", "FUTURE"]
    assert [r["import_assigned_expected_intervals"] for r in rows] == [60, 30, 0]
    assert [r["import_valid_intervals"] for r in rows] == [60, 30, 0]
    assert rows[0]["import_last_data_at"] == T0 + timedelta(minutes=90)


def test_assignment_boundaries(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        late_dev = t.device("Late meter")
        late = t.asset("Assigned mid-range")
        t.bind_both(late, late_dev, start=T0 + timedelta(minutes=30))
        ended_dev = t.device("Ended meter")
        ended = t.asset("Assignment ended")
        t.bind_both(ended, ended_dev, end=T0 + timedelta(minutes=30))
        future_dev = t.device("Future meter")
        future = t.asset("Assigned later")
        t.bind_both(future, future_dev, start=T0 + timedelta(hours=5))
        for dev in (late_dev, ended_dev, future_dev):
            t.seed(dev, T0, T0 + timedelta(hours=2))
        t.refresh(T0, T0 + timedelta(hours=2))
        checkpoints(cur)
        as_of = T0 + timedelta(hours=4)
        rows = dq(t, [late, ended, future], T0, T0 + timedelta(hours=2), "1h", as_of=as_of)

    by = {}
    for r in rows:
        by.setdefault(r["asset_id"], []).append(r)
    lr, er, fr = by[uuid_of(late)], by[uuid_of(ended)], by[uuid_of(future)]
    # Mid-range assignment: the first hour holds only the attributed half.
    assert [(r["import_data_state"], _d(r["import_kwh"]), r["import_assigned_expected_intervals"]) for r in lr] == [
        ("MEASURED", _d("3.0"), 30), ("MEASURED", _d("6.0"), 60)]
    assert lr[0]["import_first_data_at"] == T0 + timedelta(minutes=30)
    # Ended assignment: the second hour is not assigned; data bounds stop at the end; not stale.
    assert [r["import_data_state"] for r in er] == ["MEASURED", "NOT_ASSIGNED"]
    assert er[0]["import_last_data_at"] == T0 + timedelta(minutes=30)
    assert er[0]["import_assigned_in_range"] is True and er[0]["import_stale"] is False
    # Assigned only after the range.
    assert {r["import_data_state"] for r in fr} == {"NOT_ASSIGNED"}
    assert fr[0]["import_assigned_in_range"] is False


def uuid_of(value) -> "object":
    import uuid

    return uuid.UUID(str(value))


def test_device_first_initial_is_not_rejected_but_a_later_initial_is(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Initial")
        seed_rows(t, device, [T0], quality="INITIAL", valid=False)
        later_initial = T0 + timedelta(minutes=20)
        seed_rows(t, device, minutes(T0 + timedelta(minutes=1), T0 + timedelta(minutes=30), skip=(later_initial,)))
        seed_rows(t, device, [later_initial], quality="INITIAL", valid=False)
        t.refresh(T0, T0 + timedelta(minutes=30))
        checkpoints(cur)
        rows = dq(t, [asset], T0, T0 + timedelta(minutes=30), "15m", as_of=FAR)

    first, second = rows
    assert (first["import_valid_intervals"], first["import_invalid_intervals"], first["import_assigned_expected_intervals"]) == (14, 0, 14)
    assert (second["import_valid_intervals"], second["import_invalid_intervals"], second["import_assigned_expected_intervals"]) == (14, 1, 15)
    assert first["import_first_data_at"] == T0


def test_missing_rejected_gap_and_all_rejected_buckets(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Evidence")
        seed_rows(t, device, [T0 - timedelta(minutes=1)], quality="INITIAL", valid=False)   # device's first reading
        missing, gap, rejected = (T0 + timedelta(minutes=m) for m in (5, 6, 10))
        seed_rows(t, device, minutes(T0, T0 + timedelta(minutes=15), skip=(missing, gap, rejected)))
        seed_rows(t, device, [gap], quality="GAP")
        seed_rows(t, device, [rejected], quality="IMPLAUSIBLE_DELTA", valid=False)
        seed_rows(t, device, minutes(T0 + timedelta(minutes=15), T0 + timedelta(minutes=30)), quality="IMPLAUSIBLE_DELTA", valid=False)
        t.refresh(T0, T0 + timedelta(minutes=30))
        checkpoints(cur)
        rows = dq(t, [asset], T0, T0 + timedelta(minutes=30), "15m", as_of=FAR)

    mixed, all_rejected = rows
    assert (mixed["import_valid_intervals"], mixed["import_invalid_intervals"], mixed["import_gap_intervals"],
            mixed["import_assigned_expected_intervals"], mixed["import_data_state"]) == (13, 1, 1, 15, "MEASURED")
    assert _d(mixed["import_kwh"]) == _d("1.3")
    assert (all_rejected["import_kwh"], all_rejected["import_invalid_intervals"],
            all_rejected["import_data_state"]) == (None, 15, "GAP")


# ---------------------------------------------------------------------------
# Stale
# ---------------------------------------------------------------------------


def _stage(cur) -> timedelta:
    cur.execute(STAGE_SQL)
    return cur.fetchone()[0]


def _stale_at(t, asset, as_of) -> bool | None:
    rows = dq(t, [asset], T0, T0 + timedelta(hours=3), "1h", as_of=as_of)
    return rows[0]["import_stale"]


def test_stale_threshold_is_capture_plus_tolerance_plus_live_stages(tx):
    """Staging configuration: 60 s capture; 60 s tolerance (three sites) ->
    7 minutes; 900 s tolerance (default) -> 21 minutes."""

    with tx.cursor() as cur:
        t = Tenant(cur)   # 60 s capture, 60 s tolerance
        asset, device = t.simple_asset("Stale")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        stage = _stage(cur)
        last = T0 + timedelta(hours=1)
        assert stage == timedelta(minutes=5)
        seven = timedelta(seconds=120) + stage
        assert seven == timedelta(minutes=7)
        assert _stale_at(t, asset, last + seven - timedelta(seconds=1)) is False
        assert _stale_at(t, asset, last + seven + timedelta(seconds=1)) is True

        cur.execute("UPDATE config.telemetry_capture_policies SET late_arrival_tolerance_seconds = 900 WHERE site_id = %s", (t.site,))
        twenty_one = timedelta(seconds=960) + stage
        assert twenty_one == timedelta(minutes=21)
        assert _stale_at(t, asset, last + timedelta(minutes=10)) is False
        assert _stale_at(t, asset, last + twenty_one - timedelta(seconds=1)) is False
        assert _stale_at(t, asset, last + twenty_one + timedelta(seconds=1)) is True


def test_stale_uses_the_policy_in_effect_at_last_data(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Policy at last data")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        change = T0 + timedelta(hours=1, minutes=5)
        cur.execute(
            "UPDATE config.telemetry_capture_policies SET late_arrival_tolerance_seconds = 900, effective_to = %s "
            "WHERE site_id = %s", (change, t.site))
        cur.execute(
            "INSERT INTO config.telemetry_capture_policies "
            "(site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled) "
            "VALUES (%s, 60, 'WALL_CLOCK', 60, %s, TRUE)", (t.site, change))
        # 10 minutes after last data: stale under the new 60 s tolerance (7 min),
        # not stale under the 900 s tolerance in effect at last data (21 min).
        assert _stale_at(t, asset, T0 + timedelta(hours=1, minutes=10)) is False


def test_an_unscheduled_stage_still_contributes_its_schedule_interval(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Unscheduled")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        cur.execute(
            "SELECT alter_job(job_id, scheduled => FALSE) FROM timescaledb_information.jobs "
            "WHERE proc_schema = 'telemetry' AND proc_name = 'run_energy_routing_job'")
        last = T0 + timedelta(hours=1)
        assert _stale_at(t, asset, last + timedelta(minutes=7) - timedelta(seconds=1)) is False
        assert _stale_at(t, asset, last + timedelta(minutes=7) + timedelta(seconds=1)) is True


def test_unverified_capture_path_has_no_stale_verdict_and_no_data_is_not_stale(tx):
    with tx.cursor() as cur:
        t = Tenant(cur, capture=900)
        asset, device = t.simple_asset("Quarter-hour capture")
        seed_rows(t, device, [T0 + timedelta(minutes=15 * i) for i in range(4)])
        checkpoints(cur)
        rows = dq(t, [asset], T0, T0 + timedelta(hours=3), "1h", as_of=T0 + timedelta(hours=2))
        empty_asset, _ = t.simple_asset("Never reported")
        empty = dq(t, [empty_asset], T0, T0 + timedelta(hours=3), "1h", as_of=T0 + timedelta(hours=2))

    assert rows[0]["import_stale"] is None
    assert (empty[0]["import_first_data_at"], empty[0]["import_last_data_at"], empty[0]["import_stale"]) == (None, None, False)
    assert {r["import_data_state"] for r in empty} == {"BEFORE_DATA"}
    assert {r["import_assigned_expected_intervals"] for r in empty} == {0}


# ---------------------------------------------------------------------------
# Floors / reconstruction / tenancy
# ---------------------------------------------------------------------------


def test_site_aware_floors_use_the_15m_floor_for_local_1h_off_the_utc_hour(tx):
    with tx.cursor() as cur:
        ist = Tenant(cur, tz="Asia/Kolkata")
        utc = Tenant(cur)
        as_of = datetime(2026, 9, 29, 6, 0, tzinfo=UTC)

        def floors(site):
            cur.execute(f"SELECT resolution, earliest_available FROM {FLOORS_SIG.split('(')[0]}(%s, %s)", (site, as_of))
            return dict(cur.fetchall())

        ist_floors, utc_floors = floors(ist.site), floors(utc.site)
    assert ist_floors["1h"] == ist_floors["15m"]
    assert utc_floors["1h"] != utc_floors["15m"]
    assert {k: v for k, v in ist_floors.items() if k != "1h"} == {k: v for k, v in utc_floors.items() if k != "1h"}


def test_reconstruction_stays_off_and_nothing_is_reconstructed(tx):
    with tx.cursor() as cur:
        cur.execute("SELECT config.energy_reconstruction_enabled(NULL::uuid, NULL::uuid)")
        assert cur.fetchone()[0] is False
        t = Tenant(cur)
        asset, device = t.simple_asset("No reconstruction")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        rows = dq(t, [asset], T0, T0 + timedelta(hours=1), "15m", as_of=FAR)
    assert {(r["import_reconstructed_intervals"], r["export_reconstructed_intervals"]) for r in rows} == {(0, 0)}


def test_data_quality_fields_do_not_cross_tenants(tx):
    with tx.cursor() as cur:
        t = Tenant(cur)
        asset, device = t.simple_asset("Own")
        t.seed(device, T0, T0 + timedelta(hours=1))
        t.refresh(T0, T0 + timedelta(hours=1))
        checkpoints(cur)
        other = Tenant(cur)
        assert dq(t, [asset], T0, T0 + timedelta(hours=1), "1h", as_of=FAR, user=other.user) == []
