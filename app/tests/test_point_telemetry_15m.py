"""Contract and functional tests for migration 264 (analytical backbone M1):
analytics.point_telemetry_15m and analytics.backfill_point_telemetry_15m.

Runs against the disposable ems_test database (see conftest.py). Structural
tests read the TimescaleDB catalog; functional tests insert GOOD / non-GOOD
normalized_points samples for the seeded fixture device and materialize them
only through the sanctioned bounded paths (the backfill procedure and the
late-data refresh policy job) -- never an unbounded refresh.
"""

import os
from datetime import datetime, timedelta, timezone
from decimal import Decimal
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

# Deterministic tenant identity created by conftest.seed_grafana_tenant_fixture.
ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
SITE_ID = "00000000-0000-0000-0000-0000000001a1"
DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"

# Distinct from the VOLTAGE_L1 samples the Explorer tests insert.
LOGICAL_POINT_NAME = "CURRENT_L1"

CAGG = "analytics.point_telemetry_15m"
BACKFILL = "analytics.backfill_point_telemetry_15m"

MIGRATION_PATH = (
    Path(__file__).resolve().parents[2]
    / "postgres"
    / "migrations"
    / "264_point_telemetry_15m.sql"
)


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


def _mat_hypertable_id(conn):
    return _one(
        conn,
        """
        SELECT mat_hypertable_id
        FROM _timescaledb_catalog.continuous_agg
        WHERE user_view_schema = 'analytics'
          AND user_view_name = 'point_telemetry_15m'
        """,
    )[0]


