"""Contract and functional tests for migration 267: the routing loaders'
window-end lookup is max(platform_received_at) bounded to recent event_time
(so it never decompresses historical normalized_points chunks), with the
original global max() kept only as the NULL fallback.

Runs against the disposable ems_test database (see conftest.py). Every
functional test runs inside one transaction that is rolled back, so fixtures,
chunk compression and pipeline_state changes never persist. Fixture rows use
random device/point ids (as the migration-207 contract does): they resolve to
no device, so they drive the window-end computation without producing
routing candidates.
"""

import os
import re
import time
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

BOUNDED_SQL = (
    "SELECT max(platform_received_at) FROM telemetry.normalized_points "
    "WHERE platform_received_at IS NOT NULL AND event_time >= now() - INTERVAL '1 day'"
)
GLOBAL_SQL = (
    "SELECT max(platform_received_at) FROM telemetry.normalized_points "
    "WHERE platform_received_at IS NOT NULL"
)
LOADERS = {
    "energy_measurements": "telemetry.load_energy_measurements_incremental",
    "environment_measurements": "telemetry.load_environment_measurements_incremental",
}
PIPELINE_JOBS = ("run_normalization_job", "run_energy_routing_job", "run_environment_routing_job")
DECOMPRESSION_NODES = ("ColumnarScan", "DecompressChunk")


@pytest.fixture(scope="module", autouse=True)
def quiesce_pipeline_jobs():
    """Pause normalization and both routing jobs for this module (these tests
    set checkpoints and window data) and restore their scheduled state."""
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


def _insert_np(conn, event_time, platform_received_at):
    conn.execute(
        """
        INSERT INTO telemetry.normalized_points
            (event_time, organization_id, device_id, logical_point_id,
             device_uid, logical_point, quality_code, platform_received_at)
        VALUES (%s, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                'TEST:267:WINDOW:NOMATCH', 'TEST_267_WINDOW_END', 'GOOD', %s)
        """,
        (event_time, platform_received_at),
    )


def _set_checkpoint(conn, pipeline, ts):
    conn.execute(
        "UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s",
        (ts, pipeline),
    )


def _run(conn, pipeline):
    if pipeline == "environment_measurements":
        conn.execute("DROP TABLE IF EXISTS tmp_environment_candidates")
    conn.execute(f"CALL {LOADERS[pipeline]}(INTERVAL '5 minutes', NULL)")
    return _one(
        conn,
        "SELECT last_received_at, last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s",
        (pipeline,),
    )


def _plan(conn, sql):
    return "\n".join(r[0] for r in conn.execute(f"EXPLAIN {sql}").fetchall())


# ---------------------------------------------------------------------------
# Deployed definition
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("proc", LOADERS.values())
def test_loader_uses_bounded_lookup_with_global_fallback_only(proc):
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        src = _one(conn, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (f"{proc}(interval,interval)",))[0]
    src = src.replace("\r", "")
    bounded = re.findall(
        r"SELECT max\(platform_received_at\) INTO v_window_end\s+FROM telemetry\.normalized_points\s+"
        r"WHERE platform_received_at IS NOT NULL\s+AND event_time >= now\(\) - INTERVAL '1 day';",
        src,
    )
    fallback = re.findall(
        r"IF v_window_end IS NULL THEN\s+SELECT max\(platform_received_at\) INTO v_window_end\s+"
        r"FROM telemetry\.normalized_points\s+WHERE platform_received_at IS NOT NULL;\s+END IF;",
        src,
    )
    assert len(bounded) == 1, proc
    assert len(fallback) == 1, proc
    assert src.count("max(platform_received_at) INTO v_window_end") == 2, proc
    # The fallback is only reached when the bounded lookup found nothing.
    assert src.index(bounded[0]) < src.index(fallback[0])
    # Not the normalization checkpoint.
    assert "pipeline_name='normalized_points'" not in src.replace(" ", "")


