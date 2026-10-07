"""Contract and functional tests for migration 290 (F1): the 15-minute
register-delta tier analytics.energy_register_delta_15min, its refresh
function, forward job and reconcile job.

Runs against the disposable ems_test database (see conftest.py). Every
functional test builds its own organization / site / Eniscope device and a
site-specific capture policy inside one transaction that is rolled back. The
test holds the forward job's advisory lock for the whole transaction, so the
background scheduler never interferes.
"""

import os
import re
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest
from psycopg.types.json import Jsonb

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

TABLE = "analytics.energy_register_delta_15min"
PIPELINE = "energy_register_delta_15min"
LOCK_KEY = "analytics.run_energy_register_delta_15min_job"
REFRESH_SIG = "analytics.refresh_energy_register_delta_15min(timestamptz, timestamptz)"
FORWARD_SIG = "analytics.run_energy_register_delta_15min_job(integer, jsonb)"
RECONCILE_SIG = "analytics.reconcile_energy_register_delta_15min(integer, jsonb)"
MIGRATION_PATH = (
    Path(__file__).resolve().parents[2] / "postgres" / "migrations" / "290_energy_register_delta_15min.sql"
)

UTC = timezone.utc
T0 = datetime(2026, 9, 1, 10, 0, tzinfo=UTC)  # a closed, 15-minute aligned instant

# energy_measurements column -> register logical point.
COLUMN_POINTS = {
    "import_energy_total_wh": "ENERGY_IMPORT_TOTAL",
    "import_energy_l1_wh": "ENERGY_IMPORT_L1",
    "import_energy_l2_wh": "ENERGY_IMPORT_L2",
    "import_energy_l3_wh": "ENERGY_IMPORT_L3",
    "export_energy_total_wh": "ENERGY_EXPORT_TOTAL",
    "export_energy_l1_wh": "ENERGY_EXPORT_L1",
    "export_energy_l2_wh": "ENERGY_EXPORT_L2",
    "export_energy_l3_wh": "ENERGY_EXPORT_L3",
    "reactive_energy_total_varh": "REACTIVE_ENERGY_TOTAL",
    "reactive_energy_l1_varh": "REACTIVE_ENERGY_L1",
    "reactive_energy_l2_varh": "REACTIVE_ENERGY_L2",
    "reactive_energy_l3_varh": "REACTIVE_ENERGY_L3",
    "reactive_export_energy_total_varh": "ENERGY_REACTIVE_EXPORT_TOTAL",
    "reactive_export_energy_l1_varh": "ENERGY_REACTIVE_EXPORT_L1",
    "reactive_export_energy_l2_varh": "ENERGY_REACTIVE_EXPORT_L2",
    "reactive_export_energy_l3_varh": "ENERGY_REACTIVE_EXPORT_L3",
    "apparent_energy_total_vah": "APPARENT_ENERGY_TOTAL",
    "apparent_energy_l1_vah": "APPARENT_ENERGY_L1",
    "apparent_energy_l2_vah": "APPARENT_ENERGY_L2",
    "apparent_energy_l3_vah": "APPARENT_ENERGY_L3",
}


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


