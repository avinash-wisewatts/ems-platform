"""Tests for migration 303: routing forward reads bounded to uncompressed
telemetry.normalized_points chunks, plus the hourly late-data sweep.

Forward scope (the scheduled routing jobs) adds event_time >= the newest
compressed chunk's range_end to the window read, so chunk exclusion skips every
compressed chunk. The late-sweep scope (ems.routing_scope = 'late_sweep', set
transaction-locally by telemetry.run_routing_late_sweep_job) reads only rows
below that floor, with its own checkpoint, never passing the forward one.

Runs against the disposable ems_test database (see conftest.py). Functional
tests run inside one transaction that is rolled back, so fixtures, chunk
compression and checkpoints never persist. The one end-to-end wrapper test
commits (the wrapper COMMITs per loader) and restores the checkpoints after.
"""
import os
import time
import uuid
from datetime import timedelta

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

MIGRATION_ID = "303_routing_forward_floor_late_sweep"
ENERGY = "telemetry.load_energy_measurements_incremental"
ENV = "telemetry.load_environment_measurements_incremental"
# Migration 305 (recovery scope) builds on the 303 bodies; reverting its
# fragments gives back the 303 bodies (305's postconditions and
# test_routing_generator_contract.py). The 303 fragments are checked below.
BODY_MD5 = {
    ENERGY: "9b035f4a55edbf99ec2a5db4bb173d09",
    ENV: "d2d906d4da78eeba3740b2b0d082a237",
}
PIPELINE = {ENERGY: "energy_measurements", ENV: "environment_measurements"}
PIPELINE_JOBS = (
    "run_normalization_job",
    "run_energy_routing_job",
    "run_environment_routing_job",
    "run_routing_late_sweep_job",
)
DECOMPRESSION_NODES = ("ColumnarScan", "DecompressChunk")

FLOOR_SQL = """
    SELECT COALESCE(max(c.range_end), '-infinity'::timestamptz)
    FROM timescaledb_information.chunks c
    WHERE c.hypertable_schema = 'telemetry' AND c.hypertable_name = 'normalized_points' AND c.is_compressed
"""
# The forward window read of both loaders, reduced to its normalized_points part.
WINDOW_SQL = (
    "SELECT np.device_id, np.event_time, max(np.platform_received_at) "
    "FROM telemetry.normalized_points np "
    "WHERE np.platform_received_at > $1 AND np.platform_received_at <= $2 "
    "{bound}GROUP BY np.device_id, np.event_time"
)
BOUNDED = "AND np.event_time >= $3 AND np.event_time < $4 "


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


def _now(conn):
    return _one(conn, "SELECT now()")[0]


# ---------------------------------------------------------------------------
# Fixtures: an AirSense device (environment) and an Eniscope meter (energy)
# ---------------------------------------------------------------------------


def _site(conn, tag, ids, capture_seconds, tolerance_seconds):
    conn.execute("INSERT INTO metadata.organizations (id, name, code) VALUES (%s, %s, %s)",
                 (ids["org"], f"T303 Org {tag}", f"T303_ORG_{tag}"))
    conn.execute("INSERT INTO metadata.sites (id, organization_id, name, code) VALUES (%s, %s, %s, %s)",
                 (ids["site"], ids["org"], f"T303 Site {tag}", f"T303_SITE_{tag}"))
    conn.execute("INSERT INTO metadata.gateways (id, organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s, %s)",
                 (ids["gw"], ids["org"], ids["site"], f"T303 GW {tag}", f"T303-GW-{tag}"))
    conn.execute(
        """
        INSERT INTO config.telemetry_capture_policies
            (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
        VALUES (%s, %s, 'WALL_CLOCK', %s, now() - INTERVAL '90 days', TRUE)
        """,
        (ids["site"], capture_seconds, tolerance_seconds),
    )


def _device(conn, ids, profile_code, label):
    prof = _one(conn, "SELECT id FROM config.device_profiles WHERE profile_code = %s", (profile_code,))
    assert prof, f"fixture assumption: profile {profile_code} is seeded"
    ids["uid"] = f"T303-{label}-{uuid.uuid4().hex[:8].upper()}"
    conn.execute(
        "INSERT INTO metadata.devices (id, organization_id, gateway_id, name, external_id, profile_id) VALUES (%s, %s, %s, %s, %s, %s)",
        (ids["dev"], ids["org"], ids["gw"], ids["uid"], ids["uid"], prof[0]),
    )


