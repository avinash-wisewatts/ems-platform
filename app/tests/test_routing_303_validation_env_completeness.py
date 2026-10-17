"""Tests for the V6 environment completeness block of
scripts/diagnostics/routing_303_post_deploy_validation.sql.

environment_measurements.bucket_start is the site capture bucket (1 minute on a
60 s policy, 5 minutes on a 300 s one), and AirSense devices do not always
report on a bucket boundary. The block maps every source device-minute to the
bucket the loader assigns it and requires that bucket to be routed; samples
not yet due (received after the forward checkpoint, or in a bucket still open
when that run started) are pending, not missing.

The block is read from the script itself and run against the disposable
ems_test database (see conftest.py) inside one transaction that is rolled
back, after routing the fixture with the real environment loader.
"""
import os
import re
import time
import uuid
from datetime import timedelta
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
ENV = "telemetry.load_environment_measurements_incremental"
PIPELINE = "environment_measurements"
PIPELINE_JOBS = (
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_routing_late_sweep_job",
)
# The pre-fix V6 environment leg: 5-minute bins of the source, routed row
# required exactly at the bin start.
OLD_FIVE_MINUTE_SQL = """
    WITH env_src AS (
        SELECT DISTINCT np.device_id, date_bin('5 minutes', np.event_time, TIMESTAMPTZ '2000-01-01') AS b
        FROM telemetry.normalized_points np
        WHERE np.device_id = %(dev)s AND np.event_time >= %(v6_from)s AND np.event_time < %(v6_to)s
    ),
    env_dst AS (
        SELECT DISTINCT device_id, bucket_start AS b FROM telemetry.environment_measurements
        WHERE device_id = %(dev)s AND bucket_start >= %(v6_from)s AND bucket_start < %(v6_to)s
    )
    SELECT count(*) FILTER (WHERE d.b IS NULL) FROM env_src s LEFT JOIN env_dst d USING (device_id, b)
"""


def _script_block():
    text = SCRIPT.read_text(encoding="utf-8").replace("\r", "")
    block = text.split("-- V6-ENV-BEGIN", 1)[1].split("-- V6-ENV-END", 1)[0]
    lines = [ln for ln in block.splitlines()[1:] if not ln.lstrip().startswith(("--", "\\"))]
    return "\n".join(lines).strip().rstrip(";")


def _env_sql(device_id):
    """The script's block, psql variables bound as parameters and the source
    restricted to the fixture device (the test DB holds other tests' data)."""
    sql = _script_block().replace(":'v6_from'", "%(v6_from)s").replace(":'v6_to'", "%(v6_to)s")
    marker = "AND dp.profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'"
    assert sql.count(marker) == 1
    return sql.replace(marker, marker + " AND np.device_id = %(dev)s"), device_id


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


def _airsense(conn, capture_seconds):
    """An AirSense device on its own site with a capture_seconds policy."""
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev")}
    tag = uuid.uuid4().hex[:8].upper()
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"TV6 Org {tag}", f"TV6_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
                 (ids["site"], ids["org"], f"TV6 Site {tag}", f"TV6_SITE_{tag}"))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"TV6 GW {tag}", f"TV6-GW-{tag}"))
    conn.execute(
        """
        INSERT INTO config.telemetry_capture_policies
            (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
        VALUES (%s, %s, 'WALL_CLOCK', 900, now() - INTERVAL '90 days', TRUE)
        """,
        (ids["site"], capture_seconds),
    )
    prof = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'")
    assert prof, "fixture assumption: the AirSense profile is seeded"
    ids["uid"] = f"TV6-AIRSENSE-{tag}"
    conn.execute(
        "INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id) VALUES (%s, %s, %s, %s, %s, %s)",
        (ids["dev"], ids["org"], ids["gw"], ids["uid"], ids["uid"], prof[0]),
    )
    lp = dict(conn.execute(
        "SELECT name, id FROM metadata.logical_points WHERE name IN ('ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY')"
    ).fetchall())
    assert len(lp) == 2
    ids["points"] = [("ENV_TEMPERATURE", lp["ENV_TEMPERATURE"], 21.5), ("ENV_RELATIVE_HUMIDITY", lp["ENV_RELATIVE_HUMIDITY"], 45.0)]
    return ids


def _sample(conn, ids, event_time, received):
    for name, lp_id, value in ids["points"]:
        conn.execute(
            """
            INSERT INTO telemetry.normalized_points
                (event_time, organization_id, site_id, gateway_id, device_id, logical_point_id, device_uid,
                 logical_point, numeric_value, quality_code, platform_received_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'GOOD', %s)
            """,
            (event_time, ids["org"], ids["site"], ids["gw"], ids["dev"], lp_id, ids["uid"], name, value, received),
        )


