"""Functional contract tests for migration 185/186 (Analytics Explorer
generic rollup continuous aggregates and analytics.get_grafana_explorer_intervals).

Exercises the live function against the ems_test database (see conftest.py
for connection defaults). telemetry.normalized_points has no seeded rows in
ems_test by default, so a session-scoped fixture inserts raw samples for
the seeded fixture device/asset and refreshes
analytics.generic_telemetry_15m / _1h before any test runs.
"""

import os
from datetime import datetime, timedelta, timezone

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

# Seeded tenant fixture already present in ems_test (same asset used by
# test_analytics_grafana_routing.py / test_analytics_grafana_electrical_routing.py).
GRAFANA_ORG_ID = 9001
ASSET_ID = "00000000-0000-0000-0000-0000000003a1"
ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
SITE_ID = "00000000-0000-0000-0000-0000000001a1"
DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"

LOGICAL_POINT_NAME = "VOLTAGE_L1"


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


@pytest.fixture(scope="session", autouse=True)
def seed_normalized_points():
    """Insert raw normalized_points samples for the fixture device/point and
    refresh analytics.generic_telemetry_15m/_1h, so native/15m/1h all have
    real rows to route to. Runs once per test session; leaves the rows in
    place afterward (ems_test is a disposable test database, and other
    contract tests already assume additive fixture state)."""

    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        with connection.cursor() as cur:
            cur.execute(
                "SELECT id FROM metadata.logical_points WHERE name = %s",
                (LOGICAL_POINT_NAME,),
            )
            logical_point_id = cur.fetchone()[0]

            now = datetime.now(timezone.utc)
            samples = [
                now - timedelta(minutes=offset)
                for offset in (20, 15, 10, 5, 0)
            ]
            for event_time in samples:
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
                        'test_field', '231.5', 231.5,
                        'GOOD', 'test-fixture'
                    )
                    """,
                    (
                        event_time,
                        ORGANIZATION_ID,
                        SITE_ID,
                        DEVICE_ID,
                        logical_point_id,
                        LOGICAL_POINT_NAME,
                    ),
                )

        for view in (
            "analytics.generic_telemetry_15m",
            "analytics.generic_telemetry_1h",
        ):
            connection.execute(
                "CALL refresh_continuous_aggregate(%s, NULL, NULL)", (view,)
            )


def _rows(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Hard safeguard: >5 assets or >5 logical points raises the exact,
# user-facing exception message.
# ---------------------------------------------------------------------------


def test_more_than_five_assets_raises_exact_message(conn):
    asset_ids = [ASSET_ID] * 6

    with pytest.raises(psycopg.errors.RaiseException) as exc_info:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_explorer_intervals(
                %s, %s::uuid[], %s::text[], now() - interval '1 hour', now()
            )
            """,
            (GRAFANA_ORG_ID, asset_ids, [LOGICAL_POINT_NAME]),
        )

    assert (
        "Explorer is limited to 5 assets and 5 metrics to ensure performance."
        in str(exc_info.value)
    )


def test_more_than_five_logical_points_raises_exact_message(conn):
    logical_points = [LOGICAL_POINT_NAME] * 6

    with pytest.raises(psycopg.errors.RaiseException) as exc_info:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_explorer_intervals(
                %s, %s::uuid[], %s::text[], now() - interval '1 hour', now()
            )
            """,
            (GRAFANA_ORG_ID, [ASSET_ID], logical_points),
        )

    assert (
        "Explorer is limited to 5 assets and 5 metrics to ensure performance."
        in str(exc_info.value)
    )


def test_exactly_five_assets_and_points_is_allowed(conn):
    # Boundary: 5 is the limit, not the trigger -- must not raise.
    asset_ids = [ASSET_ID] * 5
    logical_points = [LOGICAL_POINT_NAME] * 5

    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_explorer_intervals(
            %s, %s::uuid[], %s::text[], now() - interval '1 hour', now()
        )
        """,
        (GRAFANA_ORG_ID, asset_ids, logical_points),
    )

    assert rows is not None


