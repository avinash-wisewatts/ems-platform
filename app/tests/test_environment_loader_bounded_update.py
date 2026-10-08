"""Tests for migration 291: the environment routing loader's UPDATE is bounded
to the earliest still-correctable candidate bucket_start, so it never
decompresses historical telemetry.environment_measurements chunks.

Background: the unbounded UPDATE decompressed every compressed batch of the
hypertable on every run; on staging (2026-10-08) that reached 109,092 tuples,
over timescaledb.max_tuples_decompressed_per_dml_transaction (100,000), and
every run of the environment routing job failed.

Runs against the disposable ems_test database (see conftest.py). Every
functional test runs inside one transaction that is rolled back, so fixtures,
chunk compression and pipeline_state changes never persist.
"""
import os
import time
import uuid
from datetime import timedelta

import psycopg
import pytest
from psycopg import sql

DB_HOST = os.environ["EMS_APP_DB_HOST"]
DB_PORT = os.environ["EMS_APP_DB_PORT"]
DB_NAME = os.environ["EMS_APP_DB_NAME"]
DB_USER = os.environ["EMS_APP_DB_USER"]
DB_PASSWORD = os.environ["EMS_APP_DB_PASSWORD"]

CONNINFO = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD}"
)

LOADER = "telemetry.load_environment_measurements_incremental"
LOADER_SIG = f"{LOADER}(interval,interval)"
MIGRATION_ID = "291_environment_loader_bounded_update"
BODY_MD5_291 = "d0708b46eb9ab81a6b2cc37ee0d85ef5"
PIPELINE_JOBS = ("run_normalization_job", "run_energy_routing_job", "run_environment_routing_job")
HISTORY_ROWS = 4000
DECOMPRESSION_CAP = 100

# The pre-291 statement shape (migration 267 body), reduced to the columns the
# tests assert on. Same FROM/WHERE as the template minus the 291 floor.
UNBOUNDED_UPDATE = """
    UPDATE telemetry.environment_measurements t
    SET temperature_c = COALESCE(s.temperature_c, t.temperature_c),
        source_timestamp = s.source_timestamp
    FROM {cand} s
    WHERE t.bucket_start = s.bucket_start
      AND t.device_id = s.device_id
      AND COALESCE(s.source_timestamp, s.received_at) >
          COALESCE(t.source_timestamp, t.received_at, '-infinity'::TIMESTAMPTZ)
      AND %(now)s <= s.correction_deadline
    RETURNING t.device_id, t.bucket_start, t.temperature_c, t.source_timestamp
"""

# The migration-291 statement shape: the same UPDATE plus the floor predicate.
BOUNDED_UPDATE = """
    UPDATE telemetry.environment_measurements t
    SET temperature_c = COALESCE(s.temperature_c, t.temperature_c),
        source_timestamp = s.source_timestamp
    FROM {cand} s
    WHERE t.bucket_start >= %(floor)s
      AND t.bucket_start = s.bucket_start
      AND t.device_id = s.device_id
      AND COALESCE(s.source_timestamp, s.received_at) >
          COALESCE(t.source_timestamp, t.received_at, '-infinity'::TIMESTAMPTZ)
      AND %(now)s <= s.correction_deadline
    RETURNING t.device_id, t.bucket_start, t.temperature_c, t.source_timestamp
"""


@pytest.fixture(scope="module", autouse=True)
def quiesce_pipeline_jobs():
    """Pause normalization and both routing jobs for this module (these tests
    set checkpoints and routing data) and restore their scheduled state."""
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


def _airsense_fixture(conn):
    """Org, site, gateway, an AirSense device and a backdated site capture
    policy (300 s WALL_CLOCK, 900 s late-arrival tolerance), as in the
    migration-226 fixture. Returns the ids the tests need."""
    tag = uuid.uuid4().hex[:8].upper()
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev")}
    prof = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENVIRONMENT_SENSOR_AIRSENSE_V1'")
    assert prof, "fixture assumption: the AirSense profile is seeded"
    lp = dict(conn.execute(
        "SELECT name, id FROM metadata.logical_points WHERE name IN ('ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY')"
    ).fetchall())
    assert len(lp) == 2, "fixture assumption: AirSense logical points are seeded"
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"T291 Org {tag}", f"T291_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
                 (ids["site"], ids["org"], f"T291 Site {tag}", f"T291_SITE_{tag}"))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"T291 GW {tag}", f"T291-GW-{tag}"))
    conn.execute(
        "INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id) VALUES (%s, %s, %s, %s, %s, %s)",
        (ids["dev"], ids["org"], ids["gw"], f"T291 AirSense {tag}", f"T291-AIRSENSE-{tag}", prof[0]),
    )
    conn.execute(
        """
        INSERT INTO config.telemetry_capture_policies
            (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
        VALUES (%s, 300, 'WALL_CLOCK', 900, now() - INTERVAL '60 days', TRUE)
        """,
        (ids["site"],),
    )
    ids["uid"] = f"T291-AIRSENSE-{tag}"
    ids["lp_temp"], ids["lp_hum"] = lp["ENV_TEMPERATURE"], lp["ENV_RELATIVE_HUMIDITY"]
    return ids