def _utc_bucket(ts: datetime) -> datetime:
    epoch = datetime(2000, 1, 1, tzinfo=timezone.utc)
    step = timedelta(minutes=15)
    return epoch + ((ts - epoch) // step) * step


# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------


def test_is_a_materialized_only_uncompressed_continuous_aggregate(conn):
    row = _one(
        conn,
        """
        SELECT materialized_only, compression_enabled
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'analytics' AND view_name = 'point_telemetry_15m'
        """,
    )
    assert row == (True, False)


def test_bucket_is_fixed_width_utc_15_minutes(conn):
    row = _one(
        conn,
        """
        SELECT bf.bucket_width::interval, bf.bucket_timezone, bf.bucket_fixed_width,
               bf.bucket_origin, bf.bucket_offset
        FROM _timescaledb_catalog.continuous_aggs_bucket_function AS bf
        WHERE bf.mat_hypertable_id = %s
        """,
        (_mat_hypertable_id(conn),),
    )
    assert row == (timedelta(minutes=15), None, True, None, None)


def test_columns_are_sum_count_min_max_without_avg_or_asset(conn):
    columns = _all(
        conn,
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'analytics' AND table_name = 'point_telemetry_15m'
        ORDER BY ordinal_position
        """,
    )
    assert columns == [
        ("bucket_start", "timestamp with time zone"),
        ("organization_id", "uuid"),
        ("site_id", "uuid"),
        ("device_id", "uuid"),
        ("logical_point_id", "uuid"),
        ("sum_value", "numeric"),
        ("sample_count", "bigint"),
        ("min_value", "numeric"),
        ("max_value", "numeric"),
    ]


def test_normalized_points_has_no_asset_id_column(conn):
    row = _one(
        conn,
        """
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = 'telemetry'
          AND table_name = 'normalized_points'
          AND column_name = 'asset_id'
        """,
    )
    assert row == (0,)


def test_exactly_two_disjoint_bounded_refresh_policies(conn):
    policies = _all(
        conn,
        """
        SELECT config ->> 'start_offset', config ->> 'end_offset', schedule_interval
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND (config ->> 'mat_hypertable_id')::int = %s
        ORDER BY schedule_interval
        """,
        (_mat_hypertable_id(conn),),
    )
    assert policies == [
        ("2 days", "00:01:00", timedelta(minutes=5)),
        ("35 days", "2 days", timedelta(days=1)),
    ]


def test_every_refresh_window_is_well_inside_raw_retention(conn):
    """Refreshing over dropped raw data deletes aggregate rows, so no policy
    window may reach the 90-day normalized_points retention boundary."""
    offsets = _all(
        conn,
        """
        SELECT (config ->> 'start_offset')::interval
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND (config ->> 'mat_hypertable_id')::int = %s
        """,
        (_mat_hypertable_id(conn),),
    )
    raw_retention = _one(
        conn,
        """
        SELECT (config ->> 'drop_after')::interval
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
          AND hypertable_schema = 'telemetry'
          AND hypertable_name = 'normalized_points'
        """,
    )[0]
    assert raw_retention == timedelta(days=90)
    assert offsets and all(start < raw_retention for (start,) in offsets)


def test_120_day_retention_and_no_compression_policy(conn):
    mat_id = _mat_hypertable_id(conn)
    retention = _all(
        conn,
        """
        SELECT config ->> 'drop_after'
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
          AND (config ->> 'hypertable_id')::int = %s
        """,
        (mat_id,),
    )
    compression = _one(
        conn,
        """
        SELECT count(*)
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_compression'
          AND (config ->> 'hypertable_id')::int = %s
        """,
        (mat_id,),
    )
    assert retention == [("120 days",)]
    assert compression == (0,)


def test_grants(conn):
    row = _one(
        conn,
        """
        SELECT
            has_table_privilege('ems_app', %(v)s, 'SELECT'),
            has_table_privilege('ems_readonly', %(v)s, 'SELECT'),
            has_table_privilege('grafana_reader', %(v)s, 'SELECT'),
            has_table_privilege('ems_app', %(v)s, 'INSERT'),
            has_function_privilege('ems_admin', %(p)s, 'EXECUTE'),
            has_function_privilege('ems_app', %(p)s, 'EXECUTE'),
            has_function_privilege('ems_readonly', %(p)s, 'EXECUTE')
        """,
        {
            "v": CAGG,
            "p": f"{BACKFILL}(timestamptz, timestamptz, interval)",
        },
    )
    assert row == (True, True, False, False, True, False, False)


def test_legacy_generic_aggregates_and_explorer_are_untouched(conn):
    policies = _all(
        conn,
        """
        SELECT j.hypertable_name, j.config ->> 'start_offset'
        FROM timescaledb_information.jobs AS j
        WHERE j.hypertable_schema = 'analytics'
          AND j.hypertable_name IN ('generic_telemetry_15m', 'generic_telemetry_1h')
          AND j.proc_name = 'policy_refresh_continuous_aggregate'
        ORDER BY 2
        """,
    )
    assert [start for _, start in policies] == ["2 days", "7 days"]

    body = _one(
        conn,
        "SELECT prosrc FROM pg_proc WHERE oid = 'analytics.get_grafana_explorer_intervals'::regproc",
    )[0]
    assert "generic_telemetry_15m" in body
    assert "point_telemetry_15m" not in body


def test_migration_file_never_issues_an_unbounded_refresh():
    sql = MIGRATION_PATH.read_text(encoding="utf-8")
    executable = "\n".join(
        line for line in sql.splitlines() if not line.lstrip().startswith("--")
    )
    assert "NULL, NULL)" not in executable.replace("NULL,NULL)", "NULL, NULL)")


# ---------------------------------------------------------------------------
# Backfill procedure guards
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "p_from, p_to, p_slice",
    [
        ("NULL", "now()", "interval '1 day'"),
        ("now() - interval '1 day'", "NULL", "interval '1 day'"),
        ("now() - interval '1 day'", "now()", "NULL"),
    ],
)
def test_backfill_rejects_unbounded_arguments(conn, p_from, p_to, p_slice):
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        conn.execute(f"CALL {BACKFILL}({p_from}, {p_to}, {p_slice})")


def test_backfill_rejects_unaligned_window(conn):
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="15-minute grid"):
        conn.execute(
            f"""
            CALL {BACKFILL}(
                date_bin('15 minutes', now() - interval '3 days', TIMESTAMPTZ '2000-01-01 00:00:00+00') + interval '1 minute',
                date_bin('15 minutes', now() - interval '2 days', TIMESTAMPTZ '2000-01-01 00:00:00+00')
            )
            """
        )


def test_backfill_rejects_future_end(conn):
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="future"):
        conn.execute(
            f"""
            CALL {BACKFILL}(
                date_bin('15 minutes', now(), TIMESTAMPTZ '2000-01-01 00:00:00+00'),
                date_bin('15 minutes', now() + interval '1 day', TIMESTAMPTZ '2000-01-01 00:00:00+00')
            )
            """
        )


def test_backfill_rejects_bad_slice(conn):
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="p_slice"):
        conn.execute(
            f"""
            CALL {BACKFILL}(
                date_bin('15 minutes', now() - interval '3 days', TIMESTAMPTZ '2000-01-01 00:00:00+00'),
                date_bin('15 minutes', now() - interval '2 days', TIMESTAMPTZ '2000-01-01 00:00:00+00'),
                interval '10 minutes'
            )
            """
        )


def test_backfill_refuses_window_older_than_retained_raw_chunks(conn, point_fixture):
    oldest_chunk = _one(
        conn,
        """
        SELECT min(range_start)
        FROM timescaledb_information.chunks
        WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'
        """,
    )[0]
    assert oldest_chunk is not None
    start = _utc_bucket(oldest_chunk) - timedelta(minutes=15)
    with pytest.raises(psycopg.errors.InvalidParameterValue, match="oldest retained"):
        conn.execute(
            f"CALL {BACKFILL}(%s, %s, interval '15 minutes')",
            (start, start + timedelta(minutes=30)),
        )


def test_backfill_cannot_run_inside_a_transaction_block(point_fixture):
    with psycopg.connect(CONNINFO) as tx_conn:
        with pytest.raises(psycopg.errors.InvalidTransactionTermination):
            tx_conn.execute(
                f"""
                CALL {BACKFILL}(
                    date_bin('15 minutes', now() - interval '3 days', TIMESTAMPTZ '2000-01-01 00:00:00+00'),
                    date_bin('15 minutes', now() - interval '3 days', TIMESTAMPTZ '2000-01-01 00:00:00+00') + interval '15 minutes'
                )
                """
            )


# ---------------------------------------------------------------------------
# Functional behaviour
# ---------------------------------------------------------------------------


@pytest.fixture
def point_fixture(conn, seed_grafana_tenant_fixture):
    """Two adjacent UTC 15-minute buckets ~3 days back (inside the late-data
    policy window [now-35d, now-2d)), with GOOD samples, one non-GOOD sample
    and one NULL-valued sample. Existing fixture rows in the window are
    removed first so reruns stay deterministic."""
    logical_point_id = _one(
        conn,
        "SELECT id FROM metadata.logical_points WHERE name = %s",
        (LOGICAL_POINT_NAME,),
    )[0]

    bucket_a = _utc_bucket(datetime.now(timezone.utc) - timedelta(days=3))
    bucket_b = bucket_a + timedelta(minutes=15)
    window_end = bucket_b + timedelta(minutes=15)

    conn.execute(
        """
        DELETE FROM telemetry.normalized_points
        WHERE device_id = %s AND logical_point_id = %s
          AND event_time >= %s AND event_time < %s
        """,
        (DEVICE_ID, logical_point_id, bucket_a, window_end),
    )

    samples = [
        # (event_time, numeric_value, quality_code)
        (bucket_a, Decimal("1"), "GOOD"),
        (bucket_a + timedelta(minutes=4), Decimal("2"), "GOOD"),
        (bucket_a + timedelta(minutes=9), Decimal("3"), "GOOD"),
        (bucket_a + timedelta(minutes=14, seconds=59), Decimal("10"), "GOOD"),
        (bucket_a + timedelta(minutes=7), Decimal("1000"), "GAP"),
        (bucket_a + timedelta(minutes=8), None, "INVALID_NUMERIC"),
        # Exactly on the next bucket's start: belongs to bucket B, not A.
        (bucket_b, Decimal("5"), "GOOD"),
    ]
    with conn.cursor() as cur:
        for event_time, value, quality in samples:
            cur.execute(
                """
                INSERT INTO telemetry.normalized_points (
                    event_time, organization_id, site_id, device_id,
                    logical_point_id, device_uid, logical_point,
                    raw_field_name, raw_value, numeric_value,
                    quality_code, mapping_source
                ) VALUES (
                    %s, %s, %s, %s,
                    %s, 'test-device', %s,
                    'test_field', %s, %s,
                    %s, 'test-fixture-264'
                )
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

    return {
        "logical_point_id": logical_point_id,
        "bucket_a": bucket_a,
        "bucket_b": bucket_b,
        "window_end": window_end,
    }


def _fixture_rows(conn, fx):
    return _all(
        conn,
        f"""
        SELECT bucket_start, organization_id::text, site_id::text,
               sum_value, sample_count, min_value, max_value
        FROM {CAGG}
        WHERE device_id = %s AND logical_point_id = %s
          AND bucket_start >= %s AND bucket_start < %s
        ORDER BY bucket_start
        """,
        (DEVICE_ID, fx["logical_point_id"], fx["bucket_a"], fx["window_end"]),
    )


def test_backfill_materializes_exact_sum_count_min_max(conn, point_fixture):
    fx = point_fixture
    conn.execute(
        f"CALL {BACKFILL}(%s, %s, interval '15 minutes')",
        (fx["bucket_a"], fx["window_end"]),
    )

    rows = _fixture_rows(conn, fx)
    assert rows == [
        (fx["bucket_a"], ORGANIZATION_ID, SITE_ID, Decimal("16"), 4, Decimal("1"), Decimal("10")),
        (fx["bucket_b"], ORGANIZATION_ID, SITE_ID, Decimal("5"), 1, Decimal("5"), Decimal("5")),
    ]
    # Average is derived at read time, never stored.
    assert rows[0][3] / rows[0][4] == Decimal("4")


def test_backfill_is_idempotent(conn, point_fixture):
    fx = point_fixture
    for _ in range(2):
        conn.execute(
            f"CALL {BACKFILL}(%s, %s)",
            (fx["bucket_a"], fx["window_end"]),
        )
    assert [(r[0], r[3], r[4]) for r in _fixture_rows(conn, fx)] == [
        (fx["bucket_a"], Decimal("16"), 4),
        (fx["bucket_b"], Decimal("5"), 1),
    ]


def test_buckets_are_on_the_utc_grid_regardless_of_session_timezone(conn, point_fixture):
    fx = point_fixture
    conn.execute(
        f"CALL {BACKFILL}(%s, %s, interval '15 minutes')",
        (fx["bucket_a"], fx["window_end"]),
    )
    # +05:45 has no whole-hour alignment; the stored instants must still be
    # exact multiples of 15 minutes from the UTC origin.
    conn.execute("SET TIME ZONE 'Asia/Kathmandu'")
    misaligned = _one(
        conn,
        f"""
        SELECT count(*)
        FROM {CAGG}
        WHERE device_id = %s AND logical_point_id = %s
          AND bucket_start <> date_bin('15 minutes', bucket_start, TIMESTAMPTZ '2000-01-01 00:00:00+00')
        """,
        (DEVICE_ID, fx["logical_point_id"]),
    )
    assert misaligned == (0,)


def test_late_data_policy_picks_up_a_late_sample(conn, point_fixture):
    fx = point_fixture
    conn.execute(
        f"CALL {BACKFILL}(%s, %s, interval '15 minutes')",
        (fx["bucket_a"], fx["window_end"]),
    )

    # A recovered sample arrives for an already-materialized bucket 3 days back.
    conn.execute(
        """
        INSERT INTO telemetry.normalized_points (
            event_time, organization_id, site_id, device_id,
            logical_point_id, device_uid, logical_point,
            raw_field_name, raw_value, numeric_value,
            quality_code, mapping_source
        ) VALUES (
            %s, %s, %s, %s, %s, 'test-device', %s,
            'test_field', '20', 20, 'GOOD', 'test-fixture-264'
        )
        """,
        (
            fx["bucket_a"] + timedelta(minutes=11),
            ORGANIZATION_ID,
            SITE_ID,
            DEVICE_ID,
            fx["logical_point_id"],
            LOGICAL_POINT_NAME,
        ),
    )

    late_policy_job = _one(
        conn,
        """
        SELECT job_id
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_refresh_continuous_aggregate'
          AND (config ->> 'mat_hypertable_id')::int = %s
          AND config ->> 'start_offset' = '35 days'
        """,
        (_mat_hypertable_id(conn),),
    )[0]
    conn.execute("CALL run_job(%s)", (late_policy_job,))

    bucket_a_row = _fixture_rows(conn, fx)[0]
    assert (bucket_a_row[3], bucket_a_row[4], bucket_a_row[6]) == (Decimal("36"), 5, Decimal("20"))
