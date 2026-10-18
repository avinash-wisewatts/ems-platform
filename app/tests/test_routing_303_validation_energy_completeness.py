"""Tests for the V6 window and the V6 energy completeness block of
scripts/diagnostics/routing_303_post_deploy_validation.sql.

The window is the last three closed UTC hours, whatever the session time zone
(staging runs Asia/Kolkata, where date_trunc('hour', now()) is a half hour in
UTC). The energy block maps every source device-minute to the capture bucket
the energy loader assigns it and requires that bucket to be routed; samples
not yet due (received after the forward checkpoint, or in a bucket still open
when that run started) are pending, not missing.

2026-10-18 05:32 UTC on staging: the pre-fix check, window 02:30-05:30 UTC,
reported 200 missing = 54 + 54 + 38 + 54 device-minutes at 05:26-05:29 UTC, all
received after the forward checkpoint (05:26:24). test_reported_false_misses
reproduces that shape.

The blocks are read from the script itself and run against the disposable
ems_test database (see conftest.py) inside one transaction that is rolled
back, after routing the fixture with the real energy loader.
"""
import os
import time
import uuid
from datetime import timedelta, timezone
from pathlib import Path

import psycopg
import pytest

DB_HOST = os.environ["EMS_APP_DB_HOST"]
DB_PORT = os.environ["EMS_APP_DB_PORT"]
DB_NAME = os.environ["EMS_APP_DB_NAME"]
DB_USER = os.environ["EMS_APP_DB_USER"]
DB_PASSWORD = os.environ["EMS_APP_DB_PASSWORD"]

CONNINFO = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD}"
)

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "diagnostics" / "routing_303_post_deploy_validation.sql"
ENERGY = "telemetry.load_energy_measurements_incremental"
PIPELINE = "energy_measurements"
PIPELINE_JOBS = (
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_routing_late_sweep_job",
)
# The pre-fix V6 window (session time zone) and energy leg (1-minute bins of
# the source, routed row required at the bin start, no pending split).
OLD_WINDOW_SQL = "SELECT date_trunc('hour', now()) - INTERVAL '3 hours', date_trunc('hour', now())"
OLD_ENERGY_SQL = """
    WITH energy_src AS (
        SELECT DISTINCT np.device_id, date_bin('1 minute', np.event_time, TIMESTAMPTZ '2000-01-01') AS b
        FROM telemetry.normalized_points np
        WHERE np.device_id = ANY(%(devs)s) AND np.event_time >= %(v6_from)s AND np.event_time < %(v6_to)s
          AND np.logical_point = 'ENERGY_IMPORT_TOTAL' AND np.quality_code = 'GOOD'
    ),
    energy_dst AS (
        SELECT DISTINCT device_id, bucket_start AS b FROM telemetry.energy_measurements
        WHERE device_id = ANY(%(devs)s) AND bucket_start >= %(v6_from)s AND bucket_start < %(v6_to)s
    )
    SELECT count(*) FILTER (WHERE d.b IS NULL) FROM energy_src s LEFT JOIN energy_dst d USING (device_id, b)
"""


def _script_text():
    return SCRIPT.read_text(encoding="utf-8").replace("\r", "")


def _window_sql():
    """The script's \\gset window query, without the meta-command."""
    line = next(ln for ln in _script_text().splitlines() if ln.rstrip().endswith("\\gset"))
    return line.rsplit("\\gset", 1)[0].strip()


def _energy_sql():
    """The script's energy block, psql variables bound as parameters and the
    source restricted to the fixture devices (the test DB holds other tests' data)."""
    block = _script_text().split("-- V6-ENERGY-BEGIN", 1)[1].split("-- V6-ENERGY-END", 1)[0]
    lines = [ln for ln in block.splitlines()[1:] if not ln.lstrip().startswith(("--", "\\"))]
    sql = "\n".join(lines).strip().rstrip(";")
    sql = sql.replace(":'v6_from'", "%(v6_from)s").replace(":'v6_to'", "%(v6_to)s")
    marker = "AND dp.profile_code = 'ENERGY_METER_ENISCOPE_V1'"
    assert sql.count(marker) == 1
    return sql.replace(marker, marker + " AND np.device_id = ANY(%(devs)s)")