def _seed_compressed_history(conn, ids, rows=HISTORY_ROWS):
    """rows already-routed rows 40 days back, then compress every chunk older
    than 8 days (rolled back with the test). Returns the compressed row count."""
    conn.execute(
        """
        INSERT INTO telemetry.environment_measurements
            (bucket_start, received_at, source_timestamp, organization_id, site_id, device_id, temperature_c)
        SELECT ts, ts, ts, %s, %s, %s, 20.0
        FROM generate_series(1, %s) AS g,
             LATERAL (SELECT date_bin('5 minutes', now() - INTERVAL '40 days', TIMESTAMPTZ '2000-01-01')
                             + g * INTERVAL '5 minutes' AS ts) AS x
        """,
        (ids["org"], ids["site"], ids["dev"], rows),
    )
    conn.execute(
        """
        SELECT compress_chunk(c, if_not_compressed => true)
        FROM show_chunks('telemetry.environment_measurements', older_than => INTERVAL '8 days') AS c
        """
    )
    compressed = _one(
        conn,
        """
        SELECT count(*) FROM timescaledb_information.chunks
        WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'environment_measurements' AND is_compressed
        """,
    )[0]
    assert compressed >= 1, "fixture must produce at least one compressed chunk"
    return _one(conn, "SELECT count(*) FROM telemetry.environment_measurements WHERE device_id = %s AND bucket_start < now() - INTERVAL '8 days'", (ids["dev"],))[0]


def _correctable_bucket(conn):
    """A closed 5-minute bucket still inside its correction window:
    bucket_start + 300 s <= now and bucket_start + 300 s + 900 s >= now."""
    return _one(conn, "SELECT date_bin('5 minutes', now() - INTERVAL '7 minutes', TIMESTAMPTZ '2000-01-01')")[0]


# ---------------------------------------------------------------------------
# Deployed definition (contract)
# ---------------------------------------------------------------------------


def test_deployed_loader_is_the_migration_291_body(tx):
    md5, src = _one(
        tx,
        "SELECT md5(replace(prosrc, E'\\r', '')), prosrc FROM pg_proc WHERE oid = %s::regprocedure",
        (LOADER_SIG,),
    )
    assert md5 == BODY_MD5_291
    assert _one(tx, "SELECT count(*) FROM admin.schema_migrations WHERE migration_id = %s", (MIGRATION_ID,))[0] == 1
    src = src.replace("\r", "")
    assert src.count("SELECT min(bucket_start) INTO v_update_floor") == 1
    assert src.count("WHERE v_now <= correction_deadline;") == 1
    assert src.count("IF v_update_floor IS NOT NULL THEN") == 1
    assert src.count("WHERE t.bucket_start >= v_update_floor") == 1
    assert "EXECUTE " not in src and "format(" not in src
    assert "plan_cache_mode" not in src


# ---------------------------------------------------------------------------
# Regression: the real loader over compressed history with a tight cap
# ---------------------------------------------------------------------------