class Fixture:
    def __init__(self, cur):
        self.cur = cur
        self.tag = uuid.uuid4().hex[:8].upper()
        cur.execute("SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")
        row = cur.fetchone()
        if row is None:
            pytest.skip("ENERGY_METER_ENISCOPE_V1 profile is not seeded in this database")
        self.profile_id = row[0]
        cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter'")
        category_id = cur.fetchone()[0]
        cur.execute(
            """
            INSERT INTO metadata.device_models (vendor, model, device_type, device_category_id)
            VALUES ('WiseWatts Test', %s, 'Energy Meter', %s) RETURNING id
            """,
            (f"Register Delta Meter {self.tag}", category_id),
        )
        self.model_id = cur.fetchone()[0]

    def site(self, label: str, capture_seconds: int | None = 60) -> tuple[str, str, str]:
        code = f"RD_{label}_{self.tag}"
        self.cur.execute(
            "INSERT INTO metadata.organizations (name, code) VALUES (%s, %s) RETURNING id",
            (f"Register Delta {label} {self.tag}", code),
        )
        org = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.sites (organization_id, name, code, timezone) VALUES (%s, %s, %s, 'Asia/Kolkata') RETURNING id",
            (org, f"Register Delta Site {label} {self.tag}", code),
        )
        site = self.cur.fetchone()[0]
        self.cur.execute(
            "INSERT INTO metadata.gateways (organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
            (org, site, f"RD GW {label} {self.tag}", f"RD-GW-{label}-{self.tag}"),
        )
        gateway = self.cur.fetchone()[0]
        if capture_seconds is not None:
            self.cur.execute(
                """
                INSERT INTO config.telemetry_capture_policies
                    (site_id, capture_interval_seconds, alignment_mode, late_arrival_tolerance_seconds, effective_from, is_enabled)
                VALUES (%s, %s, 'WALL_CLOCK', 60, '2000-01-01 00:00:00+00', TRUE)
                """,
                (site, capture_seconds),
            )
        return org, site, gateway

    def device(self, org, gateway, name: str) -> str:
        slug = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_")
        self.cur.execute(
            """
            INSERT INTO metadata.devices (organization_id, gateway_id, device_model_id, profile_id, name, external_id)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING id
            """,
            (org, gateway, self.model_id, self.profile_id, name, f"RD_DEV_{slug}_{self.tag}"),
        )
        return self.cur.fetchone()[0]

    def reading(self, org, site, device, at: datetime, **registers) -> None:
        columns = ["bucket_start", "organization_id", "site_id", "device_id", *registers]
        self.cur.execute(
            f"INSERT INTO telemetry.energy_measurements ({', '.join(columns)}) "
            f"VALUES ({', '.join(['%s'] * len(columns))})",
            (at, org, site, device, *registers.values()),
        )

    def series(self, org, site, device, start: datetime, minutes: int, step=10, **base) -> None:
        """One reading per minute; every given register increases by `step`
        per minute from its base value."""
        for i in range(minutes):
            self.reading(org, site, device, start + timedelta(minutes=i),
                         **{col: Decimal(v) + step * i for col, v in base.items()})

    def refresh(self, frm: datetime, to: datetime) -> int:
        self.cur.execute(f"SELECT analytics.refresh_energy_register_delta_15min(%s, %s)", (frm, to))
        return self.cur.fetchone()[0]

    def rows(self, device, point: str):
        self.cur.execute(
            f"""
            SELECT r.bucket_start, r.delta_value, r.source_interval_count, r.valid_interval_count,
                   r.gap_interval_count, r.reset_interval_count, r.rollover_interval_count,
                   r.initial_interval_count, r.invalid_interval_count,
                   r.first_source_bucket, r.last_source_bucket
            FROM {TABLE} AS r JOIN metadata.logical_points AS lp ON lp.id = r.logical_point_id
            WHERE r.device_id = %s AND lp.name = %s
            ORDER BY r.bucket_start
            """,
            (device, point),
        )
        return self.cur.fetchall()


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        with connection.cursor() as cur:
            # Keep the background forward / reconcile jobs out of this transaction.
            cur.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s, 0))", (LOCK_KEY,))
        yield connection
        connection.rollback()


@pytest.fixture
def fx(tx):
    with tx.cursor() as cur:
        yield Fixture(cur)


# ---------------------------------------------------------------------------
# Contract
# ---------------------------------------------------------------------------