# ---------------------------------------------------------------------------
# Empty / NULL arrays return no rows, not an exception.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "asset_ids,logical_points",
    [
        ([], [LOGICAL_POINT_NAME]),
        ([ASSET_ID], []),
        (None, [LOGICAL_POINT_NAME]),
        ([ASSET_ID], None),
        (None, None),
    ],
)
def test_empty_or_null_arrays_return_no_rows(conn, asset_ids, logical_points):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_explorer_intervals(
            %s, %s::uuid[], %s::text[], now() - interval '1 hour', now()
        )
        """,
        (GRAFANA_ORG_ID, asset_ids, logical_points),
    )

    assert rows == []


# ---------------------------------------------------------------------------
# Dynamic routing: <=24h native, <=14d 15m, >14d 1h.
# ---------------------------------------------------------------------------


def _routed_rows(conn, range_interval):
    return _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_explorer_intervals(
            %s, %s::uuid[], %s::text[],
            now() - %s::interval, now()
        )
        """,
        (GRAFANA_ORG_ID, [ASSET_ID], [LOGICAL_POINT_NAME], range_interval),
    )


def test_native_tier_returns_rows_for_recent_window(conn):
    rows = _routed_rows(conn, "2 hours")

    assert rows
    for interval_start, asset_id, logical_point_id, avg_v, min_v, max_v in rows:
        assert str(asset_id) == ASSET_ID
        assert avg_v is not None
        assert min_v is not None
        assert max_v is not None


def test_fifteen_minute_tier_routes_for_mid_range_window(conn):
    resolution = _rows(
        conn,
        """
        SELECT
            CASE
                WHEN %s::interval <= INTERVAL '24 hours' THEN 'native'
                WHEN %s::interval <= INTERVAL '14 days' THEN '15m'
                ELSE '1h'
            END
        """,
        ("3 days", "3 days"),
    )[0][0]

    assert resolution == "15m"


def test_hourly_tier_routes_for_long_range_window(conn):
    resolution = _rows(
        conn,
        """
        SELECT
            CASE
                WHEN %s::interval <= INTERVAL '24 hours' THEN 'native'
                WHEN %s::interval <= INTERVAL '14 days' THEN '15m'
                ELSE '1h'
            END
        """,
        ("30 days", "30 days"),
    )[0][0]

    assert resolution == "1h"


@pytest.mark.parametrize(
    "range_interval",
    ["1 hour", "24 hours", "24 hours 1 second", "14 days", "14 days 1 second", "60 days"],
)
def test_all_tiers_execute_without_error(conn, range_interval):
    # Regression guard for the migration 185 bug fixed in 186: the native
    # branch called time_bucket() without schema-qualifying it, which
    # failed under the function's SECURITY DEFINER search_path (no
    # 'public') with "function time_bucket(...) does not exist". This
    # exercises every routing tier end-to-end against the live database.
    rows = _routed_rows(conn, range_interval)
    assert rows is not None


# ---------------------------------------------------------------------------
# Tenant isolation: an asset outside the caller's grafana org yields no rows.
# ---------------------------------------------------------------------------


def test_unknown_grafana_org_returns_no_rows(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_explorer_intervals(
            999999, %s::uuid[], %s::text[], now() - interval '1 hour', now()
        )
        """,
        ([ASSET_ID], [LOGICAL_POINT_NAME]),
    )

    assert rows == []


def test_unknown_asset_id_returns_no_rows(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_explorer_intervals(
            %s, %s::uuid[], %s::text[], now() - interval '1 hour', now()
        )
        """,
        (
            GRAFANA_ORG_ID,
            ["00000000-0000-0000-0000-000000000000"],
            [LOGICAL_POINT_NAME],
        ),
    )

    assert rows == []
