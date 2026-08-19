"""Functional contract tests for migration 046 (electrical trend dynamic
resolution routing).

Exercises the live analytics functions against the ems_test database (see
conftest.py for connection defaults). telemetry.energy_measurements has no
seeded rows in ems_test by default, so a session-scoped fixture inserts a
handful of raw electrical samples for the seeded fixture device and
refreshes the relevant continuous aggregates before any test runs -- this
keeps the suite self-contained and reproducible rather than depending on
ems's live telemetry.
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
# test_analytics_grafana_routing.py).
GRAFANA_ORG_ID = 9001
ASSET_ID = "00000000-0000-0000-0000-0000000003a1"
ORGANIZATION_ID = "00000000-0000-0000-0000-0000000000a1"
SITE_ID = "00000000-0000-0000-0000-0000000001a1"
DEVICE_ID = "00000000-0000-0000-0000-0000000002a1"


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


@pytest.fixture(scope="session", autouse=True)
def seed_electrical_samples():
    """Insert raw electrical samples for the fixture device and refresh
    the continuous aggregates that depend on them, so native/15m/1h all
    have real rows to route to. Runs once per test session; leaves the
    rows in place afterward (ems_test is a disposable test database, and
    other contract tests already assume additive fixture state)."""

    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        with connection.cursor() as cur:
            now = datetime.now(timezone.utc)
            rows = [
                now - timedelta(minutes=offset)
                for offset in (20, 15, 10, 5, 0)
            ]
            for bucket_start in rows:
                cur.execute(
                    """
                    INSERT INTO telemetry.energy_measurements (
                        bucket_start, organization_id, site_id, device_id,
                        active_power_total_w,
                        voltage_l1_v, voltage_l2_v, voltage_l3_v,
                        voltage_ln_avg_v,
                        current_l1_a, current_l2_a, current_l3_a,
                        neutral_current_a,
                        power_factor_total, frequency_hz,
                        current_thd_l1_percent, current_thd_l2_percent, current_thd_l3_percent,
                        voltage_thd_l1_percent, voltage_thd_l2_percent, voltage_thd_l3_percent
                    ) VALUES (
                        %s, %s, %s, %s,
                        4200.0,
                        231.5, 230.8, 232.1,
                        231.47,
                        18.2, 17.9, 18.5,
                        0.42,
                        0.97, 50.01,
                        2.1, 2.3, 1.9,
                        1.1, 1.3, 1.0
                    )
                    """,
                    (bucket_start, ORGANIZATION_ID, SITE_ID, DEVICE_ID),
                )

        for view in (
            "telemetry.ca_energy_15min",
            "telemetry.ca_energy_hourly",
            "telemetry.ca_energy_electrical_ext_15min",
            "telemetry.ca_energy_electrical_ext_hourly",
        ):
            connection.execute(
                "CALL refresh_continuous_aggregate(%s, NULL, NULL)", (view,)
            )


def _scalar(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchone()[0]


def _rows(conn, sql, params):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


# ---------------------------------------------------------------------------
# Routing thresholds: same <=24h / <=14d / >14d boundaries as the energy
# routing helper (migration 045), verified independently for the
# electrical-trend helper.
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
def test_electrical_routing_thresholds(conn, range_interval, expected_resolution):
    resolution = _scalar(
        conn,
        """
        SELECT analytics.resolve_grafana_electrical_routing_resolution(
            now(),
            now() + %s::interval
        )
        """,
        (range_interval,),
    )
    assert resolution == expected_resolution


# ---------------------------------------------------------------------------
# Data presence + new-column parity at all three zoom levels.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "range_interval",
    ["2 hours", "2 days", "20 days"],
)
def test_electrical_trend_returns_data_at_all_zoom_levels(conn, range_interval):
    rows = _rows(
        conn,
        """
        SELECT
            interval_start, voltage_ln_avg_v, neutral_current_a,
            voltage_thd_l1_percent, voltage_thd_l2_percent, voltage_thd_l3_percent
        FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now() - %s::interval, now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID, range_interval),
    )

    assert rows, f"expected at least one row for range={range_interval}"

    # The newly-added columns (this migration's whole point) must carry
    # real, non-null values at every zoom level, not just exist as NULLs.
    for row in rows:
        _, voltage_ln_avg_v, neutral_current_a, thd_l1, thd_l2, thd_l3 = row
        assert voltage_ln_avg_v is not None
        assert neutral_current_a is not None
        assert thd_l1 is not None
        assert thd_l2 is not None
        assert thd_l3 is not None