def _env_fixture(conn):
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev")}
    _site(conn, uuid.uuid4().hex[:8].upper(), ids, 300, 900)
    _device(conn, ids, "ENVIRONMENT_SENSOR_AIRSENSE_V1", "AIRSENSE")
    lp = dict(conn.execute(
        "SELECT name, id FROM metadata.logical_points WHERE name IN ('ENV_TEMPERATURE','ENV_RELATIVE_HUMIDITY')"
    ).fetchall())
    assert len(lp) == 2
    ids["points"] = [("ENV_TEMPERATURE", lp["ENV_TEMPERATURE"], 21.5), ("ENV_RELATIVE_HUMIDITY", lp["ENV_RELATIVE_HUMIDITY"], 45.0)]
    ids["loader"], ids["table"], ids["grain"] = ENV, "telemetry.environment_measurements", timedelta(minutes=5)
    return ids


def _energy_fixture(conn):
    ids = {k: uuid.uuid4() for k in ("org", "site", "gw", "dev")}
    _site(conn, uuid.uuid4().hex[:8].upper(), ids, 60, 60)
    _device(conn, ids, "ENERGY_METER_ENISCOPE_V1", "ENISCOPE")
    lp = _one(conn, "SELECT id FROM metadata.logical_points WHERE name = 'ENERGY_IMPORT_TOTAL'")[0]
    ids["points"] = [("ENERGY_IMPORT_TOTAL", lp, 1000.0)]
    ids["loader"], ids["table"], ids["grain"] = ENERGY, "telemetry.energy_measurements", timedelta(minutes=1)
    return ids


FIXTURES = {"energy": _energy_fixture, "environment": _env_fixture}


def _sample(conn, ids, event_time, received, value_offset=0.0):
    """Normalized samples of every fixture point at event_time, received at received."""
    for name, lp_id, value in ids["points"]:
        conn.execute(
            """
            INSERT INTO telemetry.normalized_points
                (event_time, organization_id, site_id, gateway_id, device_id, logical_point_id, device_uid,
                 logical_point, numeric_value, quality_code, platform_received_at)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'GOOD', %s)
            """,
            (event_time, ids["org"], ids["site"], ids["gw"], ids["dev"], lp_id, ids["uid"],
             name, value + value_offset, received),
        )


def _bucket(conn, ids, event_time):
    return _one(conn, "SELECT date_bin(%s, %s, TIMESTAMPTZ '2000-01-01')", (ids["grain"], event_time))[0]


def _routed(conn, ids, bucket):
    return _one(conn, f"SELECT count(*) FROM {ids['table']} WHERE device_id = %s AND bucket_start = %s",
                (ids["dev"], bucket))[0]


def _state(conn, pipeline):
    return _one(conn, "SELECT last_received_at, last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s",
                (pipeline,))


def _set_ckpt(conn, pipeline, ts):
    conn.execute("UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s", (ts, pipeline))


def _forward(conn, ids, max_window=None):
    conn.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
    conn.execute(f"CALL {ids['loader']}(INTERVAL '15 minutes', %s)", (max_window,))
    return _state(conn, PIPELINE[ids["loader"]])


def _sweep(conn, ids, max_window=timedelta(days=1)):
    conn.execute("SELECT set_config('ems.routing_scope', 'late_sweep', true)")
    try:
        conn.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
        conn.execute(f"CALL {ids['loader']}(INTERVAL '15 minutes', %s)", (max_window,))
    finally:
        conn.execute("SELECT set_config('ems.routing_scope', '', true)")
    return _state(conn, PIPELINE[ids["loader"]] + "_late_sweep")


def _compress_old_normalized_chunks(conn, older_than="30 days"):
    conn.execute(
        f"""
        SELECT compress_chunk(c, if_not_compressed => true)
        FROM show_chunks('telemetry.normalized_points', older_than => INTERVAL '{older_than}') AS c
        """
    )
    floor = _one(conn, FLOOR_SQL)[0]
    assert floor is not None and floor != float("-inf")
    return floor


def _late_old_row(conn, ids):
    """A sample 40 days old, its chunk compressed, then the same device's late
    sample (also 40 days old) received now: it lands in a compressed chunk."""
    now = _now(conn)
    seed_event = now - timedelta(days=40)
    _sample(conn, ids, seed_event, seed_event)
    floor = _compress_old_normalized_chunks(conn)
    late_event = _bucket(conn, ids, now - timedelta(days=40)) + ids["grain"] + timedelta(seconds=10)
    assert late_event < floor
    received = now - timedelta(seconds=30)
    _sample(conn, ids, late_event, received)
    return late_event, received, floor