@pytest.fixture(scope="module", autouse=True)
def quiesce_pipeline_jobs():
    """Pause normalization, both routing jobs and the sweep for this module and
    restore their scheduled state afterwards."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        jobs = c.execute(
            """
            SELECT j.job_id, j.scheduled, s.next_start
            FROM timescaledb_information.jobs AS j
            JOIN timescaledb_information.job_stats AS s USING (job_id)
            WHERE j.proc_name = ANY(%s)
            """,
            (list(PIPELINE_JOBS),),
        ).fetchall()
        for job_id, _, _ in jobs:
            c.execute("SELECT alter_job(%s, scheduled => false)", (job_id,))
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and c.execute(
            "SELECT count(*) FROM timescaledb_information.job_stats WHERE job_id = ANY(%s) AND job_status = 'Running'",
            ([j[0] for j in jobs],),
        ).fetchone()[0]:
            time.sleep(1)
    yield
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        for job_id, scheduled, next_start in jobs:
            if scheduled:
                c.execute(
                    "SELECT alter_job(%s, scheduled => true, next_start => %s)",
                    (job_id, next_start),
                )


@pytest.fixture
def tx():
    """One transaction per test, always rolled back."""
    with psycopg.connect(CONNINFO) as conn:
        try:
            yield conn
        finally:
            conn.rollback()


def _one(conn, sql, params=None):
    return conn.execute(sql, params).fetchone()


def _eniscope_site(conn, capture_seconds, devices=1):
    """Eniscope meters on their own site with a capture_seconds policy."""
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw")}
    tag = uuid.uuid4().hex[:8].upper()
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"TV6E Org {tag}", f"TV6E_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
                 (ids["site"], ids["org"], f"TV6E Site {tag}", f"TV6E_SITE_{tag}"))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"TV6E GW {tag}", f"TV6E-GW-{tag}"))
    conn.execute(
        """
        INSERT INTO config.telemetry_capture_policies
            (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
        VALUES (%s, %s, 'WALL_CLOCK', 900, now() - INTERVAL '90 days', TRUE)
        """,
        (ids["site"], capture_seconds),
    )
    prof = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
    assert prof, "fixture assumption: the Eniscope profile is seeded"
    ids["lp"] = _one(conn, "SELECT id FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL'")[0]
    ids["devs"] = []
    for n in range(devices):
        dev, uid = uuid.uuid4(), f"TV6E-ENISCOPE-{tag}-{n:02d}"
        conn.execute(
            "INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id) VALUES (%s, %s, %s, %s, %s, %s)",
            (dev, ids["org"], ids["gw"], uid, uid, prof[0]),
        )
        ids["devs"].append((dev, uid))
    return ids


def _sample(conn, ids, dev, event_time, received):
    dev_id, uid = dev
    conn.execute(
        """
        INSERT INTO telemetry.normalized_points
            (event_time, organization_id, site_id, gateway_id, device_id, logical_point_id, device_uid,
             logical_point, numeric_value, quality_code, platform_received_at)
        VALUES (%s, %s, %s, %s, %s, %s, %s, 'ENERGY_IMPORT_TOTAL', 1000.0, 'GOOD', %s)
        """,
        (event_time, ids["org"], ids["site"], ids["gw"], dev_id, ids["lp"], uid, received),
    )


def _route(conn):
    """One forward run of the energy loader from a recent checkpoint."""
    now = _one(conn, "SELECT now()")[0]
    conn.execute("UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s",
                 (now - timedelta(minutes=2), PIPELINE))
    conn.execute(f"CALL {ENERGY}(INTERVAL '15 minutes', NULL)")
    assert _one(conn, "SELECT last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))[0] == "SUCCESS"


def _window(conn, hours_after=0):
    """The script's window (optionally extended)."""
    v6_from, v6_to = _one(conn, _window_sql())
    return v6_from, v6_to + timedelta(hours=hours_after)


def _check(conn, ids, v6_from, v6_to):
    row = conn.execute(_energy_sql(), {"v6_from": v6_from, "v6_to": v6_to,
                                       "devs": [d for d, _ in ids["devs"]]}).fetchone()
    domain, source_minutes, source_buckets, missing_minutes, missing_buckets, pending = row
    assert domain == "energy"
    return {"source_minutes": source_minutes, "source_buckets": source_buckets,
            "missing_minutes": missing_minutes, "missing_buckets": missing_buckets, "pending": pending}


def _old_missing(conn, ids, v6_from, v6_to):
    return _one(conn, OLD_ENERGY_SQL, {"v6_from": v6_from, "v6_to": v6_to,
                                       "devs": [d for d, _ in ids["devs"]]})[0]


# ---------------------------------------------------------------------------


@pytest.mark.parametrize("tz", ["UTC", "Asia/Kolkata", "America/St_Johns", "Asia/Kathmandu"])
def test_window_is_three_closed_utc_hours_in_any_session_time_zone(tx, tz):
    tx.execute("SELECT set_config('TimeZone', %s, true)", (tz,))
    v6_from, v6_to = _one(tx, _window_sql())
    now = _one(tx, "SELECT now()")[0]
    to_utc = v6_to.astimezone(timezone.utc)
    assert (to_utc.minute, to_utc.second, to_utc.microsecond) == (0, 0, 0)
    assert timedelta(0) <= now - v6_to < timedelta(hours=1)
    assert v6_to - v6_from == timedelta(hours=3)


def test_old_window_ends_on_a_utc_half_hour_in_asia_kolkata(tx):
    """The defect: the pre-fix window in the staging session time zone."""
    tx.execute("SELECT set_config('TimeZone', 'Asia/Kolkata', true)")
    _, old_to = _one(tx, OLD_WINDOW_SQL)
    assert old_to.astimezone(timezone.utc).minute == 30


def test_reported_false_misses(tx):
    """2026-10-18 05:32 UTC: 54 meters, four minutes just before the old
    window's end, received after the forward checkpoint (one minute from 38
    meters only). The old check reported them as 200 missing; the fixed one
    counts them pending, and in the script's UTC window nothing is missing."""
    tx.execute("SELECT set_config('TimeZone', 'Asia/Kolkata', true)")
    ids = _eniscope_site(tx, 60, devices=54)
    old_from, old_to = _one(tx, OLD_WINDOW_SQL)
    now = _one(tx, "SELECT now()")[0]
    for dev in ids["devs"]:
        for m in range(10, 4, -1):          # routed earlier minutes
            _sample(tx, ids, dev, old_to - timedelta(minutes=m, seconds=-7), now - timedelta(seconds=30))
    _route(tx)
    for n, dev in enumerate(ids["devs"]):
        for m in (4, 3, 2, 1):              # not yet reached by the forward run
            if m == 2 and n >= 38:
                continue
            _sample(tx, ids, dev, old_to - timedelta(minutes=m, seconds=-7), now + timedelta(minutes=1))

    assert _old_missing(tx, ids, old_from, old_to) == 200
    assert _check(tx, ids, old_from, old_to) == {
        "source_minutes": 324, "source_buckets": 324, "missing_minutes": 0, "missing_buckets": 0, "pending": 200}
    v6_from, v6_to = _window(tx)
    assert _check(tx, ids, v6_from, v6_to)["missing_minutes"] == 0


def test_minutes_received_after_the_checkpoint_are_pending(tx):
    ids = _eniscope_site(tx, 60)
    dev = ids["devs"][0]
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    _sample(tx, ids, dev, v6_from + timedelta(minutes=20, seconds=3), now - timedelta(seconds=30))
    _route(tx)
    ckpt = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))[0]
    _sample(tx, ids, dev, v6_from + timedelta(minutes=21, seconds=3), ckpt + timedelta(microseconds=1))
    _sample(tx, ids, dev, v6_from + timedelta(minutes=22, seconds=3), ckpt + timedelta(minutes=5))

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 1, "source_buckets": 1, "missing_minutes": 0, "missing_buckets": 0, "pending": 2}
    assert _old_missing(tx, ids, v6_from, v6_to) == 2