def test_table_hypertable_policies_and_identity():
    with psycopg.connect(CONNINFO) as conn:
        cols = dict(conn.execute(
            """
            SELECT column_name, is_nullable FROM information_schema.columns
            WHERE table_schema = 'analytics' AND table_name = 'energy_register_delta_15min'
            """
        ).fetchall())
        chunk = conn.execute(
            """
            SELECT time_interval FROM timescaledb_information.dimensions
            WHERE hypertable_schema = 'analytics' AND hypertable_name = 'energy_register_delta_15min'
            """
        ).fetchone()[0]
        policies = dict(conn.execute(
            """
            SELECT proc_name, CASE proc_name WHEN 'policy_retention' THEN config ->> 'drop_after'
                                             ELSE config ->> 'compress_after' END
            FROM timescaledb_information.jobs
            WHERE hypertable_schema = 'analytics' AND hypertable_name = 'energy_register_delta_15min' AND scheduled
            """
        ).fetchall())
        unique_cols = conn.execute(
            """
            SELECT array_agg(a.attname ORDER BY k.ord)
            FROM pg_index AS i
            JOIN pg_class AS c ON c.oid = i.indexrelid
            CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
            JOIN pg_attribute AS a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
            WHERE c.relname = 'ux_energy_register_delta_15min_identity' AND i.indisunique
            """
        ).fetchone()[0]

    for identity in ("bucket_start", "organization_id", "site_id", "device_id", "logical_point_id"):
        assert cols[identity] == "NO"
    assert cols["delta_value"] == "YES"
    assert not any("asset" in c or "timezone" in c for c in cols)
    assert chunk == timedelta(days=7)
    assert policies == {"policy_retention": "2 years", "policy_compression": "30 days"}
    assert unique_cols == ["device_id", "logical_point_id", "bucket_start"]


def test_jobs_scheduled_with_their_configs():
    with psycopg.connect(CONNINFO) as conn:
        jobs = {
            name: (scheduled, config, interval)
            for name, scheduled, config, interval in conn.execute(
                """
                SELECT proc_name, scheduled, config, schedule_interval FROM timescaledb_information.jobs
                WHERE proc_schema = 'analytics'
                  AND proc_name IN ('run_energy_register_delta_15min_job', 'reconcile_energy_register_delta_15min')
                """
            ).fetchall()
        }
    assert jobs["run_energy_register_delta_15min_job"] == (
        True, {"max_catchup_window": "1 day", "overlap": "1 hour"}, timedelta(minutes=5))
    assert jobs["reconcile_energy_register_delta_15min"] == (
        True, {"reconcile_window": "3 days", "coarse": "1 day"}, timedelta(days=1))


def test_routine_security_and_grants():
    with psycopg.connect(CONNINFO) as conn:
        for sig in (REFRESH_SIG, FORWARD_SIG, RECONCILE_SIG):
            row = conn.execute(
                """
                SELECT p.prosecdef, r.rolname,
                       has_function_privilege('public', p.oid, 'EXECUTE'),
                       has_function_privilege('ems_app', p.oid, 'EXECUTE'),
                       has_function_privilege('ems_admin', p.oid, 'EXECUTE')
                FROM pg_proc AS p JOIN pg_roles AS r ON r.oid = p.proowner
                WHERE p.oid = %s::regprocedure
                """,
                (sig,),
            ).fetchone()
            assert row == (True, "ems_admin", False, False, True), sig
        grants = conn.execute(
            """
            SELECT has_table_privilege('ems_app', %s, 'SELECT'), has_table_privilege('ems_app', %s, 'INSERT'),
                   has_table_privilege('ems_readonly', %s, 'SELECT')
            """,
            (TABLE, TABLE, TABLE),
        ).fetchone()
    assert grants == (True, False, True)


def test_migration_touches_no_energy_path_raw_retention_or_read_path():
    sql = MIGRATION_PATH.read_text(encoding="utf-8").lower()
    for forbidden in (
        "insert into analytics.energy_consumption", "update analytics.energy_consumption",
        "alter table telemetry.energy_measurements", "remove_retention_policy",
        "create or replace function analytics.classify_energy_register_delta",
        "update config.energy_register_semantics", "get_portal_", "delete from",
    ):
        assert forbidden not in sql, forbidden
    assert "add_retention_policy('analytics.energy_register_delta_15min'" in sql


