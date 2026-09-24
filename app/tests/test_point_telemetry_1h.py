"""Contract and functional tests for migration 265 (analytical backbone M2,
stage 1): analytics.point_telemetry_1h, its refresh / detector / forward job /
reconcile job / backfill procedure.

Runs against the disposable ems_test database (see conftest.py). Raw GOOD
samples are inserted for the seeded fixture device, materialized into
analytics.point_telemetry_15m only through the bounded M1 paths, and the 1h
tier is built only through the migration-265 routines. Tests that tamper with
1h rows do so deliberately to prove the reconcile detector and repair.
"""

import os
import re
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest
from psycopg.types.json import Jsonb

DB_HOST = os.environ["EMS_APP_DB_HOST"]
DB_PORT = os.environ["EMS_APP_DB_PORT"]
DB_NAME = os.environ["EMS_APP_DB_NAME"]
DB_USER = os.environ["EMS_APP_DB_USER"]
DB_PASSWORD = os.environ["EMS_APP_DB_PASSWORD"]

CONNINFO = (
    f"host={DB_HOST} port={DB_PORT} dbname={DB_NAME} "
    f"user={DB_USER} password={DB_PASSWORD}"
)

# Deterministic tenant identity created by conftest.seed_grafana_tenant_fixture.
ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
SITE_ID = "00000000-0000-0000-0000-0000000001a1"
DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"

# Distinct from VOLTAGE_L1 (Explorer tests) and CURRENT_L1 (M1 tests).
LOGICAL_POINT_NAME = "FREQUENCY"

TABLE = "analytics.point_telemetry_1h"
PIPELINE = "point_telemetry_1h"
FORWARD_LOCK = "analytics.run_point_telemetry_1h_job"
RECONCILE_ALL = {"reconcile_window": "35 days", "coarse": "1 day", "n_max": 100}

MIGRATION_PATH = (
    Path(__file__).resolve().parents[2]
    / "postgres"
    / "migrations"
    / "265_point_telemetry_1h.sql"
)

UTC_EPOCH = datetime(2000, 1, 1, tzinfo=timezone.utc)