# ---------------------------------------------------------------------------
# Deployed definitions
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("proc", [ENERGY, ENV])
def test_deployed_loader_is_the_migration_303_body(tx, proc):
    md5, src = _one(tx, "SELECT md5(replace(prosrc, E'\\r', '')), prosrc FROM pg_proc WHERE oid = %s::regprocedure",
                    (f"{proc}(interval,interval)",))
    assert md5 == BODY_MD5[proc]
    src = src.replace("\r", "")
    assert src.count("np.event_time >= v_event_min") == 1
    assert src.count("np.event_time < v_event_max") == 1
    assert src.count("current_setting('ems.routing_scope', true)") == 1
    assert "EXECUTE " not in src and "format(" not in src and "plan_cache_mode" not in src
    assert _one(tx, "SELECT count(*) FROM admin.schema_migrations WHERE migration_id = %s", (MIGRATION_ID,))[0] == 1


def test_late_sweep_job_is_registered_hourly_at_31_30_utc(tx):
    rows = tx.execute(
        """
        SELECT schedule_interval, fixed_schedule, max_runtime, max_retries, retry_period, config,
               extract(epoch FROM initial_start)::bigint % 3600
        FROM timescaledb_information.jobs
        WHERE proc_schema = 'telemetry' AND proc_name = 'run_routing_late_sweep_job'
        """
    ).fetchall()
    assert len(rows) == 1
    interval, fixed, max_runtime, retries, retry_period, config, phase = rows[0]
    assert (interval, fixed, max_runtime, retries, retry_period) == (
        timedelta(hours=1), True, timedelta(minutes=10), 3, timedelta(minutes=5))
    assert config == {"overlap": "15 minutes", "max_window": "1 day"}
    assert phase == 31 * 60 + 30
    assert _one(tx, "SELECT has_function_privilege('public', 'telemetry.run_routing_late_sweep_job(integer,jsonb)', 'EXECUTE')")[0] is False


def test_late_sweep_checkpoint_rows_exist(tx):
    names = {r[0] for r in tx.execute(
        "SELECT pipeline_name FROM telemetry.pipeline_state WHERE pipeline_name LIKE '%\\_late\\_sweep'").fetchall()}
    assert names == {"energy_measurements_late_sweep", "environment_measurements_late_sweep"}
    # Seeded SUCCESS (verify_pipeline.sh requires every row to be SUCCESS); a
    # sweep may since have run, so only the never-failed states are accepted.
    statuses = {r[0] for r in tx.execute(
        "SELECT last_status FROM telemetry.pipeline_state WHERE pipeline_name LIKE '%\\_late\\_sweep'").fetchall()}
    assert statuses <= {"SUCCESS", "NO_SOURCE_DATA"}, statuses


def test_existing_routing_jobs_are_untouched(tx):
    rows = tx.execute(
        "SELECT proc_name, config FROM timescaledb_information.jobs "
        "WHERE proc_name IN ('run_energy_routing_job', 'run_environment_routing_job')"
    ).fetchall()
    assert len(rows) == 2
    for _, config in rows:
        assert set(config) == {"overlap", "max_window"}


# ---------------------------------------------------------------------------
# Query plans
# ---------------------------------------------------------------------------


def _explain_analyze(conn, prepared, args):
    return "\n".join(
        r[0] for r in conn.execute(
            f"EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE {prepared}({args})"
        ).fetchall()
    )