def test_loader_updates_over_compressed_history_without_hitting_the_decompression_cap(tx):
    ids = _airsense_fixture(tx)
    history = _seed_compressed_history(tx, ids)
    assert history == HISTORY_ROWS

    bucket = _correctable_bucket(tx)
    event = bucket + timedelta(seconds=60)
    # Already-routed row for the bucket, with an older sample.
    tx.execute(
        """
        INSERT INTO telemetry.environment_measurements
            (bucket_start, received_at, source_timestamp, organization_id, site_id, device_id, temperature_c)
        VALUES (%s, %s, %s, %s, %s, %s, 20.0)
        """,
        (bucket, bucket + timedelta(seconds=5), bucket + timedelta(seconds=5), ids["org"], ids["site"], ids["dev"]),
    )
    # A newer sample for the same bucket arrives.
    received = _one(tx, "SELECT now() - INTERVAL '30 seconds'")[0]
    tx.execute(
        """
        INSERT INTO telemetry.normalized_points
            (event_time, organization_id, site_id, device_id, logical_point_id, device_uid, logical_point,
             numeric_value, quality_code, platform_received_at)
        VALUES (%s, %s, %s, %s, %s, %s, 'ENV_TEMPERATURE', 25.0, 'GOOD', %s),
               (%s, %s, %s, %s, %s, %s, 'ENV_RELATIVE_HUMIDITY', 48.0, 'GOOD', %s)
        """,
        (event, ids["org"], ids["site"], ids["dev"], ids["lp_temp"], ids["uid"], received,
         event, ids["org"], ids["site"], ids["dev"], ids["lp_hum"], ids["uid"], received),
    )
    tx.execute(
        "UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = 'environment_measurements'",
        (received - timedelta(minutes=10),),
    )

    tx.execute(f"SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = {DECOMPRESSION_CAP}")
    tx.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
    tx.execute(f"CALL {LOADER}(INTERVAL '5 minutes', NULL)")

    status = _one(tx, "SELECT last_status FROM telemetry.pipeline_state WHERE pipeline_name = 'environment_measurements'")[0]
    assert status == "SUCCESS"
    temp, src_ts, n = _one(
        tx,
        """
        SELECT max(temperature_c), max(source_timestamp), count(*)
        FROM telemetry.environment_measurements WHERE device_id = %s AND bucket_start = %s
        """,
        (ids["dev"], bucket),
    )
    assert n == 1
    assert temp == pytest.approx(25.0), "the correctable row must have been updated with the newer sample"
    assert src_ts == event

    # Control: the pre-291 statement over the same candidates and history hits the cap.
    with pytest.raises(psycopg.Error, match="tuple decompression limit exceeded"):
        with tx.transaction():
            tx.execute(UNBOUNDED_UPDATE.format(cand="tmp_environment_candidates"), {"now": _one(tx, "SELECT now()")[0]})


# ---------------------------------------------------------------------------
# Behavioural equivalence: same rows changed, same values
# ---------------------------------------------------------------------------


def _candidates(conn, ids, now):
    """A mixed candidate set (temp table t291_cand), including rows the UPDATE
    must change and rows it must not:
      A correctable, newer sample            -> updated
      B correctable, older sample            -> not updated
      C deadline passed, recent chunk        -> not updated
      D deadline passed, compressed history  -> not updated
      E correctable, no existing row         -> nothing to update
    """
    a = _correctable_bucket(conn)
    b = a - timedelta(minutes=5)
    c = a - timedelta(hours=6)
    d = _one(conn, "SELECT min(bucket_start) FROM telemetry.environment_measurements WHERE device_id = %s", (ids["dev"],))[0]
    e = a - timedelta(minutes=10)
    existing = [(a, a + timedelta(seconds=5)), (b, b + timedelta(seconds=120)), (c, c + timedelta(seconds=5))]
    for bucket, src in existing:
        conn.execute(
            """
            INSERT INTO telemetry.environment_measurements
                (bucket_start, received_at, source_timestamp, organization_id, site_id, device_id, temperature_c)
            VALUES (%s, %s, %s, %s, %s, %s, 20.0)
            """,
            (bucket, src, src, ids["org"], ids["site"], ids["dev"]),
        )
    conn.execute(
        """
        CREATE TEMP TABLE t291_cand (
            bucket_start TIMESTAMPTZ, device_id UUID, source_timestamp TIMESTAMPTZ,
            received_at TIMESTAMPTZ, correction_deadline TIMESTAMPTZ, temperature_c DOUBLE PRECISION
        ) ON COMMIT DROP
        """
    )
    late = timedelta(seconds=1200)
    rows = [
        (a, ids["dev"], a + timedelta(seconds=60), now, a + late, 25.0),          # A
        (b, ids["dev"], b + timedelta(seconds=60), now, b + late, 26.0),          # B (older than existing 120 s)
        (c, ids["dev"], c + timedelta(seconds=60), now, c + late, 27.0),          # C (deadline long passed)
        (d, ids["dev"], d + timedelta(seconds=60), now, d + late, 28.0),          # D (compressed, deadline passed)
        (e, ids["dev"], e + timedelta(seconds=60), now, e + late, 29.0),          # E (no row)
    ]
    with conn.cursor() as cur:
        cur.executemany("INSERT INTO t291_cand VALUES (%s, %s, %s, %s, %s, %s)", rows)
    return {"A": a, "B": b, "C": c, "D": d, "E": e}