def _route(conn):
    """One forward run of the environment loader from a recent checkpoint."""
    now = _one(conn, "SELECT now()")[0]
    conn.execute("UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s",
                 (now - timedelta(minutes=2), PIPELINE))
    conn.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
    conn.execute(f"CALL {ENV}(INTERVAL '15 minutes', NULL)")
    assert _one(conn, "SELECT last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))[0] == "SUCCESS"


def _window(conn, hours_after=0):
    """The script's window, three closed hours (optionally extended)."""
    to = _one(conn, "SELECT date_trunc('hour', now())")[0]
    return to - timedelta(hours=3), to + timedelta(hours=hours_after)


def _check(conn, ids, v6_from, v6_to):
    sql, dev = _env_sql(ids["dev"])
    row = conn.execute(sql, {"v6_from": v6_from, "v6_to": v6_to, "dev": dev}).fetchone()
    domain, source_minutes, source_buckets, missing_minutes, missing_buckets, pending = row
    assert domain == "environment"
    return {"source_minutes": source_minutes, "source_buckets": source_buckets,
            "missing_minutes": missing_minutes, "missing_buckets": missing_buckets, "pending": pending}


def _old_missing(conn, ids, v6_from, v6_to):
    return _one(conn, OLD_FIVE_MINUTE_SQL, {"v6_from": v6_from, "v6_to": v6_to, "dev": ids["dev"]})[0]


# ---------------------------------------------------------------------------


def test_script_counts_the_points_the_environment_loader_routes(tx):
    """The script's logical-point list is the deployed loader's list."""
    src = _one(tx, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (f"{ENV}(interval,interval)",))[0]
    loader_list = src.replace("\r", "").split("np.logical_point IN", 1)[1].split(")", 1)[0]
    script_list = _script_block().split("np.logical_point IN", 1)[1].split(")", 1)[0]
    assert set(re.findall(r"'([A-Z0-9_]+)'", script_list)) == set(re.findall(r"'([A-Z0-9_]+)'", loader_list))


def test_irregular_reporting_on_a_one_minute_policy_is_complete(tx):
    """The staging case (2026-10-17): samples only at :19:24 and :37-:39 of the
    5-minute bins starting :15 and :35. Each minute is routed in its own 1-minute
    bucket, so nothing is missing; the old 5-minute-boundary check reported 2."""
    ids = _airsense(tx, 60)
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    events = [v6_from + timedelta(minutes=19, seconds=24)] + [
        v6_from + timedelta(minutes=m, seconds=24) for m in (37, 38, 39)]
    for e in events:
        _sample(tx, ids, e, now - timedelta(seconds=30))
    _route(tx)

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 4, "source_buckets": 4, "missing_minutes": 0, "missing_buckets": 0, "pending": 0}
    assert _old_missing(tx, ids, v6_from, v6_to) == 2


def test_irregular_reporting_on_a_five_minute_policy_is_complete(tx):
    """Off-boundary samples on a 300 s policy land in the 5-minute bucket that
    contains them; minutes inside one bucket share it."""
    ids = _airsense(tx, 300)
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    for offset in (timedelta(minutes=3, seconds=24), timedelta(minutes=4, seconds=50),
                   timedelta(minutes=17, seconds=5), timedelta(hours=1, minutes=58, seconds=59)):
        _sample(tx, ids, v6_from + offset, now - timedelta(seconds=30))
    _route(tx)

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 4, "source_buckets": 3, "missing_minutes": 0, "missing_buckets": 0, "pending": 0}


def test_a_routed_minute_that_disappears_is_missing(tx):
    ids = _airsense(tx, 60)
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    for m in (10, 11, 12):
        _sample(tx, ids, v6_from + timedelta(minutes=m, seconds=7), now - timedelta(seconds=30))
    _route(tx)
    assert _check(tx, ids, v6_from, v6_to)["missing_minutes"] == 0

    tx.execute("DELETE FROM telemetry.environment_measurements WHERE device_id = %s AND bucket_start = %s",
               (ids["dev"], v6_from + timedelta(minutes=11)))
    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 3, "source_buckets": 3, "missing_minutes": 1, "missing_buckets": 1, "pending": 0}


def test_a_due_minute_the_loader_never_routed_is_missing(tx):
    """A sample received before the forward checkpoint but absent from the
    routed table (a skipped row) is missing, whether or not it is on a
    5-minute boundary."""
    ids = _airsense(tx, 60)
    v6_from, v6_to = _window(tx)
    now = _one(tx, "SELECT now()")[0]
    _sample(tx, ids, v6_from + timedelta(minutes=40, seconds=5), now - timedelta(seconds=30))
    _route(tx)
    ckpt = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))[0]
    for m in (41, 45):
        _sample(tx, ids, v6_from + timedelta(minutes=m, seconds=5), ckpt - timedelta(seconds=1))

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 3, "source_buckets": 3, "missing_minutes": 2, "missing_buckets": 2, "pending": 0}


def test_samples_not_yet_due_are_pending_not_missing(tx):
    """Received after the forward checkpoint, or in a bucket still open when the
    forward run started: pending, never missing."""
    ids = _airsense(tx, 60)
    v6_from, v6_to = _window(tx, hours_after=2)
    now = _one(tx, "SELECT now()")[0]
    _sample(tx, ids, v6_from + timedelta(minutes=5, seconds=1), now - timedelta(seconds=30))
    _sample(tx, ids, now + timedelta(minutes=30), now - timedelta(seconds=30))   # bucket open at run time
    _route(tx)
    _sample(tx, ids, v6_from + timedelta(minutes=6, seconds=1), now + timedelta(minutes=1))  # after checkpoint

    assert _check(tx, ids, v6_from, v6_to) == {
        "source_minutes": 1, "source_buckets": 1, "missing_minutes": 0, "missing_buckets": 0, "pending": 2}