def test_forward_window_read_skips_every_compressed_chunk_with_a_generic_plan(tx):
    ids = _env_fixture(tx)
    now = _now(tx)
    for days in (40, 33):
        _sample(tx, ids, now - timedelta(days=days), now - timedelta(days=days))
    _sample(tx, ids, now - timedelta(minutes=10), now - timedelta(minutes=9))
    floor = _compress_old_normalized_chunks(tx)
    start, end = now - timedelta(hours=1), now

    tx.execute("SET LOCAL plan_cache_mode = force_generic_plan")
    tx.execute("PREPARE t303_unbounded(timestamptz, timestamptz) AS " + WINDOW_SQL.format(bound=""))
    tx.execute("PREPARE t303_bounded(timestamptz, timestamptz, timestamptz, timestamptz) AS " + WINDOW_SQL.format(bound=BOUNDED))
    try:
        control = _explain_analyze(tx, "t303_unbounded", f"'{start}', '{end}'")
        bounded = _explain_analyze(tx, "t303_bounded", f"'{start}', '{end}', '{floor}', 'infinity'")
    finally:
        tx.execute("DEALLOCATE t303_unbounded")
        tx.execute("DEALLOCATE t303_bounded")
    # Control: the pre-303 read visits the compressed chunks.
    assert any(node in control for node in DECOMPRESSION_NODES), control
    # The bounded read excludes them at executor startup.
    assert not any(node in bounded for node in DECOMPRESSION_NODES), bounded
    assert "Chunks excluded during startup" in bounded, bounded


def test_sweep_window_read_reads_only_below_the_floor(tx):
    ids = _env_fixture(tx)
    late_event, received, floor = _late_old_row(tx, ids)
    _sample(tx, ids, _now(tx) - timedelta(minutes=10), received)
    rows = tx.execute(
        WINDOW_SQL.format(bound=BOUNDED).replace("$1", "%s").replace("$2", "%s").replace("$3", "%s").replace("$4", "%s"),
        (received - timedelta(minutes=1), received, "-infinity", floor),
    ).fetchall()
    assert [r[1] for r in rows] == [late_event]


# ---------------------------------------------------------------------------
# Late arrivals
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("domain", FIXTURES)
def test_late_row_in_a_compressed_chunk_is_routed_by_the_sweep_not_the_forward_run(tx, domain):
    ids = FIXTURES[domain](tx)
    late_event, received, _ = _late_old_row(tx, ids)
    pipeline = PIPELINE[ids["loader"]]
    _set_ckpt(tx, pipeline, received - timedelta(minutes=5))
    _set_ckpt(tx, pipeline + "_late_sweep", received - timedelta(minutes=5))

    ckpt, status = _forward(tx, ids)
    assert status == "SUCCESS" and ckpt == received
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 0, "forward runs skip compressed chunks"

    sckpt, sstatus = _sweep(tx, ids)
    assert sstatus == "SUCCESS" and sckpt == received
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 1, "the sweep routes the late row"


@pytest.mark.parametrize("domain", FIXTURES)
def test_late_row_in_an_uncompressed_chunk_is_routed_by_the_forward_run(tx, domain):
    ids = FIXTURES[domain](tx)
    now = _now(tx)
    _sample(tx, ids, now - timedelta(days=40), now - timedelta(days=40))
    floor = _compress_old_normalized_chunks(tx)
    event = _bucket(tx, ids, now - timedelta(days=2)) + timedelta(seconds=10)  # 2 days late
    assert event >= floor
    received = now - timedelta(seconds=30)
    _sample(tx, ids, event, received)
    _set_ckpt(tx, PIPELINE[ids["loader"]], received - timedelta(minutes=5))

    ckpt, status = _forward(tx, ids)
    assert (ckpt, status) == (received, "SUCCESS")
    assert _routed(tx, ids, _bucket(tx, ids, event)) == 1


def test_sweep_never_passes_the_forward_checkpoint(tx):
    ids = _env_fixture(tx)
    late_event, received, _ = _late_old_row(tx, ids)
    _set_ckpt(tx, "environment_measurements", received - timedelta(minutes=5))   # forward has not reached it
    _set_ckpt(tx, "environment_measurements_late_sweep", received - timedelta(minutes=10))

    sckpt, status = _sweep(tx, ids)
    assert status == "SUCCESS"
    assert sckpt == received - timedelta(minutes=5), "capped at the forward checkpoint"
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 0

    _forward(tx, ids)
    sckpt, _ = _sweep(tx, ids)
    assert sckpt == received
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 1


def test_sweep_checkpoint_never_moves_backwards(tx):
    ids = _env_fixture(tx)
    now = _now(tx)
    _set_ckpt(tx, "environment_measurements", now - timedelta(hours=2))
    _set_ckpt(tx, "environment_measurements_late_sweep", now - timedelta(hours=1))   # ahead (manual edit)
    _sample(tx, ids, now - timedelta(minutes=5), now - timedelta(minutes=4))
    sckpt, status = _sweep(tx, ids)
    assert status == "SUCCESS" and sckpt == now - timedelta(hours=1)