def test_pipeline_state_row_exists():
    with psycopg.connect(CONNINFO) as conn:
        assert conn.execute(
            "SELECT count(*) FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,)
        ).fetchone()[0] == 1


# ---------------------------------------------------------------------------
# Refresh semantics
# ---------------------------------------------------------------------------


def test_every_register_is_mapped_and_deltas_are_classified(fx):
    org, site, gw = fx.site("A")
    dev = fx.device(org, gw, "A Meter")
    base = {col: 1000 * (i + 1) for i, col in enumerate(COLUMN_POINTS)}
    fx.series(org, site, dev, T0, 6, step=10, **base)
    assert fx.refresh(T0, T0 + timedelta(minutes=15)) == len(COLUMN_POINTS)

    for point in COLUMN_POINTS.values():
        (row,) = fx.rows(dev, point)
        bucket, delta, source, valid, gap, reset, rollover, initial, invalid, first, last = row
        assert bucket == T0
        # First reading of the device has no predecessor (INITIAL); five valid
        # one-minute deltas of 10 follow.
        assert (delta, source, valid, gap, reset, rollover, initial, invalid) == (Decimal(50), 6, 5, 0, 0, 0, 1, 0), point
        assert (first, last) == (T0, T0 + timedelta(minutes=5))


def test_predecessor_before_the_window_is_used(fx):
    org, site, gw = fx.site("B")
    dev = fx.device(org, gw, "B Meter")
    fx.series(org, site, dev, T0 - timedelta(minutes=2), 5, step=10, import_energy_total_wh=500)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    # Readings at T0, T0+1, T0+2 each close a valid delta, including the one
    # whose predecessor (T0-1) lies before the refreshed window.
    assert (row[1], row[2], row[3], row[7]) == (Decimal(30), 3, 3, 0)


def test_gap_keeps_its_delta_and_is_counted(fx):
    org, site, gw = fx.site("C")
    dev = fx.device(org, gw, "C Meter")
    fx.reading(org, site, dev, T0, import_energy_total_wh=100)
    fx.reading(org, site, dev, T0 + timedelta(minutes=1), import_energy_total_wh=110)
    fx.reading(org, site, dev, T0 + timedelta(minutes=6), import_energy_total_wh=160)  # 5 min > 1.5 min
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    # (delta, source, valid, gap, reset, rollover, initial, invalid)
    assert tuple(row[1:9]) == (Decimal(60), 3, 2, 1, 0, 0, 1, 0)


def test_five_minute_capture_uses_the_native_threshold(fx):
    org, site, gw = fx.site("D", capture_seconds=300)
    dev = fx.device(org, gw, "D Meter")
    for i in range(3):
        fx.reading(org, site, dev, T0 + timedelta(minutes=5 * i), import_energy_total_wh=100 + 50 * i)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    # 5-minute steps are within 7.5 minutes: GOOD, not GAP.
    assert tuple(row[1:9]) == (Decimal(100), 3, 2, 0, 0, 0, 1, 0)


def test_reset_and_implausible_jump_are_rejected(fx):
    org, site, gw = fx.site("E")
    dev = fx.device(org, gw, "E Meter")
    values = [1000, 1010, 5, 15, 15 + 2_000_000, 15 + 2_000_010]
    for i, v in enumerate(values):
        fx.reading(org, site, dev, T0 + timedelta(minutes=i), import_energy_total_wh=v)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    # Valid: 1000->1010 (10), 5->15 (10), jump->+10 (10). Rejected: the
    # decrease (RESET) and the 2,000,000 jump (IMPLAUSIBLE_DELTA).
    assert tuple(row[1:9]) == (Decimal(30), 6, 3, 0, 1, 0, 1, 2)