def _floor(ts: datetime, step: timedelta) -> datetime:
    return UTC_EPOCH + ((ts - UTC_EPOCH) // step) * step


def _hour(ts: datetime) -> datetime:
    return _floor(ts, timedelta(hours=1))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


def _one(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()


def _all(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def _watermark(conn):
    return _one(conn, "SELECT analytics.point_telemetry_15m_watermark()")[0]


def _run_15m_forward_policy(conn):
    """Materialize the last 2 days of the 15m tier (its own bounded policy)."""
    job_id = _one(
        conn,
        """
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_15m'
          AND config ->> 'start_offset' = '2 days'
        """,
    )[0]
    conn.execute("CALL run_job(%s)", (job_id,))


def _insert_raw(conn, logical_point_id, event_time, value, quality="GOOD"):
    conn.execute(
        """
        INSERT INTO telemetry.normalized_points (
            event_time, organization_id, site_id, device_id,
            logical_point_id, device_uid, logical_point,
            raw_field_name, raw_value, numeric_value,
            quality_code, mapping_source
        ) VALUES (
            %s, %s, %s, %s, %s, 'test-device', %s,
            'test_field', %s, %s, %s, 'test-fixture-265'
        )
        ON CONFLICT DO NOTHING
        """,
        (
            event_time,
            ORGANIZATION_ID,
            SITE_ID,
            DEVICE_ID,
            logical_point_id,
            LOGICAL_POINT_NAME,
            None if value is None else str(value),
            value,
            quality,
        ),
    )


def _backfill_15m(conn, frm, to):
    conn.execute(
        "CALL analytics.backfill_point_telemetry_15m(%s, %s, interval '1 hour')",
        (frm, to),
    )


def _backfill_1h(conn, frm, to, slice_="1 hour"):
    conn.execute(
        "CALL analytics.backfill_point_telemetry_1h(%s, %s, %s::interval)",
        (frm, to, slice_),
    )


def _row(conn, fx, bucket):
    return _one(
        conn,
        f"""
        SELECT sum_value, sample_count, min_value, max_value, source_bucket_count, calculated_at
        FROM {TABLE}
        WHERE device_id = %s AND logical_point_id = %s AND bucket_start = %s
        """,
        (DEVICE_ID, fx["lp"], bucket),
    )


def _checkpoint(conn):
    return _one(
        conn,
        "SELECT last_received_at, last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s",
        (PIPELINE,),
    )


def _set_checkpoint(conn, ts):
    conn.execute(
        "UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s",
        (ts, PIPELINE),
    )


def _run_forward(conn, config=None):
    conn.execute(
        "CALL analytics.run_point_telemetry_1h_job(0, %s)",
        (Jsonb(config or {}),),
    )


def _run_reconcile(conn, config=None):
    conn.execute(
        "CALL analytics.reconcile_point_telemetry_1h(0, %s)",
        (Jsonb(config if config is not None else RECONCILE_ALL),),
    )
    return _one(
        conn,
        """
        SELECT outcome, window_start, window_end, coarse_examined, coarse_mismatch,
               rows_repaired, error_count, first_error_message
        FROM analytics.pipeline_reconciliation_log
        WHERE tier = %s
        ORDER BY ran_at DESC
        LIMIT 1
        """,
        (PIPELINE,),
    )


def _settle(conn):
    """Anchor the checkpoint at the last closed 15m hour and reconcile the
    35-day window until HEALTHY (repairs any hour built by no test yet)."""
    _set_checkpoint(conn, _hour(_watermark(conn)))
    for _ in range(3):
        if _run_reconcile(conn)[0] == "HEALTHY":
            return
    raise AssertionError("point_telemetry_1h did not reconcile to HEALTHY")


@pytest.fixture(scope="module")
def fx(seed_grafana_tenant_fixture):
    """Raw GOOD/non-GOOD samples ~5 days back (hour H0, next hour, and one hour
    on the previous UTC day D1), materialized into 15m; 15m watermark moved to
    ~now by the 15m tier's own bounded forward policy."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        lp = _one(c, "SELECT id FROM metadata.logical_points WHERE name = %s", (LOGICAL_POINT_NAME,))[0]

        h0 = _hour(datetime.now(timezone.utc) - timedelta(days=5))
        d1 = h0 - timedelta(days=1)

        for frm, to in ((h0, h0 + timedelta(hours=2)), (d1, d1 + timedelta(hours=1))):
            c.execute(
                """
                DELETE FROM telemetry.normalized_points
                WHERE device_id = %s AND logical_point_id = %s
                  AND event_time >= %s AND event_time < %s
                """,
                (DEVICE_ID, lp, frm, to),
            )

        samples = [
            (h0, Decimal("1"), "GOOD"),                                          # q0
            (h0 + timedelta(minutes=5), Decimal("2"), "GOOD"),                   # q0
            (h0 + timedelta(minutes=15), Decimal("3"), "GOOD"),                  # q1
            (h0 + timedelta(minutes=50), Decimal("10"), "GOOD"),                 # q3
            (h0 + timedelta(minutes=59, seconds=59), Decimal("20"), "GOOD"),     # q3, last instant of H0
            (h0 + timedelta(minutes=20), None, "MISSING"),                       # excluded
            (h0 + timedelta(minutes=21), None, "INVALID_NUMERIC"),               # excluded
            (h0 + timedelta(hours=1), Decimal("7"), "GOOD"),                     # first instant of H0+1h
            (d1 + timedelta(minutes=10), Decimal("100"), "GOOD"),                # D1
        ]
        for event_time, value, quality in samples:
            _insert_raw(c, lp, event_time, value, quality)

        # The 15m watermark is the end of the newest materialized bucket that
        # holds data, so give the forward policy a recent complete bucket to
        # move it to ~now.
        recent = _floor(datetime.now(timezone.utc) - timedelta(hours=1), timedelta(minutes=15))
        _insert_raw(c, lp, recent + timedelta(minutes=1), Decimal("9"))

        _backfill_15m(c, h0, h0 + timedelta(hours=2))
        _backfill_15m(c, d1, d1 + timedelta(hours=1))
        _run_15m_forward_policy(c)
        assert _watermark(c) >= recent + timedelta(minutes=15)

    return {"lp": lp, "h0": h0, "h1": h0 + timedelta(hours=1), "d1": d1}


@pytest.fixture(scope="module", autouse=True)
def quiesce_m2_jobs():
    """Migration 266 activates the forward and reconcile jobs. These tests set
    checkpoints and tamper with 1h rows, so pause both jobs for the duration
    of the module (waiting out any in-flight run) and restore their exact
    scheduled state and next_start afterwards."""
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        jobs = _all(
            c,
            """
            SELECT j.job_id, j.scheduled, s.next_start
            FROM timescaledb_information.jobs AS j
            JOIN timescaledb_information.job_stats AS s USING (job_id)
            WHERE j.proc_schema = 'analytics'
              AND j.proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h')
            """,
        )
        for job_id, _, _ in jobs:
            c.execute("SELECT alter_job(%s, scheduled => false)", (job_id,))
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and _one(
            c,
            "SELECT count(*) FROM timescaledb_information.job_stats WHERE job_id = ANY(%s) AND job_status = 'Running'",
            ([j[0] for j in jobs],),
        )[0]:
            time.sleep(1)
    yield
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        for job_id, scheduled, next_start in jobs:
            if scheduled:
                c.execute(
                    "SELECT alter_job(%s, scheduled => true, next_start => %s)",
                    (job_id, next_start),
                )


EXPECTED_H0 = (Decimal("36"), 5, Decimal("1"), Decimal("20"), 3)
EXPECTED_H1 = (Decimal("7"), 1, Decimal("7"), Decimal("7"), 1)
EXPECTED_D1 = (Decimal("100"), 1, Decimal("100"), Decimal("100"), 1)


# ---------------------------------------------------------------------------
# Structure / identity
# ---------------------------------------------------------------------------


def test_columns_and_types(conn):
    columns = _all(
        conn,
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'point_telemetry_1h'
        ORDER BY ordinal_position
        """,
    )
    assert columns == [
        ("bucket_start", "timestamp with time zone", "NO"),
        ("organization_id", "uuid", "NO"),
        ("site_id", "uuid", "NO"),
        ("device_id", "uuid", "NO"),
        ("logical_point_id", "uuid", "NO"),
        ("sum_value", "numeric", "NO"),
        ("sample_count", "bigint", "NO"),
        ("min_value", "numeric", "NO"),
        ("max_value", "numeric", "NO"),
        ("source_bucket_count", "smallint", "NO"),
        ("calculated_at", "timestamp with time zone", "NO"),
    ]


@pytest.mark.parametrize(
    "column", ["bucket_start", "organization_id", "site_id", "device_id", "logical_point_id"]
)
def test_null_identity_is_rejected(column):
    values = {
        "bucket_start": "TIMESTAMPTZ '2026-01-01 00:00:00+00'",
        "organization_id": "gen_random_uuid()",
        "site_id": "gen_random_uuid()",
        "device_id": "gen_random_uuid()",
        "logical_point_id": "gen_random_uuid()",
    }
    values[column] = "NULL"
    with psycopg.connect(CONNINFO) as tx:
        with pytest.raises(psycopg.errors.NotNullViolation):
            tx.execute(
                f"""
                INSERT INTO {TABLE} (bucket_start, organization_id, site_id, device_id,
                    logical_point_id, sum_value, sample_count, min_value, max_value, source_bucket_count)
                VALUES ({values['bucket_start']}, {values['organization_id']}, {values['site_id']},
                    {values['device_id']}, {values['logical_point_id']}, 1, 1, 1, 1, 1)
                """
            )
        tx.rollback()


def test_unique_index_is_plain_and_covers_full_identity(conn):
    row = _one(
        conn,
        """
        SELECT i.indisunique, i.indnullsnotdistinct,
               array_agg(a.attname ORDER BY k.ord)
        FROM pg_index AS i
        JOIN pg_class AS c ON c.oid = i.indexrelid
        CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
        JOIN pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
        WHERE c.relname = 'ux_point_telemetry_1h_identity'
        GROUP BY 1, 2
        """,
    )
    assert row == (
        True,
        False,
        ["device_id", "logical_point_id", "bucket_start", "organization_id", "site_id"],
    )


def test_duplicate_identity_is_rejected():
    with psycopg.connect(CONNINFO) as tx:
        ident = (str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4()))
        insert = f"""
            INSERT INTO {TABLE} (bucket_start, organization_id, site_id, device_id,
                logical_point_id, sum_value, sample_count, min_value, max_value, source_bucket_count)
            VALUES (TIMESTAMPTZ '2026-01-01 00:00:00+00', %s, %s, %s, %s, 1, 1, 1, 1, 1)
        """
        tx.execute(insert, ident)
        with pytest.raises(psycopg.errors.UniqueViolation):
            tx.execute(insert, ident)
        tx.rollback()


@pytest.mark.parametrize(
    "bucket_start, source_bucket_count, min_value, max_value",
    [
        ("2026-01-01 00:30:00+00", 1, 1, 1),   # off the UTC hour grid
        ("2026-01-01 00:00:00+00", 0, 1, 1),   # no contributing bucket
        ("2026-01-01 00:00:00+00", 5, 1, 1),   # more than four 15m buckets
        ("2026-01-01 00:00:00+00", 1, 2, 1),   # min > max
    ],
)
def test_check_constraints(bucket_start, source_bucket_count, min_value, max_value):
    with psycopg.connect(CONNINFO) as tx:
        with pytest.raises(psycopg.errors.CheckViolation):
            tx.execute(
                f"""
                INSERT INTO {TABLE} (bucket_start, organization_id, site_id, device_id,
                    logical_point_id, sum_value, sample_count, min_value, max_value, source_bucket_count)
                VALUES (%s, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                    gen_random_uuid(), 1, 1, %s, %s, %s)
                """,
                (bucket_start, min_value, max_value, source_bucket_count),
            )
        tx.rollback()


def test_hypertable_chunking_and_compression_settings(conn):
    assert _one(
        conn,
        """
        SELECT time_interval FROM timescaledb_information.dimensions
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
        """,
    ) == (timedelta(days=7),)
    settings = _all(
        conn,
        """
        SELECT attname, segmentby_column_index, orderby_column_index, orderby_asc
        FROM timescaledb_information.compression_settings
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_1h'
        ORDER BY segmentby_column_index NULLS LAST, orderby_column_index
        """,
    )
    assert settings == [
        ("device_id", 1, None, None),
        ("logical_point_id", 2, None, None),
        ("bucket_start", None, 1, False),
        ("organization_id", None, 2, True),
        ("site_id", None, 3, True),
    ]


def test_every_job_and_policy_is_registered_with_the_265_definition(conn):
    """Migration 265 registered these four jobs unscheduled; whether they are
    scheduled is owned by migration 266 and asserted in
    test_point_telemetry_1h_activation.py."""
    rows = _all(
        conn,
        """
        SELECT j.proc_name, j.scheduled, j.schedule_interval, j.config,
               b.check_schema || '.' || b.check_name
        FROM timescaledb_information.jobs AS j
        JOIN _timescaledb_config.bgw_job AS b ON b.id = j.job_id
        WHERE (j.proc_schema = 'analytics'
               AND j.proc_name IN ('run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h'))
           OR (j.hypertable_schema = 'analytics' AND j.hypertable_name = 'point_telemetry_1h')
        ORDER BY j.proc_name
        """,
    )
    by_name = {r[0]: r for r in rows}
    assert set(by_name) == {
        "policy_compression",
        "policy_retention",
        "reconcile_point_telemetry_1h",
        "run_point_telemetry_1h_job",
    }
    assert by_name["policy_retention"][3]["drop_after"] == "1 year"
    assert by_name["policy_compression"][3]["compress_after"] == "30 days"
    assert by_name["run_point_telemetry_1h_job"][2:] == (
        timedelta(minutes=15),
        {"lookback": "2 days", "max_catchup_window": "2 days", "overlap": "2 hours"},
        "config.assert_analytical_lookback_job_config",
    )
    assert by_name["reconcile_point_telemetry_1h"][2:] == (
        timedelta(days=1),
        {"reconcile_window": "35 days", "coarse": "1 day", "n_max": 7},
        "config.assert_reconciliation_job_config",
    )


def test_reconciliation_log_tier_check_is_widened_additively():
    tiers = [
        "energy_consumption_1min", "energy_consumption_5min", "energy_consumption_15min",
        "energy_consumption_hourly", "energy_consumption_daily", "demand_intervals",
        "environment_daily", "derived_space_dew_point_1min", "point_telemetry_1h",
    ]
    with psycopg.connect(CONNINFO) as tx:
        for tier in tiers:
            tx.execute(
                "INSERT INTO analytics.pipeline_reconciliation_log (tier, outcome) VALUES (%s, 'HEALTHY')",
                (tier,),
            )
        with pytest.raises(psycopg.errors.CheckViolation):
            tx.execute(
                "INSERT INTO analytics.pipeline_reconciliation_log (tier, outcome) VALUES ('not_a_tier', 'HEALTHY')"
            )
        tx.rollback()


def test_grants(conn):
    routines = [
        "analytics.point_telemetry_15m_watermark()",
        "analytics.refresh_point_telemetry_1h(timestamptz, timestamptz)",
        "analytics.detect_point_telemetry_1h_deficits(timestamptz, timestamptz, interval, integer)",
        "analytics.run_point_telemetry_1h_job(integer, jsonb)",
        "analytics.reconcile_point_telemetry_1h(integer, jsonb)",
        "analytics.backfill_point_telemetry_1h(timestamptz, timestamptz, interval)",
    ]
    assert _one(
        conn,
        """
        SELECT has_table_privilege('ems_app', %(t)s, 'SELECT'),
               has_table_privilege('ems_readonly', %(t)s, 'SELECT'),
               has_table_privilege('grafana_reader', %(t)s, 'SELECT'),
               has_table_privilege('ems_app', %(t)s, 'INSERT'),
               has_table_privilege('ems_readonly', %(t)s, 'UPDATE')
        """,
        {"t": TABLE},
    ) == (True, True, False, False, False)
    for routine in routines:
        assert _one(
            conn,
            """
            SELECT has_function_privilege('ems_admin', %(r)s, 'EXECUTE'),
                   has_function_privilege('ems_app', %(r)s, 'EXECUTE'),
                   has_function_privilege('ems_readonly', %(r)s, 'EXECUTE'),
                   has_function_privilege('grafana_reader', %(r)s, 'EXECUTE')
            """,
            {"r": routine},
        ) == (True, False, False, False), routine


def test_no_routine_removes_rows_or_refreshes_a_cagg(conn):
    offenders = _all(
        conn,
        """
        SELECT p.proname
        FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'analytics'
          AND p.proname IN ('refresh_point_telemetry_1h', 'detect_point_telemetry_1h_deficits',
                            'run_point_telemetry_1h_job', 'reconcile_point_telemetry_1h',
                            'backfill_point_telemetry_1h', 'point_telemetry_15m_watermark')
          AND (p.prosrc ~* '\\mdelete\\s+from\\M' OR p.prosrc ~* '\\mtruncate\\M'
               OR p.prosrc ~* 'refresh_continuous_aggregate')
        """,
    )
    assert offenders == []


def test_migration_file_never_refreshes_a_continuous_aggregate():
    """The 1h tier is a job-built table: migration 265 must never call
    refresh_continuous_aggregate (bounded or not) on the 15m tier."""
    executable = "\n".join(
        line
        for line in MIGRATION_PATH.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("--")
    )
    invocation = re.compile(
        r"\b(CALL|SELECT|PERFORM)\s+(public\.)?refresh_continuous_aggregate\s*\(", re.IGNORECASE
    )
    assert not invocation.search(executable)


def test_existing_m1_explorer_and_energy_objects_are_untouched(conn):
    m1 = _all(
        conn,
        """
        SELECT proc_name, scheduled FROM timescaledb_information.jobs
        WHERE hypertable_schema = 'analytics' AND hypertable_name = 'point_telemetry_15m'
        ORDER BY proc_name, config ->> 'start_offset'
        """,
    )
    assert m1 == [
        ("policy_refresh_continuous_aggregate", True),
        ("policy_refresh_continuous_aggregate", True),
        ("policy_retention", True),
    ]
    assert _all(
        conn,
        """
        SELECT hypertable_name, config ->> 'start_offset' FROM timescaledb_information.jobs
        WHERE hypertable_schema = 'analytics'
          AND hypertable_name IN ('generic_telemetry_15m', 'generic_telemetry_1h')
          AND proc_name = 'policy_refresh_continuous_aggregate'
        ORDER BY 2
        """,
    ) == [("generic_telemetry_15m", "2 days"), ("generic_telemetry_1h", "7 days")]
    explorer = _one(
        conn,
        "SELECT prosrc FROM pg_proc WHERE oid = 'analytics.get_grafana_explorer_intervals'::regproc",
    )[0]
    assert "generic_telemetry_1h" in explorer and "point_telemetry_1h" not in explorer
    assert _one(
        conn,
        """
        SELECT count(*) FROM timescaledb_information.jobs
        WHERE proc_name IN ('run_energy_consumption_hourly_job', 'reconcile_energy_consumption_hourly')
          AND scheduled
        """,
    ) == (2,)


def test_pipeline_state_row_exists(conn):
    assert _one(
        conn,
        "SELECT count(*) FROM telemetry.pipeline_state WHERE pipeline_name = %s",
        (PIPELINE,),
    ) == (1,)


# ---------------------------------------------------------------------------
# Refresh / backfill guards
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "frm, to",
    [
        ("NULL", "date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '1 day'"),
        ("date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '2 days'", "NULL"),
        # unaligned
        ("date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '2 days' + interval '15 minutes'",
         "date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '1 day'"),
        # > 7 days
        ("date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '9 days'",
         "date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '1 day'"),
        # beyond the closed-15m watermark
        ("date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') - interval '1 hour'",
         "date_bin('1 hour', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00') + interval '1 hour'"),
    ],
)
def test_refresh_guards(conn, fx, frm, to):
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        conn.execute(f"SELECT analytics.refresh_point_telemetry_1h({frm}, {to})")