def _run_both(conn, now):
    """Run the unbounded and the bounded statement on identical state (each in
    a savepoint that is rolled back) and return their RETURNING sets."""
    floor = _one(conn, "SELECT min(bucket_start) FROM t291_cand WHERE %s <= correction_deadline", (now,))[0]

    results = {}
    for name in ("unbounded", "bounded"):
        try:
            with conn.transaction():
                if name == "unbounded":
                    rows = conn.execute(UNBOUNDED_UPDATE.format(cand="t291_cand"), {"now": now}).fetchall()
                elif floor is None:
                    rows = []  # migration 291 skips the UPDATE entirely
                else:
                    rows = conn.execute(BOUNDED_UPDATE.format(cand="t291_cand"), {"now": now, "floor": floor}).fetchall()
                results[name] = sorted(rows)
                raise _Rollback
        except _Rollback:
            pass
    return floor, results["unbounded"], results["bounded"]


def test_bounded_update_changes_exactly_the_rows_the_unbounded_update_changes(tx):
    ids = _airsense_fixture(tx)
    _seed_compressed_history(tx, ids)
    now = _one(tx, "SELECT now()")[0]
    buckets = _candidates(tx, ids, now)

    floor, unbounded, bounded = _run_both(tx, now)
    assert floor is not None
    assert bounded == unbounded
    assert [r[1] for r in bounded] == [buckets["A"]], "only the correctable, newer candidate is updated"
    assert bounded[0][2] == pytest.approx(25.0)


def test_no_correctable_candidate_skips_the_update_with_the_same_outcome(tx):
    ids = _airsense_fixture(tx)
    _seed_compressed_history(tx, ids)
    now = _one(tx, "SELECT now()")[0]
    _candidates(tx, ids, now)
    later = now + timedelta(days=1)  # every candidate's correction window has closed

    floor, unbounded, bounded = _run_both(tx, later)
    assert floor is None
    assert unbounded == [] and bounded == []


# ---------------------------------------------------------------------------
# Plan evidence: decompression counters from EXPLAIN ANALYZE
# ---------------------------------------------------------------------------


class _Rollback(Exception):
    pass


def _explain_analyze_rolled_back(conn, query):
    """EXPLAIN ANALYZE executes the statement; run it in a savepoint that is
    always rolled back so it leaves no data or decompression behind."""
    plan = ""
    try:
        with conn.transaction():
            plan = "\n".join(
                r[0] for r in conn.execute(
                    sql.SQL("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) ") + query
                ).fetchall()
            )
            raise _Rollback
    except _Rollback:
        pass
    return plan


def test_explain_analyze_bounded_update_decompresses_nothing_even_with_a_generic_plan(tx):
    ids = _airsense_fixture(tx)
    history = _seed_compressed_history(tx, ids)
    now = _one(tx, "SELECT now()")[0]
    _candidates(tx, ids, now)
    floor = _one(tx, "SELECT min(bucket_start) FROM t291_cand WHERE %s <= correction_deadline", (now,))[0]

    # Control: the unbounded statement decompresses the whole history.
    plan = _explain_analyze_rolled_back(
        tx,
        sql.SQL(
            "UPDATE telemetry.environment_measurements t SET temperature_c = s.temperature_c "
            "FROM t291_cand s WHERE t.bucket_start = s.bucket_start AND t.device_id = s.device_id"
        ),
    )
    assert "Tuples decompressed" in plan, plan
    decompressed = int(plan.split("Tuples decompressed:")[1].split()[0])
    assert decompressed >= history, plan

    # The bounded statement, as a cached generic plan (the PL/pgSQL worst case).
    tx.execute("SET LOCAL plan_cache_mode = force_generic_plan")
    tx.execute(
        "PREPARE t291_bounded(timestamptz) AS "
        "UPDATE telemetry.environment_measurements t SET temperature_c = s.temperature_c "
        "FROM t291_cand s WHERE t.bucket_start >= $1 AND t.bucket_start = s.bucket_start AND t.device_id = s.device_id"
    )
    try:
        plan = _explain_analyze_rolled_back(
            tx, sql.SQL("EXECUTE t291_bounded({})").format(sql.Literal(floor))
        )
    finally:
        tx.execute("DEALLOCATE t291_bounded")
    assert "Tuples decompressed" not in plan, plan
    assert "Batches decompressed" not in plan, plan
