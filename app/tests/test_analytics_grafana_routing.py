"""Functional contract tests for migration 044 (dynamic Grafana resolution routing).

Exercises the live analytics functions against the ems_test database
(see conftest.py for connection defaults) rather than only asserting on
migration SQL text, since routing/exception behavior needs a real
Postgres engine to validate.
"""

import os
import uuid

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

# Seeded tenant fixture already present in ems_test: an active
# grafana_organization_map row with an asset that has a PRIMARY_METER
# device.
GRAFANA_ORG_ID = 9001
ASSET_ID = "00000000-0000-0000-0000-0000000003a1"
OTHER_ASSET_ID = "00000000-0000-0000-0000-0000000003c1"


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


def _scalar(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]


def _rows(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Routing threshold tests: analytics.resolve_grafana_energy_routing_resolution
# is the single source of truth for the 24h / 14d tier boundaries used by
# both public functions.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "range_interval,expected_resolution",
    [
        ("1 hour", "native"),
        ("24 hours", "native"),  # inclusive boundary
        ("24 hours 1 second", "15m"),  # just over 24h
        ("13 days", "15m"),
        ("14 days", "15m"),  # inclusive boundary
        ("14 days 1 second", "1h"),  # just over 14d
        ("30 days", "1h"),
        ("400 days", "1h"),
    ],
)
def test_routing_thresholds(conn, range_interval, expected_resolution):
    resolution = _scalar(
        conn,
        """
        SELECT analytics.resolve_grafana_energy_routing_resolution(
            now(),
            now() + %s::interval
        )
        """,
        (range_interval,),
    )
    assert resolution == expected_resolution


def test_24_hour_routing_is_finer_than_14_day_routing(conn):
    at_24h = _scalar(
        conn,
        "SELECT analytics.resolve_grafana_energy_routing_resolution(now(), now() + interval '24 hours')",
        (),
    )
    at_14d = _scalar(
        conn,
        "SELECT analytics.resolve_grafana_energy_routing_resolution(now(), now() + interval '14 days')",
        (),
    )
    at_over_14d = _scalar(
        conn,
        "SELECT analytics.resolve_grafana_energy_routing_resolution(now(), now() + interval '15 days')",
        (),
    )
    assert (at_24h, at_14d, at_over_14d) == ("native", "15m", "1h")


# ---------------------------------------------------------------------------
# Single-asset function: proves get_grafana_asset_energy_intervals actually
# threads the routed resolution through to get_canonical_energy_read, by
# comparing its output row-for-row against a direct canonical-reader call
# made with the independently-expected resolution for the same range.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "range_interval,expected_resolution",
    [
        ("24 hours", "native"),
        ("14 days", "15m"),
        ("30 days", "1h"),
    ],
)
def test_single_asset_routing_matches_canonical_reader(
    conn, range_interval, expected_resolution
):
    routed_rows = _rows(
        conn,
        """
        SELECT interval_start, import_consumption_kwh, export_consumption_kwh
        FROM analytics.get_grafana_asset_energy_intervals(
            %s, %s, now() - %s::interval, now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID, range_interval),
    )

    direct_rows = _rows(
        conn,
        """
        SELECT interval_start, import_consumption_kwh, export_consumption_kwh
        FROM analytics.get_canonical_energy_read(
            %s, %s, now() - %s::interval, now(), %s, 'native'
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID, range_interval, expected_resolution),
    )

    assert routed_rows == direct_rows


def test_single_asset_invalid_range_returns_no_rows_without_raising(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_asset_energy_intervals(
            %s, %s, now(), now() - interval '1 hour'
        )
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )
    assert rows == []


def test_single_asset_unknown_tenant_returns_no_rows(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_asset_energy_intervals(
            999999, %s, now() - interval '1 day', now()
        )
        """,
        (ASSET_ID,),
    )
    assert rows == []


# ---------------------------------------------------------------------------
# Multi-asset function: 10-asset exception safeguard.
# ---------------------------------------------------------------------------


def test_ten_assets_is_accepted(conn):
    asset_ids = [ASSET_ID, OTHER_ASSET_ID] + [
        str(uuid.uuid4()) for _ in range(8)
    ]
    assert len(asset_ids) == 10

    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_assets_energy_intervals(
            %s, %s::uuid[], now() - interval '1 day', now()
        )
        """,
        (GRAFANA_ORG_ID, asset_ids),
    )
    # No exception: unknown padding UUIDs simply contribute no rows.
    assert isinstance(rows, list)


def test_eleven_assets_raises_exception(conn):
    asset_ids = [str(uuid.uuid4()) for _ in range(11)]

    with pytest.raises(psycopg.errors.RaiseException) as excinfo:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_assets_energy_intervals(
                %s, %s::uuid[], now() - interval '1 day', now()
            )
            """,
            (GRAFANA_ORG_ID, asset_ids),
        )

    assert "too many assets requested (11)" in str(excinfo.value)
    assert "maximum of 10 assets" in str(excinfo.value)


def test_null_asset_ids_raises_exception(conn):
    with pytest.raises(psycopg.errors.RaiseException) as excinfo:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_assets_energy_intervals(
                %s, NULL::uuid[], now() - interval '1 day', now()
            )
            """,
            (GRAFANA_ORG_ID,),
        )
    assert "must contain at least one asset" in str(excinfo.value)


def test_empty_asset_ids_raises_exception(conn):
    with pytest.raises(psycopg.errors.RaiseException) as excinfo:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_assets_energy_intervals(
                %s, ARRAY[]::uuid[], now() - interval '1 day', now()
            )
            """,
            (GRAFANA_ORG_ID,),
        )
    assert "must contain at least one asset" in str(excinfo.value)


def test_multi_asset_fanout_matches_single_asset_calls(conn):
    asset_ids = [ASSET_ID, OTHER_ASSET_ID]

    multi_rows = _rows(
        conn,
        """
        SELECT asset_id, interval_start, import_consumption_kwh
        FROM analytics.get_grafana_assets_energy_intervals(
            %s, %s::uuid[], now() - interval '14 days', now()
        )
        ORDER BY asset_id, interval_start
        """,
        (GRAFANA_ORG_ID, asset_ids),
    )

    expected_rows = []
    for asset_id in asset_ids:
        rows = _rows(
            conn,
            """
            SELECT %s::uuid, interval_start, import_consumption_kwh
            FROM analytics.get_grafana_asset_energy_intervals(
                %s, %s, now() - interval '14 days', now()
            )
            """,
            (asset_id, GRAFANA_ORG_ID, asset_id),
        )
        expected_rows.extend(rows)
    expected_rows.sort(key=lambda row: (str(row[0]), row[1] or ""))

    assert multi_rows == expected_rows