def test_backfill_guards(conn, fx):
    now_hour = _hour(datetime.now(timezone.utc))
    oldest = _one(
        conn,
        """
        SELECT min(ch.range_start)
        FROM timescaledb_information.continuous_aggregates AS ca
        JOIN timescaledb_information.chunks AS ch
          ON ch.hypertable_schema = ca.materialization_hypertable_schema
         AND ch.hypertable_name = ca.materialization_hypertable_name
        WHERE ca.view_name = 'point_telemetry_15m'
        """,
    )[0]
    cases = [
        ("NULL", "%s", (now_hour - timedelta(days=1),), "required"),
        ("%s", "%s", (fx["h0"] + timedelta(minutes=30), fx["h1"]), "UTC hour grid"),
        ("%s", "%s", (now_hour - timedelta(hours=2), now_hour + timedelta(hours=2)), "closed hour"),
        ("%s", "%s", (_hour(oldest) - timedelta(hours=1), _hour(oldest) + timedelta(hours=1)), "oldest retained"),
    ]
    for frm, to, params, message in cases:
        with pytest.raises(psycopg.errors.InvalidParameterValue, match=message):
            conn.execute(f"CALL analytics.backfill_point_telemetry_1h({frm}, {to})", params)
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="p_slice"):
        conn.execute(
            "CALL analytics.backfill_point_telemetry_1h(%s, %s, interval '30 minutes')",
            (fx["h0"], fx["h1"]),
        )


