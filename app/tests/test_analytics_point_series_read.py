"""Migration 292 (Analytics B3): analytics.get_portal_asset_point_series,
analytics.get_portal_analytics_point_availability and
analytics.get_analytics_point_resolution_floors.

Covers units (field-mapping scale / offset, register delta scale), the
site-local 15m/30m/1h/1d composition of the 15-minute tier, 1m from raw
samples, attribution at binding boundaries, per-phase Energy from the
register-delta tier, Data Quality (interval counts, data state, quality),
capture-policy and retention-floor reasons, availability bounds and tenancy.

Runs against the disposable ems_test database; every test is one rolled-back
transaction. analytics.point_telemetry_15m is a continuous aggregate whose
refresh cannot run inside a transaction, so tests seed its materialization
hypertable directly (test-only; the view is materialized_only).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, Tenant

UTC = timezone.utc
SERIES = "analytics.get_portal_asset_point_series"
SERIES_SIG = f"{SERIES}(bigint, uuid, uuid[], text[], text[], timestamptz, timestamptz, text, timestamptz)"
AVAIL = "analytics.get_portal_analytics_point_availability"
AVAIL_SIG = f"{AVAIL}(bigint, uuid, text[], text[])"
FLOORS_SIG = "analytics.get_analytics_point_resolution_floors(timestamptz)"
SCALE_SIG = "analytics.analytics_point_source_scale(uuid, uuid)"

# A whole UTC day a few days back: inside every retention window.
DAY = (datetime.now(UTC) - timedelta(days=4)).replace(hour=0, minute=0, second=0, microsecond=0)
LATER = DAY + timedelta(days=2)   # as_of for completed-history reads


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


@pytest.fixture
def t(tx):
    return Tenant(tx.cursor())


@pytest.fixture
def ist(tx):
    return Tenant(tx.cursor(), tz="Asia/Kolkata")


def _point_id(cur, name: str) -> str:
    cur.execute("SELECT id FROM metadata.logical_points WHERE name = %s", (name,))
    row = cur.fetchone()
    if row is None:
        pytest.skip(f"logical point {name} is not seeded")
    return str(row[0])


def _scale(cur, device: str, point: str) -> tuple[Decimal, Decimal, Decimal]:
    cur.execute(f"SELECT scale, value_offset, delta_scale FROM {SCALE_SIG.split('(')[0]}(%s, %s)", (device, point))
    return cur.fetchone()


def _materialization(cur) -> str:
    cur.execute(
        """
        SELECT quote_ident(materialization_hypertable_schema) || '.' || quote_ident(materialization_hypertable_name)
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'analytics' AND view_name = 'point_telemetry_15m'
        """
    )
    return cur.fetchone()[0]


def seed_15m(t: Tenant, device: str, point: str, start: datetime, *, total, count, low, high) -> None:
    t.cur.execute(
        f"""
        INSERT INTO {_materialization(t.cur)}
            (bucket_start, organization_id, site_id, device_id, logical_point_id,
             sum_value, sample_count, min_value, max_value)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
        """,
        (start, t.org, t.site, device, point, Decimal(str(total)), count, Decimal(str(low)), Decimal(str(high))),
    )


def seed_raw(t: Tenant, device: str, point: str, at: datetime, value, quality: str = "GOOD") -> None:
    t.cur.execute(
        """
        INSERT INTO telemetry.normalized_points (
            event_time, organization_id, site_id, device_id, logical_point_id,
            device_uid, logical_point, raw_field_name, raw_value, numeric_value,
            quality_code, mapping_source)
        VALUES (%s, %s, %s, %s, %s, 'b3-test', 'b3', 'b3', %s, %s, %s, 'test-fixture-292')
        """,
        (at, t.org, t.site, device, point, None if value is None else str(value),
         None if value is None else Decimal(str(value)), quality),
    )


def seed_delta(t: Tenant, device: str, point: str, start: datetime, wh, *, valid=15, gap=0, reset=0,
               invalid=0, initial=0) -> None:
    source = valid + invalid + initial
    t.cur.execute(
        """
        INSERT INTO analytics.energy_register_delta_15min (
            bucket_start, organization_id, site_id, device_id, logical_point_id, delta_value,
            source_interval_count, valid_interval_count, gap_interval_count, reset_interval_count,
            rollover_interval_count, initial_interval_count, invalid_interval_count,
            first_source_bucket, last_source_bucket)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 0, %s, %s, %s, %s)
        """,
        (start, t.org, t.site, device, point, None if valid == 0 else Decimal(str(wh)),
         source, valid, gap, reset, initial, invalid, start, start + timedelta(minutes=14)),
    )


def _q(value):
    """Compare numerics at 9 decimal places (PostgreSQL numeric division
    keeps fewer digits than Python's Decimal context)."""

    return None if value is None else round(Decimal(value), 9)


def series(t: Tenant, specs, start, end, resolution, *, as_of=LATER, user=None) -> dict[int, list[dict]]:
    t.cur.execute(
        f"SELECT * FROM {SERIES}(%s, %s, %s::uuid[], %s::text[], %s::text[], %s, %s, %s, %s)",
        (user or t.user, t.site, [s[0] for s in specs], [s[1] for s in specs], [s[2] for s in specs],
         start, end, resolution, as_of),
    )
    names = [c.name for c in t.cur.description]
    out: dict[int, list[dict]] = {}
    for row in t.cur.fetchall():
        r = dict(zip(names, row))
        out.setdefault(r["series_index"], []).append(r)
    return out


def metered(t: Tenant, name: str = "Pump", *, start=DAY - timedelta(days=30), points=("ACTIVE_POWER_TOTAL",)):
    device = t.device(f"{name} meter")
    asset = t.asset(name)
    for p in points:
        t.bind(asset, device, p, start=start)
    return asset, device


# ---------------------------------------------------------------------------
# Contract / security
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("sig", [SERIES_SIG, AVAIL_SIG, FLOORS_SIG])
def test_functions_are_definer_stable_ems_app_only_and_never_grafana_keyed(sig):
    with psycopg.connect(CONNINFO) as connection:
        row = connection.execute(
            """
            SELECT p.prosecdef, p.provolatile, r.rolname, p.proconfig IS NOT NULL,
                   has_function_privilege('public', p.oid, 'EXECUTE'),
                   has_function_privilege('grafana_reader', p.oid, 'EXECUTE'),
                   has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                   lower(pg_get_functiondef(p.oid))
            FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
            WHERE p.oid = %s::regprocedure
            """,
            (sig,),
        ).fetchone()
    assert row[:7] == (True, "s", "ems_admin", True, False, False, True)
    for forbidden in ("grafana", "primary_meter", "insert into", "update ", "delete from", "refresh_continuous"):
        assert forbidden not in row[7], forbidden


def test_unit_helper_is_internal():
    with psycopg.connect(CONNINFO) as connection:
        public, app = connection.execute(
            "SELECT has_function_privilege('public', %s::regprocedure, 'EXECUTE'),"
            "       has_function_privilege('ems_app', %s::regprocedure, 'EXECUTE')",
            (SCALE_SIG, SCALE_SIG),
        ).fetchone()
    assert (public, app) == (False, False)


def test_floors_follow_the_live_retention_policies(tx):
    as_of = datetime(2026, 10, 9, 12, 0, tzinfo=UTC)
    rows = tx.execute(f"SELECT source_kind, resolution, earliest_available FROM {FLOORS_SIG.split('(')[0]}(%s)", (as_of,)).fetchall()
    keep = dict(tx.execute(
        """
        SELECT hypertable_name, (config ->> 'drop_after')::interval FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
          AND hypertable_name IN ('normalized_points', 'point_telemetry_15m', 'energy_register_delta_15min')
        """
    ).fetchall())
    floors = {(k, r): f for k, r, f in rows}
    assert floors[("mean", "1m")] == as_of - keep["normalized_points"]
    for r in ("15m", "30m", "1h", "1d"):
        assert floors[("mean", r)] == as_of - keep["point_telemetry_15m"]
        assert floors[("delta", r)] == as_of - keep["energy_register_delta_15min"]
    assert ("delta", "1m") not in floors


# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------


def test_measurements_are_converted_like_live_telemetry(t):
    """Eniscope stores W; the series is kW with the profile mapping's scale."""

    asset, device = metered(t)
    point = _point_id(t.cur, "ACTIVE_POWER_TOTAL")
    scale, offset, _ = _scale(t.cur, device, point)
    seed_15m(t, device, point, DAY, total=15000, count=15, low=500, high=1500)
    rows = series(t, [(asset, "ACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(minutes=15), "15m")[1]
    assert len(rows) == 1
    r = rows[0]
    assert r["source_kind"] == "mean"
    assert r["value"] == Decimal(1000) * scale + offset
    assert (r["min_value"], r["max_value"]) == (Decimal(500) * scale + offset, Decimal(1500) * scale + offset)


def test_device_override_scale_offset_and_negative_scale(t):
    """No profile mapping: the device override applies (mean = scale x mean +
    offset); a negative scale swaps min and max."""

    device = t.device("Override meter")
    t.cur.execute("UPDATE metadata.devices SET profile_id = NULL WHERE id = %s", (device,))
    point = _point_id(t.cur, "FREQUENCY")
    t.cur.execute(
        "INSERT INTO config.device_point_configuration (device_id, logical_point_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
        (device, point),
    )
    asset = t.asset("Override")
    t.bind(asset, device, "FREQUENCY", start=DAY - timedelta(days=1))
    t.cur.execute(
        "INSERT INTO metadata.device_field_mapping (device_id, raw_field_name, logical_point_id, scale_to_canonical_unit, offset_to_canonical_unit) "
        "VALUES (%s, 'f', %s, -2, 10)",
        (device, point),
    )
    seed_15m(t, device, point, DAY, total=30, count=3, low=5, high=15)   # mean 10
    r = series(t, [(asset, "FREQUENCY", None)], DAY, DAY + timedelta(minutes=15), "15m")[1][0]
    assert r["value"] == Decimal(-10)
    assert (r["min_value"], r["max_value"]) == (Decimal(-20), Decimal(0))


def test_unmapped_point_is_unchanged(t):
    device = t.device("Bare meter")
    t.cur.execute("UPDATE metadata.devices SET profile_id = NULL WHERE id = %s", (device,))
    point = _point_id(t.cur, "FREQUENCY")
    assert _scale(t.cur, device, point) == (Decimal(1), Decimal(0), Decimal(1))


# ---------------------------------------------------------------------------
# Resolutions and the site-local grid
# ---------------------------------------------------------------------------


def test_1m_reads_raw_samples_with_invalid_counted(t):
    asset, device = metered(t, points=("CURRENT_L1",))
    point = _point_id(t.cur, "CURRENT_L1")
    seed_raw(t, device, point, DAY + timedelta(seconds=5), 10)
    seed_raw(t, device, point, DAY + timedelta(seconds=35), 20)
    seed_raw(t, device, point, DAY + timedelta(minutes=1, seconds=5), 99, quality="INVALID_NUMERIC")
    rows = series(t, [(asset, "CURRENT", "L1")], DAY, DAY + timedelta(minutes=3), "1m")[1]
    assert [(r["value"], r["min_value"], r["max_value"], r["valid_intervals"], r["invalid_intervals"]) for r in rows] == [
        (Decimal(15), Decimal(10), Decimal(20), 1, 0),   # 2 samples capped at 1 expected interval
        (None, None, None, 0, 1),
        (None, None, None, 0, 0),
    ]


def test_ist_30m_1h_and_1d_compose_15_minute_rows_on_the_local_grid(ist):
    """IST (+05:30): a local hour starts at :30 UTC. Means are exact (sum /
    count), not averages of averages."""

    asset, device = metered(ist, points=("VOLTAGE_L1",))
    point = _point_id(ist.cur, "VOLTAGE_L1")
    local_midnight = DAY - timedelta(hours=5, minutes=30)          # 00:00 IST
    seed_15m(ist, device, point, local_midnight, total=2300, count=10, low=228, high=232)               # mean 230
    seed_15m(ist, device, point, local_midnight + timedelta(minutes=15), total=1200, count=5, low=239, high=241)  # mean 240
    seed_15m(ist, device, point, local_midnight + timedelta(minutes=45), total=250, count=1, low=250, high=250)

    half = series(ist, [(asset, "VOLTAGE_LINE_NEUTRAL", "L1")], local_midnight, local_midnight + timedelta(hours=1), "30m")[1]
    assert [(r["bucket_start"], _q(r["value"])) for r in half] == [
        (local_midnight, _q(Decimal(3500) / 15)),
        (local_midnight + timedelta(minutes=30), _q(250)),
    ]
    assert (half[0]["min_value"], half[0]["max_value"]) == (Decimal(228), Decimal(241))

    hour = series(ist, [(asset, "VOLTAGE_LINE_NEUTRAL", "L1")], local_midnight, local_midnight + timedelta(hours=1), "1h")[1]
    assert [(r["bucket_start"], _q(r["value"])) for r in hour] == [(local_midnight, _q(Decimal(3750) / 16))]

    day = series(ist, [(asset, "VOLTAGE_LINE_NEUTRAL", "L1")], local_midnight, local_midnight + timedelta(days=1), "1d")[1]
    assert [(r["bucket_start"], r["bucket_end"], _q(r["value"])) for r in day] == [
        (local_midnight, local_midnight + timedelta(days=1), _q(Decimal(3750) / 16))
    ]
    assert day[0]["expected_intervals"] == 1440


def test_a_binding_starting_mid_bucket_attributes_only_its_own_samples(t):
    """A binding starting 12:07: the persisted 12:00 row straddles it and is
    never used (it holds pre-assignment samples); that bucket's attributed
    part comes from the raw samples from 12:07 on, at every resolution."""

    device = t.device("Late meter")
    asset = t.asset("Late")
    t.bind(asset, device, "FREQUENCY", start=(DAY + timedelta(hours=12, minutes=7)).isoformat())
    point = _point_id(t.cur, "FREQUENCY")
    seed_15m(t, device, point, DAY + timedelta(hours=12), total=500, count=10, low=50, high=50)
    seed_15m(t, device, point, DAY + timedelta(hours=12, minutes=15), total=750, count=15, low=50, high=50)
    noon = DAY + timedelta(hours=12)

    rows = series(t, [(asset, "FREQUENCY", None)], noon, noon + timedelta(minutes=30), "15m")[1]
    assert [(r["value"], r["data_state"]) for r in rows] == [(None, "BEFORE_DATA"), (Decimal(50), "MEASURED")]
    assert rows[0]["first_data_at"] == noon + timedelta(minutes=15)

    seed_raw(t, device, point, noon + timedelta(minutes=6, seconds=30), 49)    # before the assignment
    seed_raw(t, device, point, noon + timedelta(minutes=7, seconds=30), 51)
    raw = series(t, [(asset, "FREQUENCY", None)], noon + timedelta(minutes=6), noon + timedelta(minutes=8), "1m")[1]
    assert [(r["value"], r["data_state"]) for r in raw] == [(None, "NOT_ASSIGNED"), (Decimal(51), "MEASURED")]

    rows = series(t, [(asset, "FREQUENCY", None)], noon, noon + timedelta(minutes=30), "15m")[1]
    assert [(r["value"], r["valid_intervals"], r["data_state"]) for r in rows] == [
        (Decimal(51), 1, "MEASURED"),
        (Decimal(50), 15, "MEASURED"),
    ]
    assert rows[0]["first_data_at"] == noon + timedelta(minutes=7, seconds=30)
    half = series(t, [(asset, "FREQUENCY", None)], noon, noon + timedelta(minutes=30), "30m")[1]
    assert [_q(r["value"]) for r in half] == [_q(Decimal(801) / 16)]


# ---------------------------------------------------------------------------
# Data Quality
# ---------------------------------------------------------------------------


def test_quality_interval_counts_and_data_states(t):
    asset, device = metered(t, points=("POWER_FACTOR_TOTAL",))
    point = _point_id(t.cur, "POWER_FACTOR_TOTAL")
    for i, n in enumerate((15, 9, 0, 15)):
        if n:
            seed_15m(t, device, point, DAY + timedelta(minutes=15 * i), total=Decimal("0.9") * n, count=n, low="0.9", high="0.9")
    as_of = DAY + timedelta(minutes=50)            # inside the 4th bucket
    rows = series(t, [(asset, "POWER_FACTOR", "TOTAL")], DAY, DAY + timedelta(hours=1, minutes=15), "15m", as_of=as_of)[1]
    got = [(r["data_state"], r["quality"], r["valid_intervals"], r["expected_intervals"], r["assigned_expected_intervals"]) for r in rows]
    assert got[0] == ("MEASURED", "GOOD", 15, 15, 15)
    assert got[1] == ("MEASURED", "PARTIAL", 9, 15, 15)
    assert got[2] == ("GAP", "GAP", 0, 15, 15)
    assert got[3][0:2] == ("MEASURED", "GOOD")         # in progress: 5 elapsed intervals, all measured
    assert got[3][4] == 5
    assert got[4][0:2] == ("FUTURE", None)
    assert rows[0]["assigned_in_range"] is True


def test_no_data_ever_and_not_assigned_in_range(t):
    asset, device = metered(t, points=("REACTIVE_POWER_TOTAL",), start=(DAY + timedelta(days=1)).isoformat())
    rows = series(t, [(asset, "REACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(hours=1), "15m")[1]
    assert {r["data_state"] for r in rows} == {"NOT_ASSIGNED"}
    assert rows[0]["assigned_in_range"] is False
    assert (rows[0]["first_data_at"], rows[0]["last_data_at"]) == (None, None)


# ---------------------------------------------------------------------------
# Per-phase Energy
# ---------------------------------------------------------------------------


def test_per_phase_energy_sums_register_deltas_in_kwh(t):
    asset, device = metered(t, points=("ENERGY_IMPORT_L1",))
    point = _point_id(t.cur, "ENERGY_IMPORT_L1")
    _, _, delta_scale = _scale(t.cur, device, point)
    seed_delta(t, device, point, DAY, 1000)
    seed_delta(t, device, point, DAY + timedelta(minutes=15), 500, gap=2)
    seed_delta(t, device, point, DAY + timedelta(minutes=30), None, valid=0, reset=1, invalid=1)
    rows = series(t, [(asset, "ENERGY_IMPORT", "L1")], DAY, DAY + timedelta(hours=1), "30m")[1]
    assert rows[0]["source_kind"] == "delta"
    assert [(r["value"], r["gap_intervals"], r["reset_intervals"], r["invalid_intervals"], r["quality"]) for r in rows] == [
        (Decimal(1500) * delta_scale, 2, 0, 0, None),
        (None, 0, 1, 1, None),
    ]
    assert rows[0]["min_value"] is None


def test_per_phase_energy_has_no_1m_source(t):
    asset, _ = metered(t, points=("ENERGY_IMPORT_L1",))
    with pytest.raises(psycopg.errors.InvalidParameterValue):
        series(t, [(asset, "ENERGY_IMPORT", "L1")], DAY, DAY + timedelta(hours=1), "1m")


# ---------------------------------------------------------------------------
# Reasons
# ---------------------------------------------------------------------------


def test_before_retention_floor(t):
    asset, _ = metered(t)
    as_of = datetime.now(UTC)
    start = (as_of - timedelta(days=200)).replace(hour=0, minute=0, second=0, microsecond=0)
    rows = series(t, [(asset, "ACTIVE_POWER", "TOTAL")], start, start + timedelta(days=1), "15m", as_of=as_of)[1]
    assert [r["unavailable_reasons"] for r in rows] == [["BEFORE_RETENTION_FLOOR"]]


def test_capture_interval_too_coarse_for_1m(tx):
    t = Tenant(tx.cursor(), capture=300)
    asset, _ = metered(t)
    rows = series(t, [(asset, "ACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(hours=1), "1m")[1]
    assert [r["unavailable_reasons"] for r in rows] == [["CAPTURE_INTERVAL_TOO_COARSE"]]


# ---------------------------------------------------------------------------
# Tenancy and selection resolution
# ---------------------------------------------------------------------------


def test_series_index_follows_the_request_and_unservable_selections_return_nothing(t):
    asset, device = metered(t, points=("ACTIVE_POWER_L1", "ACTIVE_POWER_L2"))
    draft = t.asset("Draft", lifecycle="DRAFT")
    t.bind(draft, device, "ACTIVE_POWER_L3")
    out = series(t, [(asset, "ACTIVE_POWER", "L2"), (str(uuid.uuid4()), "ACTIVE_POWER", "L1"),
                     (draft, "ACTIVE_POWER", "L3"), (asset, "NOT_A_PARAMETER", "L1"), (asset, "ACTIVE_POWER", "L1")],
                 DAY, DAY + timedelta(minutes=15), "15m")
    assert sorted(out) == [1, 5]
    assert (out[1][0]["qualifier"], out[5][0]["qualifier"]) == ("L2", "L1")


def test_another_tenants_user_reads_nothing(tx):
    a = Tenant(tx.cursor())
    b = Tenant(tx.cursor())
    asset, device = metered(a)
    seed_15m(a, device, _point_id(a.cur, "ACTIVE_POWER_TOTAL"), DAY, total=1, count=1, low=1, high=1)
    assert series(a, [(asset, "ACTIVE_POWER", "TOTAL")], DAY, DAY + timedelta(minutes=15), "15m", user=b.user) == {}


def test_availability_bounds_null_without_data_and_tenant_scoped(tx):
    t = Tenant(tx.cursor())
    other = Tenant(tx.cursor())
    asset, device = metered(t, points=("ACTIVE_POWER_TOTAL", "FREQUENCY"))
    point = _point_id(t.cur, "ACTIVE_POWER_TOTAL")
    seed_15m(t, device, point, DAY, total=1, count=1, low=1, high=1)
    seed_15m(t, device, point, DAY + timedelta(hours=3), total=1, count=1, low=1, high=1)

    def avail(user):
        t.cur.execute(f"SELECT * FROM {AVAIL}(%s, %s, %s::text[], %s::text[])",
                      (user, t.site, ["ACTIVE_POWER", "FREQUENCY"], ["TOTAL", None]))
        return {(r[1], r[2]): (r[3], r[4]) for r in t.cur.fetchall()}

    assert avail(t.user) == {
        ("ACTIVE_POWER", "TOTAL"): (DAY, DAY + timedelta(hours=3, minutes=15)),
        ("FREQUENCY", None): (None, None),
    }
    assert avail(other.user) == {}


def _manifest_migrations() -> list[dict]:
    import csv
    from pathlib import Path

    manifest = Path(__file__).resolve().parents[2] / "postgres" / "restructure_manifest.csv"
    rows = list(csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()))
    return [r for r in rows if r["target_category"] == "migration"]


def test_manifest_registers_migration_292():
    migrations = _manifest_migrations()
    files = [r["source_file"] for r in migrations]
    row = migrations[files.index("292_analytics_point_series.sql")]
    assert row["target_path"] == "postgres/migrations/292_analytics_point_series.sql"
    assert files.index("292_analytics_point_series.sql") > files.index("291_environment_loader_bounded_update.sql")


def test_manifest_registers_migration_293_last():
    migrations = _manifest_migrations()
    assert migrations[-1]["source_file"] == "293_analytics_point_series_planner_fences.sql"
    assert migrations[-1]["target_path"] == "postgres/migrations/293_analytics_point_series_planner_fences.sql"


def test_series_read_carries_the_migration_293_planner_fences(tx):
    """Each of the four source probes ends in OFFSET 0 (migration 293), so
    the planner cannot flatten it into a hash / merge join over every chunk
    (staging, 2026-10-09: 30-55 s per series)."""

    cur = tx.cursor()
    cur.execute("SELECT pg_get_functiondef(%s::regprocedure)", (SERIES_SIG,))
    definition = cur.fetchone()[0]
    assert definition.count("OFFSET 0   -- planner fence (migration 293)") == 4