# ---------------------------------------------------------------------------
# Catch-up, idempotency, retries, locking
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("domain", FIXTURES)
def test_backlog_catch_up_routes_every_bucket_in_bounded_steps(tx, domain):
    ids = FIXTURES[domain](tx)
    now = _now(tx)
    first = _bucket(tx, ids, now - timedelta(hours=5))
    events = [first + i * timedelta(minutes=15) + timedelta(seconds=10) for i in range(16)]   # 4 h of data
    for e in events:
        _sample(tx, ids, e, e + timedelta(seconds=20))
    _set_ckpt(tx, PIPELINE[ids["loader"]], first - timedelta(minutes=1))

    checkpoints = []
    for _ in range(4):
        ckpt, status = _forward(tx, ids, timedelta(hours=1))
        assert status == "SUCCESS"
        checkpoints.append(ckpt)
    assert checkpoints == sorted(checkpoints) and len(set(checkpoints)) == 4, "advances 1 h per run"
    _forward(tx, ids, timedelta(hours=1))
    assert all(_routed(tx, ids, _bucket(tx, ids, e)) == 1 for e in events)


@pytest.mark.parametrize("domain", FIXTURES)
def test_rerunning_forward_and_sweep_changes_nothing(tx, domain):
    ids = FIXTURES[domain](tx)
    late_event, received, _ = _late_old_row(tx, ids)
    # Normal ingestion continues after the late row. (The forward window end is
    # the newest receipt among recent events -- migration 267 -- so the late
    # row is inside the forward window only once newer recent data exists.)
    recent = _bucket(tx, ids, _now(tx) - timedelta(minutes=30)) + timedelta(seconds=10)
    _sample(tx, ids, recent, received + timedelta(seconds=5))
    pipeline = PIPELINE[ids["loader"]]
    _set_ckpt(tx, pipeline, received - timedelta(minutes=5))
    _set_ckpt(tx, pipeline + "_late_sweep", received - timedelta(minutes=5))
    assert _forward(tx, ids)[0] == received + timedelta(seconds=5)
    assert _sweep(tx, ids)[0] == received + timedelta(seconds=5)
    snapshot = tx.execute(f"SELECT * FROM {ids['table']} WHERE device_id = %s ORDER BY bucket_start", (ids["dev"],)).fetchall()
    assert len(snapshot) == 2

    # Replay the same windows (as a retry after an unknown outcome would).
    _set_ckpt(tx, pipeline, received - timedelta(minutes=5))
    _set_ckpt(tx, pipeline + "_late_sweep", received - timedelta(minutes=5))
    _forward(tx, ids)
    _sweep(tx, ids)
    again = tx.execute(f"SELECT * FROM {ids['table']} WHERE device_id = %s ORDER BY bucket_start", (ids["dev"],)).fetchall()
    assert again == snapshot


def test_failed_sweep_leaves_both_checkpoints_unchanged(tx):
    ids = _env_fixture(tx)
    late_event, received, _ = _late_old_row(tx, ids)
    _set_ckpt(tx, "environment_measurements", received)
    _set_ckpt(tx, "environment_measurements_late_sweep", received - timedelta(minutes=5))
    before = (_state(tx, "environment_measurements")[0], _state(tx, "environment_measurements_late_sweep")[0])

    with pytest.raises(psycopg.errors.RaiseException, match="ems.routing_scope must be forward, late_sweep or recovery"):
        with tx.transaction():
            tx.execute("SELECT set_config('ems.routing_scope', 'bogus', true)")
            tx.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
            tx.execute(f"CALL {ENV}(INTERVAL '15 minutes', INTERVAL '1 day')")
    tx.execute("SELECT set_config('ems.routing_scope', '', true)")
    # A failure inside the sweep's routing statement also rolls back with its checkpoint.
    with pytest.raises(psycopg.Error):
        with tx.transaction():
            tx.execute("SET LOCAL statement_timeout = '1ms'")
            _sweep(tx, ids)
    after = (_state(tx, "environment_measurements")[0], _state(tx, "environment_measurements_late_sweep")[0])
    assert after == before
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 0

    _sweep(tx, ids)   # the retry succeeds
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 1