def test_backfill_cannot_run_inside_a_transaction_block(fx):
    with psycopg.connect(CONNINFO) as tx:
        with pytest.raises(psycopg.errors.InvalidTransactionTermination):
            tx.execute(
                "CALL analytics.backfill_point_telemetry_1h(%s, %s)",
                (fx["h0"], fx["h1"]),
            )


# ---------------------------------------------------------------------------
# Composition
# ---------------------------------------------------------------------------


def test_backfill_composes_exact_values_and_boundaries(conn, fx):
    _backfill_1h(conn, fx["d1"], fx["h0"] + timedelta(hours=2))
    assert _row(conn, fx, fx["h0"])[:5] == EXPECTED_H0
    assert _row(conn, fx, fx["h1"])[:5] == EXPECTED_H1
    assert _row(conn, fx, fx["d1"])[:5] == EXPECTED_D1
    # UTC hour grid: HH:00 UTC is HH:30 in Asia/Kolkata (ADR-019 D3).
    assert _one(
        conn,
        "SELECT extract(minute FROM %s::timestamptz AT TIME ZONE 'Asia/Kolkata')::int",
        (fx["h0"],),
    ) == (30,)


def test_every_1h_row_equals_its_15m_constituents(conn, fx):
    frm, to = fx["d1"], fx["h0"] + timedelta(hours=2)
    _backfill_1h(conn, frm, to, "1 day")
    diffs = _one(
        conn,
        f"""
        WITH src AS (
            SELECT date_bin('1 hour', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS b,
                   organization_id, site_id, device_id, logical_point_id,
                   sum(sum_value) s, sum(sample_count) n, min(min_value) mn, max(max_value) mx, count(*) c
            FROM analytics.point_telemetry_15m
            WHERE bucket_start >= %(f)s AND bucket_start < %(t)s
            GROUP BY 1, 2, 3, 4, 5
        ),
        dst AS (
            SELECT bucket_start AS b, organization_id, site_id, device_id, logical_point_id,
                   sum_value s, sample_count n, min_value mn, max_value mx, source_bucket_count c
            FROM {TABLE}
            WHERE bucket_start >= %(f)s AND bucket_start < %(t)s
        )
        SELECT count(*) FILTER (WHERE src.b IS NULL OR dst.b IS NULL
                                   OR (src.s, src.n, src.mn, src.mx, src.c)
                                      IS DISTINCT FROM (dst.s, dst.n, dst.mn, dst.mx, dst.c)),
               count(*)
        FROM src FULL JOIN dst USING (b, organization_id, site_id, device_id, logical_point_id)
        """,
        {"f": frm, "t": to},
    )
    assert diffs[0] == 0 and diffs[1] >= 3


