"""Contract tests for migration 266 (analytical backbone M2, stage 2):
activation of the four analytics.point_telemetry_1h jobs registered
unscheduled by migration 265.

Runs against the disposable ems_test database (see conftest.py), where the
migration runner has already applied 266.
"""

import os
import re
from datetime import timedelta
from pathlib import Path

import psycopg

DB_HOST = os.environ["EMS_APP_DB_HOST"]
DB_PORT = os.environ["EMS_APP_DB_PORT"]
DB_NAME = os.environ["EMS_APP_DB_NAME"]
DB_USER = os.environ["EMS_APP_DB_USER"]
DB_PASSWORD = os.environ["EMS_APP_DB_PASSWORD"]

CONNINFO = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD}"
)

MIGRATION_PATH = (
    Path(__file__).resolve().parents[2]
    / "postgres"
    / "migrations"
    / "266_point_telemetry_1h_activation.sql"
)

M2_JOBS_SQL = """
    SELECT j.job_id, j.proc_name, j.scheduled, j.schedule_interval, j.fixed_schedule,
           j.initial_start, j.max_runtime, j.max_retries, j.retry_period, j.config,
           s.next_start
    FROM timescaledb_information.jobs AS j
    JOIN timescaledb_information.job_stats AS s USING (job_id)
    WHERE (j.proc_schema = 'analytics'
           AND j.proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
       OR (j.hypertable_schema = 'analytics' AND j.hypertable_name = 'point_telemetry_1h')
    ORDER BY j.proc_name
"""


def _all(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def _m2_jobs(conn):
    return {row[1]: row for row in _all(conn, M2_JOBS_SQL)}


def _job_snapshot(conn):
    return _all(
        conn,
        """
        SELECT job_id, scheduled, schedule_interval, max_runtime, max_retries, retry_period,
               fixed_schedule, initial_start, config
        FROM timescaledb_information.jobs
        ORDER BY job_id
        """,
    )


def test_all_four_m2_jobs_are_scheduled():
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        jobs = _m2_jobs(conn)
    assert set(jobs) == {
        "policy_compression",
        "policy_retention",
        "reconcile_point_telemetry_1h",
        "run_point_telemetry_1h_job",
    }
    assert all(job[2] is True for job in jobs.values()), jobs


def test_migration_265_definitions_are_preserved():
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        jobs = _m2_jobs(conn)

    fwd = jobs["run_point_telemetry_1h_job"]
    assert fwd[3:5] == (timedelta(minutes=15), True)
    assert fwd[6:9] == (timedelta(minutes=10), 3, timedelta(minutes=5))
    assert fwd[9] == {"lookback": "2 days", "max_catchup_window": "2 days", "overlap": "2 hours"}

    rec = jobs["reconcile_point_telemetry_1h"]
    assert rec[3:5] == (timedelta(days=1), True)
    assert rec[6:9] == (timedelta(minutes=30), 3, timedelta(minutes=30))
    assert rec[9] == {"reconcile_window": "35 days", "coarse": "1 day", "n_max": 7}

    assert jobs["policy_retention"][9]["drop_after"] == "1 year"
    assert jobs["policy_compression"][9]["compress_after"] == "30 days"


def test_fixed_schedule_jobs_stay_on_their_own_grid():
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        jobs = _m2_jobs(conn)
    for name in ("run_point_telemetry_1h_job", "reconcile_point_telemetry_1h"):
        _, _, _, interval, fixed, initial_start, *_, next_start = jobs[name]
        assert fixed is True
        assert next_start is not None, name
        offset = (next_start - initial_start).total_seconds()
        assert offset % interval.total_seconds() == 0, (name, initial_start, next_start)
    # Forward on the :07 / :22 / :37 / :52 UTC grid; reconcile at 22:30 UTC.
    fwd_next = jobs["run_point_telemetry_1h_job"][-1]
    fwd_utc = fwd_next - fwd_next.utcoffset()
    assert (fwd_utc.minute % 15, fwd_utc.second) == (7, 0), fwd_next
    rec_next = jobs["reconcile_point_telemetry_1h"][-1]
    rec_utc = rec_next - rec_next.utcoffset()
    assert (rec_utc.hour, rec_utc.minute) == (22, 30)


def test_rerunning_the_migration_is_a_no_op():
    sql = MIGRATION_PATH.read_text(encoding="utf-8")
    with psycopg.connect(CONNINFO) as tx:
        before = _job_snapshot(tx)
        next_before = {k: v[-1] for k, v in _m2_jobs(tx).items()}
        tx.execute(sql)
        assert _job_snapshot(tx) == before
        assert {k: v[-1] for k, v in _m2_jobs(tx).items()} == next_before
        tx.rollback()


def test_non_m2_jobs_keep_their_scheduled_state():
    with psycopg.connect(CONNINFO, autocommit=True) as conn:
        rows = _all(
            conn,
            """
            SELECT proc_name, hypertable_name, scheduled
            FROM timescaledb_information.jobs
            WHERE proc_name IN ('run_derived_space_dew_point_1min_job', 'reconcile_derived_space_dew_point_1min',
                                'run_energy_consumption_hourly_job', 'reconcile_energy_consumption_hourly',
                                'run_demand_calculation_job')
               OR hypertable_name IN ('point_telemetry_15m', 'generic_telemetry_15m', 'generic_telemetry_1h')
            ORDER BY 1, 2
            """,
        )
    states = {(p, h): s for p, h, s in rows}
    # Migration 230 ships the dew-point tier disabled; 266 must not enable it.
    assert states[("run_derived_space_dew_point_1min_job", None)] is False
    assert states[("reconcile_derived_space_dew_point_1min", None)] is False
    assert states[("run_energy_consumption_hourly_job", None)] is True
    assert states[("reconcile_energy_consumption_hourly", None)] is True
    assert states[("run_demand_calculation_job", None)] is True
    assert all(
        s is True for (p, h), s in states.items()
        if h in ("point_telemetry_15m", "generic_telemetry_15m", "generic_telemetry_1h")
    )


def test_migration_changes_no_schema_data_or_pipeline_state():
    executable = "\n".join(
        line
        for line in MIGRATION_PATH.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("--")
    )
    forbidden = [
        r"\bALTER\s+TABLE\b",
        r"\bCREATE\s+(TABLE|INDEX|VIEW|FUNCTION|PROCEDURE|MATERIALIZED)\b(?!\s+TEMP)",
        r"(?<!ON COMMIT )\bDROP\s+",  # the temp snapshot table's ON COMMIT DROP is allowed
        r"\bINSERT\s+INTO\b",
        r"\bUPDATE\s+\w",
        r"\bDELETE\s+FROM\b",
        r"\bTRUNCATE\b",
        r"refresh_continuous_aggregate",
        r"refresh_point_telemetry_1h",
        r"backfill_point_telemetry",
        r"\badd_job\b",
        r"\bdelete_job\b",
    ]
    for pattern in forbidden:
        assert not re.search(pattern, executable, re.IGNORECASE), pattern
    # The only CREATE is the transaction-local snapshot table.
    creates = [c.upper() for c in re.findall(r"\bCREATE\s+(\w+\s+\w+)", executable, re.IGNORECASE)]
    assert creates == ["TEMP TABLE"], creates