def test_no_delta_spans_two_devices(fx):
    org, site, gw = fx.site("F")
    dev_a = fx.device(org, gw, "F Meter A")
    dev_b = fx.device(org, gw, "F Meter B")
    fx.series(org, site, dev_a, T0, 3, step=10, import_energy_total_wh=100)
    fx.series(org, site, dev_b, T0 + timedelta(minutes=3), 3, step=10, import_energy_total_wh=900_000)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (a,) = fx.rows(dev_a, "ENERGY_IMPORT_TOTAL")
    (b,) = fx.rows(dev_b, "ENERGY_IMPORT_TOTAL")
    assert (a[1], a[7]) == (Decimal(20), 1)
    assert (b[1], b[7]) == (Decimal(20), 1)  # B's first reading is INITIAL, never 900,000 - 120


def test_bucket_attribution_follows_the_closing_reading(fx):
    org, site, gw = fx.site("G")
    dev = fx.device(org, gw, "G Meter")
    fx.series(org, site, dev, T0 + timedelta(minutes=13), 4, step=10, import_energy_total_wh=100)
    fx.refresh(T0, T0 + timedelta(minutes=30))
    rows = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    # 13 (initial), 14 -> bucket T0; 15, 16 -> bucket T0+15.
    assert [(r[0], r[1], r[2]) for r in rows] == [
        (T0, Decimal(10), 2),
        (T0 + timedelta(minutes=15), Decimal(20), 2),
    ]


def test_registers_a_device_never_reports_produce_no_rows(fx):
    org, site, gw = fx.site("H")
    dev = fx.device(org, gw, "H Meter")
    fx.series(org, site, dev, T0, 3, step=10, import_energy_total_wh=100)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    assert fx.rows(dev, "ENERGY_IMPORT_L1") == []
    assert len(fx.rows(dev, "ENERGY_IMPORT_TOTAL")) == 1


def test_scale_to_normalized_unit_is_applied(fx):
    org, site, gw = fx.site("I")
    dev = fx.device(org, gw, "I Meter")
    fx.cur.execute(
        """
        UPDATE config.energy_register_semantics AS ers SET scale_to_normalized_unit = 0.001
        FROM metadata.logical_points AS lp
        WHERE lp.id = ers.logical_point_id AND lp.name = 'APPARENT_ENERGY_L2' AND ers.profile_id = %s
        """,
        (fx.profile_id,),
    )
    fx.series(org, site, dev, T0, 3, step=1000, apparent_energy_l2_vah=0)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    (row,) = fx.rows(dev, "APPARENT_ENERGY_L2")
    assert row[1] == Decimal(2)


def test_rows_without_a_capture_policy_are_not_processed(fx):
    org, site, gw = fx.site("J", capture_seconds=None)
    dev = fx.device(org, gw, "J Meter")
    fx.series(org, site, dev, T0, 3, step=10, import_energy_total_wh=100)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    assert fx.rows(dev, "ENERGY_IMPORT_TOTAL") == []


def test_refresh_is_value_aware_and_idempotent(fx):
    org, site, gw = fx.site("K")
    dev = fx.device(org, gw, "K Meter")
    fx.series(org, site, dev, T0, 5, step=10, import_energy_total_wh=100, apparent_energy_total_vah=200)
    assert fx.refresh(T0, T0 + timedelta(minutes=15)) == 2
    assert fx.refresh(T0, T0 + timedelta(minutes=15)) == 0
    fx.reading(org, site, dev, T0 + timedelta(minutes=5), import_energy_total_wh=150, apparent_energy_total_vah=250)
    assert fx.refresh(T0, T0 + timedelta(minutes=15)) == 2


@pytest.mark.parametrize(
    "frm, to",
    [
        (None, T0),
        (T0, None),
        (T0, T0),
        (T0 + timedelta(minutes=1), T0 + timedelta(minutes=15)),
        (T0, T0 + timedelta(minutes=14)),
        (T0, T0 + timedelta(days=2, minutes=15)),
        (T0, datetime(2100, 1, 1, tzinfo=UTC)),
    ],
)
def test_refresh_guards(tx, frm, to):
    with tx.cursor() as cur:
        with pytest.raises(psycopg.errors.InvalidParameterValue):
            cur.execute("SELECT analytics.refresh_energy_register_delta_15min(%s, %s)", (frm, to))