def test_refresh_is_value_aware_and_idempotent(conn, fx):
    _backfill_1h(conn, fx["h0"], fx["h0"] + timedelta(hours=2))
    before = _row(conn, fx, fx["h0"])
    changed = _one(
        conn,
        "SELECT analytics.refresh_point_telemetry_1h(%s, %s)",
        (fx["h0"], fx["h0"] + timedelta(hours=2)),
    )[0]
    assert changed == 0
    assert _row(conn, fx, fx["h0"]) == before  # calculated_at untouched too


# ---------------------------------------------------------------------------
# Forward job
# ---------------------------------------------------------------------------


def test_forward_first_run_uses_lookback_and_writes_only_closed_hours(conn, fx):
    lp = fx["lp"]
    now_hour = _hour(datetime.now(timezone.utc))
    _insert_raw(conn, lp, now_hour + timedelta(seconds=1), Decimal("5"))  # in-progress hour
    _run_15m_forward_policy(conn)

    _set_checkpoint(conn, None)
    _run_forward(conn, {"lookback": "2 days", "max_catchup_window": "2 days", "overlap": "2 hours"})

    closed = _hour(_watermark(conn))
    ckpt, status = _checkpoint(conn)
    assert status == "SUCCESS"
    assert ckpt == min(_hour(datetime.now(timezone.utc)), closed)
    assert _one(
        conn,
        f"SELECT count(*) FROM {TABLE} WHERE bucket_start >= %s",
        (min(now_hour, closed),),
    ) == (0,)