@pytest.mark.parametrize("proc", [ENERGY, ENV])
@pytest.mark.parametrize("scope", ["forward", "late_sweep"])
def test_sweep_and_forward_share_the_loader_lock(tx, proc, scope):
    pipeline = PIPELINE[proc] + ("_late_sweep" if scope == "late_sweep" else "")
    before = _state(tx, pipeline)[0]
    with psycopg.connect(CONNINFO, autocommit=True) as holder:
        holder.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", (proc,))
        try:
            if scope == "late_sweep":
                tx.execute("SELECT set_config('ems.routing_scope', 'late_sweep', true)")
            tx.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
            tx.execute(f"CALL {proc}(INTERVAL '15 minutes', INTERVAL '1 day')")
            tx.execute("SELECT set_config('ems.routing_scope', '', true)")
        finally:
            holder.execute("SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (proc,))
    ckpt, status = _state(tx, pipeline)
    assert status == "SKIPPED_LOCKED"
    assert ckpt == before


def test_unset_scope_is_the_forward_scope(tx):
    assert _one(tx, "SELECT current_setting('ems.routing_scope', true)")[0] in (None, "")
    ids = _env_fixture(tx)
    now = _now(tx)
    _sample(tx, ids, now - timedelta(minutes=12), now - timedelta(minutes=11))
    _set_ckpt(tx, "environment_measurements", now - timedelta(minutes=20))
    sweep_before = _state(tx, "environment_measurements_late_sweep")
    ckpt, status = _forward(tx, ids)
    assert status == "SUCCESS" and ckpt == now - timedelta(minutes=11)
    assert _state(tx, "environment_measurements_late_sweep") == sweep_before


# ---------------------------------------------------------------------------
# Demand input completeness
# ---------------------------------------------------------------------------


def test_energy_forward_routing_keeps_every_minute_of_a_closed_demand_interval(tx):
    """Demand finalizes up to max(energy_measurements.bucket_start) (migration
    210). Every minute of the last closed quarter-hour must be routed by the
    bounded forward run, with compressed history present."""
    ids = _energy_fixture(tx)
    now = _now(tx)
    _sample(tx, ids, now - timedelta(days=40), now - timedelta(days=40))
    _compress_old_normalized_chunks(tx)
    q_end = _one(tx, "SELECT date_bin('15 minutes', now() - INTERVAL '2 minutes', TIMESTAMPTZ '2000-01-01')")[0]
    q_start = q_end - timedelta(minutes=15)
    for i in range(15):
        e = q_start + timedelta(minutes=i, seconds=5)
        _sample(tx, ids, e, e + timedelta(seconds=15), value_offset=float(i))
    _set_ckpt(tx, "energy_measurements", q_start - timedelta(minutes=1))

    _, status = _forward(tx, ids)
    assert status == "SUCCESS"
    n, max_bucket = _one(
        tx,
        "SELECT count(*), max(bucket_start) FROM telemetry.energy_measurements "
        "WHERE device_id = %s AND bucket_start >= %s AND bucket_start < %s",
        (ids["dev"], q_start, q_end),
    )
    assert n == 15
    assert max_bucket == q_end - timedelta(minutes=1)
    assert _one(tx, "SELECT max(bucket_start) FROM telemetry.energy_measurements")[0] >= max_bucket


# ---------------------------------------------------------------------------
# The job procedure, end to end (commits; checkpoints restored afterwards)
# ---------------------------------------------------------------------------


def test_job_procedure_sweeps_both_loaders_and_does_not_leak_its_scope():
    names = ("energy_measurements_late_sweep", "environment_measurements_late_sweep",
             "energy_measurements", "environment_measurements",
             "energy_measurements_recovery", "environment_measurements_recovery")
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        saved = c.execute(
            "SELECT pipeline_name, last_received_at, last_status, last_started_at, last_completed_at, "
            "last_inserted_rows, last_error FROM telemetry.pipeline_state WHERE pipeline_name = ANY(%s)",
            (list(names),),
        ).fetchall()
        try:
            c.execute("CALL telemetry.run_routing_late_sweep_job(0, '{\"max_window\": \"1 day\"}'::jsonb)")
            statuses = dict(c.execute(
                "SELECT pipeline_name, last_status FROM telemetry.pipeline_state WHERE pipeline_name = ANY(%s)",
                (list(names[:2]),),
            ).fetchall())
            assert set(statuses.values()) <= {"SUCCESS", "NO_SOURCE_DATA"}, statuses
            assert c.execute("SELECT current_setting('ems.routing_scope', true)").fetchone()[0] in (None, "")
            with pytest.raises(psycopg.errors.RaiseException, match="max_window must be a positive"):
                c.execute("CALL telemetry.run_routing_late_sweep_job(0, '{\"max_window\": \"0 seconds\"}'::jsonb)")
        finally:
            for row in saved:
                c.execute(
                    "UPDATE telemetry.pipeline_state SET last_received_at = %s, last_status = %s, last_started_at = %s, "
                    "last_completed_at = %s, last_inserted_rows = %s, last_error = %s WHERE pipeline_name = %s",
                    (*row[1:], row[0]),
                )


# ---------------------------------------------------------------------------
# Rollback script (executed inside the rolled-back test transaction)
# ---------------------------------------------------------------------------

ROLLBACK_SQL = (
    __import__("pathlib").Path(__file__).resolve().parents[2]
    / "postgres" / "maintenance" / "303_routing_forward_floor_late_sweep_rollback.sql"
)
# Migration 305 builds on 303: its rollback runs first, restoring the 303
# bodies the 303 rollback requires. Migration 306 (demand reconciler cadence)
# is rolled back before 305, newest first.
ROLLBACK_305_SQL = ROLLBACK_SQL.with_name("305_routing_recovery_queue_rollback.sql")
ROLLBACK_306_SQL = ROLLBACK_SQL.with_name("306_demand_reconcile_wide_cadence_rollback.sql")
# Migration 311 replaced 305's recovery body; its rollback restores that body
# first, so the 305 rollback (which refuses any other body) can run.
ROLLBACK_311_SQL = ROLLBACK_SQL.with_name("311_recovery_lookup_event_time_bound_rollback.sql")


def _script_body(path):
    text = path.read_text(encoding="utf-8")
    assert text.count("\nBEGIN;\n") == 1 and text.rstrip().endswith("COMMIT;")
    return text.split("\nBEGIN;\n", 1)[1].rsplit("COMMIT;", 1)[0]


def _rollback_body():
    return _script_body(ROLLBACK_SQL)


@pytest.fixture
def tx_pre_305(tx):
    tx.execute(_script_body(ROLLBACK_311_SQL))
    tx.execute(_script_body(ROLLBACK_306_SQL))
    tx.execute(_script_body(ROLLBACK_305_SQL))
    return tx


def test_rollback_script_restores_the_pre_303_state_and_routing_still_works(tx_pre_305):
    tx = tx_pre_305
    tx.execute(_rollback_body())
    md5 = dict(tx.execute(
        "SELECT proname, md5(replace(prosrc, E'\r', '')) FROM pg_proc "
        "WHERE oid IN ('telemetry.load_energy_measurements_incremental(interval,interval)'::regprocedure, "
        "'telemetry.load_environment_measurements_incremental(interval,interval)'::regprocedure)"
    ).fetchall())
    assert md5 == {
        "load_energy_measurements_incremental": "d271e2b8b722729b47d5991ac9504ff7",
        "load_environment_measurements_incremental": "d0708b46eb9ab81a6b2cc37ee0d85ef5",
    }
    assert _one(tx, "SELECT to_regprocedure('telemetry.run_routing_late_sweep_job(integer,jsonb)')")[0] is None
    assert _one(tx, "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name = 'run_routing_late_sweep_job'")[0] == 0
    assert _one(tx, r"SELECT count(*) FROM telemetry.pipeline_state WHERE pipeline_name LIKE '%\_late\_sweep'")[0] == 0
    assert _one(tx, "SELECT count(*) FROM timescaledb_information.jobs "
                    "WHERE proc_name IN ('run_energy_routing_job', 'run_environment_routing_job')")[0] == 2

    # Forward routing after rollback: the pre-303 body routes the late row too.
    ids = _env_fixture(tx)
    late_event, received, _ = _late_old_row(tx, ids)
    _set_ckpt(tx, "environment_measurements", received - timedelta(minutes=5))
    ckpt, status = _forward(tx, ids)
    assert (ckpt, status) == (received, "SUCCESS")
    assert _routed(tx, ids, _bucket(tx, ids, late_event)) == 1


def test_rollback_script_refuses_when_the_loaders_are_not_the_303_bodies(tx_pre_305):
    tx = tx_pre_305
    tx.execute(_rollback_body())  # first run succeeds; the loaders are now the 267 / 291 bodies
    with pytest.raises(psycopg.errors.RaiseException, match="not the migration-303 bodies"):
        tx.execute(_rollback_body())