def test_minutes_in_a_bucket_open_at_run_time_are_pending(tx):
    ids = _eniscope_site(tx, 60)
    dev = ids["devs"][0]
    v6_from, v6_to = _window(tx, hours_after=2)
    now = _one(tx, "SELECT now()")[0]
    _sample(tx, ids, dev, v6_from + timedelta(minutes=5, seconds=1), now - timedelta(seconds=30))
    _sample(tx, ids, dev, now + timedelta(minutes=30), now - timedelta(seconds=30))
    _route(tx)

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 1, "source_buckets": 1, "missing_minutes": 0, "missing_buckets": 0, "pending": 1}


def test_a_routed_minute_that_disappears_is_missing(tx):
    ids = _eniscope_site(tx, 60)
    dev = ids["devs"][0]
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    for m in (10, 11, 12):
        _sample(tx, ids, dev, v6_from + timedelta(minutes=m, seconds=7), now - timedelta(seconds=30))
    _route(tx)
    assert _check(tx, ids, v6_from, v6_to)["missing_minutes"] == 0

    tx.execute("DELETE FROM telemetry.energy_measurements WHERE device_id = %s AND bucket_start = %s",
               (dev[0], v6_from + timedelta(minutes=11)))
    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 3, "source_buckets": 3, "missing_minutes": 1, "missing_buckets": 1, "pending": 0}


def test_a_due_minute_the_loader_never_routed_is_missing(tx):
    """Received at or before the forward checkpoint in a closed bucket but
    absent from energy_measurements: missing."""
    ids = _eniscope_site(tx, 60)
    dev = ids["devs"][0]
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    _sample(tx, ids, dev, v6_from + timedelta(minutes=40, seconds=5), now - timedelta(seconds=30))
    _route(tx)
    ckpt = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))[0]
    _sample(tx, ids, dev, v6_from + timedelta(minutes=41, seconds=5), ckpt - timedelta(seconds=1))
    _sample(tx, ids, dev, v6_from + timedelta(minutes=45, seconds=5), ckpt)

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 3, "source_buckets": 3, "missing_minutes": 2, "missing_buckets": 2, "pending": 0}


def test_five_minute_policy_uses_the_loaders_capture_bucket(tx):
    """On a 300 s policy the loader routes one row per 5-minute bucket; minutes
    inside a routed bucket are complete (the old 1-minute check flagged every
    minute that is not a bucket start)."""
    ids = _eniscope_site(tx, 300)
    dev = ids["devs"][0]
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    for offset in (timedelta(minutes=3, seconds=24), timedelta(minutes=4, seconds=50),
                   timedelta(minutes=17, seconds=5), timedelta(hours=1, minutes=58, seconds=59)):
        _sample(tx, ids, dev, v6_from + offset, now - timedelta(seconds=30))
    _route(tx)

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 4, "source_buckets": 3, "missing_minutes": 0, "missing_buckets": 0, "pending": 0}
    assert _old_missing(tx, ids, v6_from, v6_to) == 4