def test_routing_bound_is_within_the_normalized_points_compression_boundary():
    """The 1-day event_time bound must stay <= compress_after, read from the
    canonical TimescaleDB policy, so every compressed chunk is excluded."""
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        compress_after = _one(
            conn,
            """
            SELECT (config ->> 'compress_after')::interval
            FROM timescaledb_information.jobs
            WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'
              AND proc_name = 'policy_compression'
            """,
        )[0]
        bounds = set()
        for proc in LOADERS.values():
            src = _one(conn, "SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (f"{proc}(interval,interval)",))[0]
            found = re.findall(r"event_time >= now\(\) - INTERVAL '(\d+) (day|days|hour|hours)'", src)
            assert len(found) == 1, proc
            n, unit = found[0]
            bounds.add(timedelta(days=int(n)) if unit.startswith("day") else timedelta(hours=int(n)))
    assert len(bounds) == 1, "both loaders must use the same bound"
    (bound,) = bounds
    assert compress_after is not None
    assert bound <= compress_after, (bound, compress_after)


# ---------------------------------------------------------------------------
# Query plan: no decompression of historical compressed chunks
# ---------------------------------------------------------------------------


def test_bounded_lookup_never_scans_compressed_history(tx):
    now = _now(tx)
    # A historical chunk, compressed for this test only (rolled back).
    _insert_np(tx, now - timedelta(days=40), now - timedelta(days=40))
    tx.execute(
        """
        SELECT compress_chunk(c, if_not_compressed => true)
        FROM show_chunks('telemetry.normalized_points', older_than => now() - INTERVAL '30 days') AS c
        """
    )
    compressed = _one(
        tx,
        """
        SELECT count(*) FROM timescaledb_information.chunks
        WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points' AND is_compressed
        """,
    )[0]
    assert compressed >= 1

    # Control: the old global lookup does decompress compressed chunks.
    global_plan = _plan(tx, GLOBAL_SQL)
    assert any(node in global_plan for node in DECOMPRESSION_NODES), global_plan

    # The bounded lookup (custom plan) touches no compressed chunk.
    bounded_plan = _plan(tx, BOUNDED_SQL)
    assert not any(node in bounded_plan for node in DECOMPRESSION_NODES), bounded_plan

    # Same for a cached generic plan, as PL/pgSQL may use.
    tx.execute("SET LOCAL plan_cache_mode = force_generic_plan")
    tx.execute(f"PREPARE bounded_window_end AS {BOUNDED_SQL}")
    generic_plan = "\n".join(r[0] for r in tx.execute("EXPLAIN EXECUTE bounded_window_end").fetchall())
    tx.execute("DEALLOCATE bounded_window_end")
    assert not any(node in generic_plan for node in DECOMPRESSION_NODES), generic_plan


# ---------------------------------------------------------------------------
# Window-end semantics
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("pipeline", LOADERS)
def test_normal_ingestion_parity_with_the_global_max(tx, pipeline):
    now = _now(tx)
    base = now + timedelta(days=50)  # deterministically the newest receipt
    _insert_np(tx, now - timedelta(hours=1), base)

    assert _one(tx, BOUNDED_SQL)[0] == _one(tx, GLOBAL_SQL)[0] == base

    _set_checkpoint(tx, pipeline, base - timedelta(minutes=10))
    ckpt, status = _run(tx, pipeline)
    assert (ckpt, status) == (base, "SUCCESS")


@pytest.mark.parametrize("pipeline", LOADERS)
def test_window_end_ignores_a_normalization_checkpoint_that_runs_ahead(tx, pipeline):
    """Normalization's checkpoint can run ahead of normalized rows (deferred
    bucket finalization). Routing must follow the normalized rows, so a row
    normalized later is still inside the next window."""
    now = _now(tx)
    base = now + timedelta(days=50)
    _insert_np(tx, now - timedelta(hours=1), base)
    _set_checkpoint(tx, "normalized_points", base + timedelta(minutes=10))  # ahead
    _set_checkpoint(tx, pipeline, base - timedelta(minutes=5))

    ckpt, _ = _run(tx, pipeline)
    assert ckpt == base  # not the normalization checkpoint

    # The deferred sample is normalized later with an earlier receipt time
    # than the normalization checkpoint.
    deferred = base + timedelta(minutes=2)
    _insert_np(tx, now - timedelta(minutes=30), deferred)
    # A checkpoint-driven window would have started at (base + 10m) - 1m and
    # skipped it:
    assert deferred <= (base + timedelta(minutes=10)) - timedelta(minutes=1)

    ckpt2, status2 = _run(tx, pipeline)
    assert status2 == "SUCCESS"
    # Selected by the next window (previous checkpoint - 1m overlap, new end].
    assert base - timedelta(minutes=1) < deferred <= ckpt2
    assert ckpt2 == deferred


@pytest.mark.parametrize("pipeline", LOADERS)
def test_old_event_time_with_fresh_receipt_never_pushes_the_window_forward(tx, pipeline):
    now = _now(tx)
    base = now + timedelta(days=50)
    _insert_np(tx, now - timedelta(hours=1), base)                        # recent event
    fresh_old = base + timedelta(minutes=5)
    _insert_np(tx, now - timedelta(days=10), fresh_old)                   # old event, fresher receipt

    assert _one(tx, GLOBAL_SQL)[0] == fresh_old
    assert _one(tx, BOUNDED_SQL)[0] == base                              # conservative: lower

    _set_checkpoint(tx, pipeline, base - timedelta(minutes=5))
    ckpt, _ = _run(tx, pipeline)
    assert ckpt == base
    assert fresh_old > ckpt                                               # still pending, not skipped

    newer = base + timedelta(minutes=10)
    _insert_np(tx, now - timedelta(minutes=20), newer)
    ckpt2, _ = _run(tx, pipeline)
    assert ckpt2 == newer
    assert ckpt - timedelta(minutes=1) < fresh_old <= ckpt2               # selected by this window


@pytest.mark.parametrize("pipeline", LOADERS)
def test_null_bounded_result_falls_back_to_the_global_max(tx, pipeline):
    now = _now(tx)
    tx.execute("DELETE FROM telemetry.normalized_points WHERE event_time >= now() - INTERVAL '1 day'")
    base = now + timedelta(days=50)
    _insert_np(tx, now - timedelta(days=5), base)                         # only old-event data

    assert _one(tx, BOUNDED_SQL)[0] is None
    assert _one(tx, GLOBAL_SQL)[0] == base

    _set_checkpoint(tx, pipeline, base - timedelta(minutes=5))
    ckpt, status = _run(tx, pipeline)
    assert (ckpt, status) == (base, "SUCCESS")                            # routing stays live


@pytest.mark.parametrize("pipeline", LOADERS)
def test_no_source_data_behaviour_is_unchanged(tx, pipeline):
    tx.execute("DELETE FROM telemetry.normalized_points WHERE platform_received_at IS NOT NULL")
    before = _one(tx, "SELECT last_received_at FROM telemetry.pipeline_state WHERE pipeline_name = %s", (pipeline,))[0]
    ckpt, status = _run(tx, pipeline)
    assert status == "NO_SOURCE_DATA"
    assert ckpt == before