def test_native_tier_matches_raw_sample_view(conn):
    routed_rows = _rows(
        conn,
        """
        SELECT interval_start, voltage_ln_avg_v, neutral_current_a
        FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now() - interval '2 hours', now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )

    direct_rows = _rows(
        conn,
        """
        SELECT sample_time, voltage_ln_avg_v, neutral_current_a
        FROM analytics.v_grafana_asset_electrical_samples
        WHERE grafana_org_id = %s
          AND asset_id = %s
          AND sample_time >= now() - interval '2 hours'
          AND sample_time <= now()
        ORDER BY sample_time
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )

    assert routed_rows == direct_rows


def test_fifteen_minute_tier_matches_v_energy_15min(conn):
    routed_rows = _rows(
        conn,
        """
        SELECT interval_start, voltage_ln_avg_v
        FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now() - interval '2 days', now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )

    direct_rows = _rows(
        conn,
        """
        SELECT f.bucket_start, f.voltage_ln_avg_v_avg
        FROM analytics.v_energy_15min f
        WHERE f.grafana_org_id = %s
          AND f.device_id = %s
          AND f.bucket_start >= now() - interval '2 days'
          AND f.bucket_start <= now()
        ORDER BY f.bucket_start
        """,
        (GRAFANA_ORG_ID, DEVICE_ID),
    )

    assert routed_rows == direct_rows


def test_hourly_tier_matches_v_energy_hourly(conn):
    routed_rows = _rows(
        conn,
        """
        SELECT interval_start, voltage_ln_avg_v
        FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now() - interval '20 days', now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )

    direct_rows = _rows(
        conn,
        """
        SELECT h.bucket_start, h.voltage_ln_avg_v_avg
        FROM analytics.v_energy_hourly h
        WHERE h.grafana_org_id = %s
          AND h.device_id = %s
          AND h.bucket_start >= now() - interval '20 days'
          AND h.bucket_start <= now()
        ORDER BY h.bucket_start
        """,
        (GRAFANA_ORG_ID, DEVICE_ID),
    )

    assert routed_rows == direct_rows


def test_invalid_range_returns_no_rows_without_raising(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now(), now() - interval '1 hour'
        )
        """,
        (GRAFANA_ORG_ID, ASSET_ID),
    )
    assert rows == []


def test_unknown_tenant_returns_no_rows(conn):
    rows = _rows(
        conn,
        """
        SELECT * FROM analytics.get_grafana_asset_electrical_trend(
            999999, %s, now() - interval '1 day', now()
        )
        """,
        (ASSET_ID,),
    )
    assert rows == []


# ---------------------------------------------------------------------------
# Multi-asset function: same 10-asset exception safeguard as
# analytics.get_grafana_assets_energy_intervals.
# ---------------------------------------------------------------------------


def test_eleven_assets_raises_exception(conn):
    import uuid

    asset_ids = [str(uuid.uuid4()) for _ in range(11)]

    with pytest.raises(psycopg.errors.RaiseException) as excinfo:
        _rows(
            conn,
            """
            SELECT * FROM analytics.get_grafana_assets_electrical_trend(
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
            SELECT * FROM analytics.get_grafana_assets_electrical_trend(
                %s, NULL::uuid[], now() - interval '1 day', now()
            )
            """,
            (GRAFANA_ORG_ID,),
        )
    assert "must contain at least one asset" in str(excinfo.value)


def test_multi_asset_fanout_matches_single_asset_call(conn):
    rows = _rows(
        conn,
        """
        SELECT asset_id, interval_start, voltage_ln_avg_v
        FROM analytics.get_grafana_assets_electrical_trend(
            %s, %s::uuid[], now() - interval '2 hours', now()
        )
        ORDER BY interval_start
        """,
        (GRAFANA_ORG_ID, [ASSET_ID]),
    )

    single_rows = _rows(
        conn,
        """
        SELECT %s::uuid, interval_start, voltage_ln_avg_v
        FROM analytics.get_grafana_asset_electrical_trend(
            %s, %s, now() - interval '2 hours', now()
        )
        ORDER BY interval_start
        """,
        (ASSET_ID, GRAFANA_ORG_ID, ASSET_ID),
    )

    assert rows == single_rows