def test_forward_overlap_absorbs_a_late_sample(conn, fx):
    lp = fx["lp"]
    late_hour = _hour(datetime.now(timezone.utc)) - timedelta(hours=3)
    # Clear this test's own samples so reruns within the same hour stay exact.
    conn.execute(
        """
        DELETE FROM telemetry.normalized_points
        WHERE device_id = %s AND logical_point_id = %s
          AND event_time >= %s AND event_time < %s
        """,
        (DEVICE_ID, lp, late_hour, late_hour + timedelta(hours=1)),
    )
    _insert_raw(conn, lp, late_hour + timedelta(minutes=1), Decimal("40"))
    _run_15m_forward_policy(conn)
    _set_checkpoint(conn, late_hour - timedelta(hours=1))
    _run_forward(conn)
    first = _row(conn, fx, late_hour)
    assert first is not None

    _insert_raw(conn, lp, late_hour + timedelta(minutes=31), Decimal("60"))  # arrives late
    _run_15m_forward_policy(conn)
    # Checkpoint one hour past late_hour: the 2h overlap re-derives late_hour,
    # and the fixture's recent sample guarantees the closed-15m watermark is
    # beyond late_hour + 1h at any minute of the hour (late_hour + 2h would
    # need the current hour's first 15m bucket closed, i.e. minute >= ~16).
    _set_checkpoint(conn, late_hour + timedelta(hours=1))
    _run_forward(conn)
    second = _row(conn, fx, late_hour)
    assert second[1] == first[1] + 1
    assert second[0] == first[0] + Decimal("60")
    assert second[4] == first[4] + 1  # one more contributing 15m bucket


def test_forward_rerun_does_not_rewrite_unchanged_rows(conn, fx):
    late_hour = _hour(datetime.now(timezone.utc)) - timedelta(hours=3)
    _set_checkpoint(conn, late_hour + timedelta(hours=1))
    _run_forward(conn)
    before = _row(conn, fx, late_hour)
    _set_checkpoint(conn, late_hour + timedelta(hours=1))
    _run_forward(conn)
    assert _row(conn, fx, late_hour) == before