# ---------------------------------------------------------------------------
# Forward and reconcile jobs
# ---------------------------------------------------------------------------


def _checkpoint(cur):
    cur.execute("SELECT last_received_at, last_status FROM telemetry.pipeline_state WHERE pipeline_name = %s", (PIPELINE,))
    return cur.fetchone()


def _set_checkpoint(cur, at):
    cur.execute("UPDATE telemetry.pipeline_state SET last_received_at = %s WHERE pipeline_name = %s", (at, PIPELINE))


def test_forward_first_run_starts_at_the_earliest_source_row(fx):
    org, site, gw = fx.site("L")
    dev = fx.device(org, gw, "L Meter")
    early = datetime(2020, 1, 6, 8, 7, tzinfo=UTC)  # earlier than any other fixture row
    fx.series(org, site, dev, early, 3, step=10, import_energy_total_wh=100)
    _set_checkpoint(fx.cur, None)
    fx.cur.execute("CALL analytics.run_energy_register_delta_15min_job(0, %s)",
                   (Jsonb({"max_catchup_window": "1 day", "overlap": "1 hour"}),))
    start = datetime(2020, 1, 6, 8, 0, tzinfo=UTC)
    assert _checkpoint(fx.cur) == (start + timedelta(days=1), "SUCCESS")
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    assert (row[0], row[1]) == (start, Decimal(20))


def test_forward_advances_from_the_checkpoint_with_overlap(fx):
    org, site, gw = fx.site("M")
    dev = fx.device(org, gw, "M Meter")
    fx.series(org, site, dev, T0 - timedelta(minutes=30), 40, step=10, import_energy_total_wh=100)
    _set_checkpoint(fx.cur, T0)
    fx.cur.execute("CALL analytics.run_energy_register_delta_15min_job(0, %s)",
                   (Jsonb({"max_catchup_window": "1 hour", "overlap": "30 minutes"}),))
    assert _checkpoint(fx.cur) == (T0 + timedelta(hours=1), "SUCCESS")
    buckets = [r[0] for r in fx.rows(dev, "ENERGY_IMPORT_TOTAL")]
    # Overlap re-derives [T0-30m, T0); the window runs to T0+1h; the readings end at T0+9m.
    assert buckets == [T0 - timedelta(minutes=30), T0 - timedelta(minutes=15), T0]


def test_forward_rejects_bad_config_without_moving_the_checkpoint(fx):
    _set_checkpoint(fx.cur, T0)
    fx.cur.execute("SAVEPOINT bad_config")
    with pytest.raises(psycopg.errors.RaiseException):
        fx.cur.execute("CALL analytics.run_energy_register_delta_15min_job(0, %s)",
                       (Jsonb({"max_catchup_window": "2 days", "overlap": "1 hour"}),))
    fx.cur.execute("ROLLBACK TO SAVEPOINT bad_config")
    assert _checkpoint(fx.cur)[0] == T0


def test_reconcile_absorbs_late_rows_and_never_moves_the_checkpoint(fx):
    org, site, gw = fx.site("N")
    dev = fx.device(org, gw, "N Meter")
    fx.series(org, site, dev, T0, 3, step=10, import_energy_total_wh=100)
    fx.refresh(T0, T0 + timedelta(minutes=15))
    _set_checkpoint(fx.cur, T0 + timedelta(hours=1))
    fx.reading(org, site, dev, T0 + timedelta(minutes=3), import_energy_total_wh=200)  # late row
    fx.cur.execute("CALL analytics.reconcile_energy_register_delta_15min(0, %s)",
                   (Jsonb({"reconcile_window": "3 days", "coarse": "1 day"}),))
    (row,) = fx.rows(dev, "ENERGY_IMPORT_TOTAL")
    assert (row[1], row[2]) == (Decimal(100), 4)
    assert _checkpoint(fx.cur)[0] == T0 + timedelta(hours=1)