def test_forward_skipped_locked_keeps_checkpoint(conn, fx):
    anchor = _hour(_watermark(conn)) - timedelta(hours=1)
    _set_checkpoint(conn, anchor)
    with psycopg.connect(CONNINFO, autocommit=True) as holder:
        holder.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", (FORWARD_LOCK,))
        try:
            _run_forward(conn)
        finally:
            holder.execute("SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (FORWARD_LOCK,))
    assert _checkpoint(conn) == (anchor, "SKIPPED_LOCKED")


def test_forward_rejects_bad_config_without_moving_checkpoint(conn, fx):
    anchor = _hour(_watermark(conn)) - timedelta(hours=1)
    _set_checkpoint(conn, anchor)
    with pytest.raises(psycopg.errors.RaiseException):
        _run_forward(conn, {"overlap": "-1 hour"})
    assert _checkpoint(conn)[0] == anchor


FAIL_SEQ = "public.zz_265_forward_fail_seq"
FAIL_FN = "public.zz_265_forward_fail_after_two_rows"
FAIL_TRIGGER = "zz_265_forward_fail_after_two_rows"


def _arm_mid_refresh_failure(conn):
    """Test-only injection: the third row the refresh inserts into the 1h table
    raises, so the INSERT fails partway through. The sequence is not
    transactional, so it proves rows were being written before the failure."""
    conn.execute(f"DROP SEQUENCE IF EXISTS {FAIL_SEQ}")
    conn.execute(f"CREATE SEQUENCE {FAIL_SEQ}")
    conn.execute(
        f"""
        CREATE OR REPLACE FUNCTION {FAIL_FN}() RETURNS trigger LANGUAGE plpgsql AS $f$
        BEGIN
            IF nextval('{FAIL_SEQ}') >= 3 THEN
                RAISE EXCEPTION 'injected mid-refresh failure (test 265)';
            END IF;
            RETURN NEW;
        END
        $f$
        """
    )
    conn.execute(
        f"""
        CREATE TRIGGER {FAIL_TRIGGER} BEFORE INSERT ON {TABLE}
        FOR EACH ROW EXECUTE FUNCTION {FAIL_FN}()
        """
    )


def _disarm_mid_refresh_failure(conn):
    conn.execute(f"DROP TRIGGER IF EXISTS {FAIL_TRIGGER} ON {TABLE}")
    conn.execute(f"DROP FUNCTION IF EXISTS {FAIL_FN}()")
    conn.execute(f"DROP SEQUENCE IF EXISTS {FAIL_SEQ}")


def _rows_in(conn, frm, to):
    return _one(
        conn,
        f"SELECT count(*) FROM {TABLE} WHERE bucket_start >= %s AND bucket_start < %s",
        (frm, to),
    )[0]


def _state(conn):
    return _one(
        conn,
        """
        SELECT last_received_at, last_status, last_inserted_rows, last_completed_at, last_error
        FROM telemetry.pipeline_state WHERE pipeline_name = %s
        """,
        (PIPELINE,),
    )


def test_forward_failure_mid_refresh_rolls_back_is_recorded_and_retries(conn, fx):
    lp = fx["lp"]
    _run_15m_forward_policy(conn)
    closed = _hour(_watermark(conn))
    start = closed - timedelta(hours=3)          # checkpoint X
    window_from = start - timedelta(hours=2)     # X - overlap

    # Four new hours of data inside the forward window [X - 2h, closed).
    for h in range(4):
        _insert_raw(conn, lp, window_from + timedelta(hours=h, minutes=7), Decimal(200 + h))
    _run_15m_forward_policy(conn)
    closed = _hour(_watermark(conn))

    # Treat the window as not yet built, and fix a known prior state.
    conn.execute(f"DELETE FROM {TABLE} WHERE bucket_start >= %s", (window_from,))
    conn.execute(
        """
        UPDATE telemetry.pipeline_state
        SET last_received_at = %s, last_status = 'SUCCESS', last_error = NULL
        WHERE pipeline_name = %s
        """,
        (start, PIPELINE),
    )
    before = _state(conn)

    fwd_job = _one(
        conn,
        """
        SELECT job_id FROM timescaledb_information.jobs
        WHERE proc_schema = 'analytics' AND proc_name = 'run_point_telemetry_1h_job'
        """,
    )[0]

    _arm_mid_refresh_failure(conn)
    try:
        # (A) Direct call: the failure surfaces to the caller, and the whole
        # run -- partial 1h rows, RUNNING/FAILED status writes, checkpoint --
        # rolls back atomically. Nothing is recorded as complete.
        with pytest.raises(psycopg.errors.RaiseException, match="injected mid-refresh failure"):
            _run_forward(conn)
        assert _one(conn, f"SELECT last_value FROM {FAIL_SEQ}")[0] >= 3  # failed partway
        assert _state(conn) == before
        assert _rows_in(conn, window_from, closed + timedelta(hours=1)) == 0

        # (B) The registered job run by the TimescaleDB scheduler: the failure
        # is recorded in job_stats / job_errors; pipeline_state and the table
        # are still untouched.
        conn.execute(f"ALTER SEQUENCE {FAIL_SEQ} RESTART")
        failures_before = _one(
            conn, "SELECT total_failures FROM timescaledb_information.job_stats WHERE job_id = %s", (fwd_job,)
        )[0]
        conn.execute("SELECT alter_job(%s, scheduled => true, next_start => now())", (fwd_job,))
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                failures = _one(
                    conn,
                    "SELECT total_failures FROM timescaledb_information.job_stats WHERE job_id = %s",
                    (fwd_job,),
                )[0]
                if failures > failures_before:
                    break
                time.sleep(1)
            else:
                pytest.fail("scheduler did not record the forward-job failure within 120 s")
        finally:
            conn.execute("SELECT alter_job(%s, scheduled => false)", (fwd_job,))

        assert _one(
            conn, "SELECT last_run_status FROM timescaledb_information.job_stats WHERE job_id = %s", (fwd_job,)
        ) == ("Failed",)
        assert "injected mid-refresh failure" in _one(
            conn,
            """
            SELECT err_message FROM timescaledb_information.job_errors
            WHERE job_id = %s ORDER BY finish_time DESC LIMIT 1
            """,
            (fwd_job,),
        )[0]
        assert _state(conn) == before
        assert _rows_in(conn, window_from, closed + timedelta(hours=1)) == 0
    finally:
        _disarm_mid_refresh_failure(conn)

    # Back to the module's quiesced (paused) state; quiesce_m2_jobs restores
    # the job's real scheduled state when the module finishes.
    assert _one(
        conn, "SELECT scheduled FROM timescaledb_information.jobs WHERE job_id = %s", (fwd_job,)
    ) == (False,)

    # A subsequent successful run retries the same window from the unchanged
    # checkpoint and completes it exactly.
    _run_forward(conn)
    ckpt, status, rows, _, error = _state(conn)
    assert status == "SUCCESS" and error is None and rows >= 4
    assert ckpt > start and ckpt == _hour(ckpt)
    for h in range(4):
        hour = window_from + timedelta(hours=h)
        assert _row(conn, fx, hour) is not None, hour  # every retried hour is now built
    # ... and built exactly: every 1h row in the retried window equals its 15m parts.
    mismatches = _one(
        conn,
        f"""
        WITH src AS (
            SELECT date_bin('1 hour', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS b,
                   organization_id, site_id, device_id, logical_point_id,
                   sum(sum_value) s, sum(sample_count) n, min(min_value) mn, max(max_value) mx, count(*) c
            FROM analytics.point_telemetry_15m
            WHERE bucket_start >= %(f)s AND bucket_start < %(t)s
            GROUP BY 1, 2, 3, 4, 5
        ),
        dst AS (
            SELECT bucket_start AS b, organization_id, site_id, device_id, logical_point_id,
                   sum_value s, sample_count n, min_value mn, max_value mx, source_bucket_count c
            FROM {TABLE}
            WHERE bucket_start >= %(f)s AND bucket_start < %(t)s
        )
        SELECT count(*) FROM src FULL JOIN dst USING (b, organization_id, site_id, device_id, logical_point_id)
        WHERE src.b IS NULL OR dst.b IS NULL
           OR (src.s, src.n, src.mn, src.mx, src.c) IS DISTINCT FROM (dst.s, dst.n, dst.mn, dst.mx, dst.c)
        """,
        {"f": window_from, "t": ckpt},
    )[0]
    assert mismatches == 0


# ---------------------------------------------------------------------------
# Reconcile
# ---------------------------------------------------------------------------


def test_reconcile_healthy_window_and_never_writes_pipeline_state(conn, fx):
    _settle(conn)
    state_before = _one(conn, "SELECT * FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))
    log = _run_reconcile(conn)
    state_after = _one(conn, "SELECT * FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))
    assert log[0] == "HEALTHY"
    cp = state_before[1]
    assert log[1] == cp - timedelta(days=35) and log[2] == cp
    assert state_after == state_before


TAMPERS = {
    "group_count": "DELETE FROM analytics.point_telemetry_1h WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
    "sample_count": "UPDATE analytics.point_telemetry_1h SET sample_count = sample_count + 1 WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
    "sum_value": "UPDATE analytics.point_telemetry_1h SET sum_value = sum_value + 1 WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
    "min_value": "UPDATE analytics.point_telemetry_1h SET min_value = -1000000000000 WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
    "max_value": "UPDATE analytics.point_telemetry_1h SET max_value = 1000000000000 WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
    "source_bucket_count": "UPDATE analytics.point_telemetry_1h SET source_bucket_count = 4 WHERE device_id = %(d)s AND logical_point_id = %(p)s AND bucket_start = %(b)s",
}


@pytest.mark.parametrize("dimension", list(TAMPERS))
def test_reconcile_detects_and_repairs_each_compared_dimension(conn, fx, dimension):
    _settle(conn)
    day = _floor(fx["h0"], timedelta(days=1))
    conn.execute(TAMPERS[dimension], {"d": DEVICE_ID, "p": fx["lp"], "b": fx["h0"]})

    flagged = _all(
        conn,
        "SELECT coarse_bucket_start FROM analytics.detect_point_telemetry_1h_deficits(%s, %s, interval '1 day', 10)",
        (day, day + timedelta(days=1)),
    )
    assert flagged == [(day,)], dimension

    log = _run_reconcile(conn)
    assert log[0] == "REPAIRED" and log[4] == 1 and log[5] >= 1, (dimension, log)
    assert _row(conn, fx, fx["h0"])[:5] == EXPECTED_H0
    assert _run_reconcile(conn)[0] == "HEALTHY"


def test_reconcile_repairs_late_15m_data(conn, fx):
    _settle(conn)
    _insert_raw(conn, fx["lp"], fx["d1"] + timedelta(minutes=40), Decimal("50"))
    _backfill_15m(conn, fx["d1"], fx["d1"] + timedelta(hours=1))  # 15m picks it up

    log = _run_reconcile(conn)
    assert log[0] == "REPAIRED"
    sum_value, sample_count, mn, mx, buckets, _ = _row(conn, fx, fx["d1"])
    assert (sum_value, sample_count, mn, mx, buckets) == (Decimal("150"), 2, Decimal("50"), Decimal("100"), 2)
    assert _run_reconcile(conn)[0] == "HEALTHY"


def test_reconcile_partial_when_mismatches_exceed_n_max(conn, fx):
    _settle(conn)
    for bucket in (fx["h0"], fx["d1"]):  # two different UTC days
        conn.execute(TAMPERS["sum_value"], {"d": DEVICE_ID, "p": fx["lp"], "b": bucket})
    log = _run_reconcile(conn, {"reconcile_window": "35 days", "coarse": "1 day", "n_max": 1})
    assert log[0] == "PARTIAL" and log[4] == 1
    _settle(conn)
    assert _row(conn, fx, fx["h0"])[:5] == EXPECTED_H0


def test_reconcile_reports_an_orphan_row_and_never_removes_it(conn, fx):
    _settle(conn)
    orphan_device = str(uuid.uuid4())
    conn.execute(
        f"""
        INSERT INTO {TABLE} (bucket_start, organization_id, site_id, device_id,
            logical_point_id, sum_value, sample_count, min_value, max_value, source_bucket_count)
        VALUES (%s, %s, %s, %s, %s, 1, 1, 1, 1, 1)
        """,
        (fx["h0"], ORGANIZATION_ID, SITE_ID, orphan_device, fx["lp"]),
    )
    try:
        log = _run_reconcile(conn)
        assert log[0] == "FAILED" and log[6] >= 1
        assert "unrepairable" in log[7]
        assert _one(
            conn, f"SELECT count(*) FROM {TABLE} WHERE device_id = %s", (orphan_device,)
        ) == (1,)
    finally:
        conn.execute(f"DELETE FROM {TABLE} WHERE device_id = %s", (orphan_device,))
    assert _run_reconcile(conn)[0] == "HEALTHY"


def test_reconcile_skipped_locked_and_no_checkpoint(conn, fx):
    _settle(conn)
    with psycopg.connect(CONNINFO, autocommit=True) as holder:
        holder.execute("SELECT pg_advisory_lock(hashtextextended(%s, 0))", (FORWARD_LOCK,))
        try:
            assert _run_reconcile(conn)[0] == "SKIPPED_LOCKED"
        finally:
            holder.execute("SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (FORWARD_LOCK,))

    cp = _checkpoint(conn)[0]
    _set_checkpoint(conn, None)
    try:
        assert _run_reconcile(conn)[0] == "NO_CHECKPOINT"
    finally:
        _set_checkpoint(conn, cp)


def test_reconcile_window_cannot_exceed_35_days(conn, fx):
    with pytest.raises(psycopg.errors.RaiseException, match="35 days"):
        conn.execute(
            "CALL analytics.reconcile_point_telemetry_1h(0, %s)",
            (Jsonb({"reconcile_window": "36 days", "coarse": "1 day", "n_max": 7}),),
        )
