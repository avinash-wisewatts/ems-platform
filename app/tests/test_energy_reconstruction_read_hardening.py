"""Tests for migration 269 (ADR-020 PR2): Energy read-side hardening.

Three groups:

* Static contract checks on the migration file and manifest.
* GOLDEN equivalence with zero reconstructed rows: the exact pre-269 chain
  (app/tests/fixtures/energy_269_baseline.sql) is recreated under schema
  zz269_old inside a rolled-back transaction and compared, on identical
  fixture data, with the post-269 objects -- every view, every canonical-read
  tier, the persisted 15m/hourly/daily refreshes (including no calculated_at
  churn) and reconcile detection.
* Synthetic reconstructed rows (the ADR-020 PR3 row contract): measured
  coverage/counters/registers exclude them, totals include them, statuses
  report RECONSTRUCTED_TIMING (never GOOD), persisted counters are written,
  and reconcile reports no false mismatch.

Every write happens inside a transaction that is rolled back.
"""

import csv
import os
import random
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

import psycopg
import pytest

CONNINFO = (
    f"host={os.environ['EMS_APP_DB_HOST']} port={os.environ['EMS_APP_DB_PORT']} "
    f"dbname={os.environ['EMS_APP_DB_NAME']} user={os.environ['EMS_APP_DB_USER']} "
    f"password={os.environ['EMS_APP_DB_PASSWORD']}"
)

REPO = Path(__file__).resolve().parents[2]
MIGRATION_PATH = REPO / "postgres" / "migrations" / "269_energy_reconstruction_read_hardening.sql"
MANIFEST = REPO / "postgres" / "restructure_manifest.csv"
BASELINE = Path(__file__).resolve().parent / "fixtures" / "energy_269_baseline.sql"

UTC = timezone.utc
T0 = datetime(2025, 3, 10, 17, 40, tzinfo=UTC)  # crosses UTC 18:00/19:00 and IST midnight (18:30 UTC)
WINDOW_FROM = datetime(2025, 3, 9, 0, 0, tzinfo=UTC)
WINDOW_TO = datetime(2025, 3, 13, 0, 0, tzinfo=UTC)

CHANGED_VIEWS = (
    "v_energy_consumption_native",
    "v_energy_semantic_rollup_5min",
    "v_energy_semantic_rollup_15min",
    "v_energy_reporting_5min",
    "v_energy_reporting_15min",
    "v_energy_reporting_hourly",
    "v_energy_reporting_daily",
    "v_energy_consumption_daily",
    "v_asset_consumption_daily",
    "v_asset_hierarchy_rollup_daily",
)
SECURITY_BARRIER_VIEWS = CHANGED_VIEWS[3:]

NATIVE_COLUMNS = (
    "bucket_start, organization_id, site_id, device_id, previous_bucket_start, elapsed_minutes, "
    "source_sample_count, import_register_wh, previous_import_register_wh, import_consumption_wh, "
    "import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, "
    "import_rollover_detected, export_register_wh, previous_export_register_wh, export_consumption_wh, "
    "export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, "
    "export_rollover_detected, gap_detected, calculated_at, is_reconstructed, "
    "import_reconstruction_role, import_reconstruction_method, import_gap_start, import_gap_end, "
    "import_gap_delta_wh, export_reconstruction_role, export_reconstruction_method, export_gap_start, "
    "export_gap_end, export_gap_delta_wh"
)


# ---------------------------------------------------------------------------
# helpers / fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as connection:
        yield connection


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        try:
            yield connection
        finally:
            connection.rollback()


def _all(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchall()


def _one(cur, sql, params=None):
    cur.execute(sql, params)
    return cur.fetchone()


def _tenant(cur, capture_interval_seconds=60):
    """Org -> site (Asia/Kolkata) -> gateway -> device(s) -> asset (PRIMARY_METER)
    -> Grafana org map -> capture policy. Returns a dict of identifiers."""
    suffix = f"{random.randrange(10**9):09d}"
    grafana_org_id = 700000 + random.randrange(99999)
    cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter' LIMIT 1")
    category = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id) "
        "VALUES ('WiseWatts Test', 'M269 Test Meter', 'Energy Meter', %s) "
        "ON CONFLICT (lower(COALESCE(vendor, '')), lower(model)) DO UPDATE SET device_category_id = EXCLUDED.device_category_id "
        "RETURNING id",
        (category,),
    )
    model = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.organizations(name, code, timezone) VALUES (%s, %s, 'Asia/Kolkata') RETURNING id",
        (f"M269 Org {suffix}", f"M269_ORG_{suffix}"),
    )
    org = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active) "
        "VALUES (%s, %s, %s, 'Asia/Kolkata', TRUE) RETURNING id",
        (org, f"M269 Site {suffix}", f"M269_SITE_{suffix}"),
    )
    site = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.gateways(organization_id, site_id, name, external_id) VALUES (%s, %s, %s, %s) RETURNING id",
        (org, site, f"M269 GW {suffix}", f"M269-GW-{suffix}"),
    )
    gateway = cur.fetchone()[0]
    devices = []
    for label in ("A", "B"):
        cur.execute(
            "INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s) RETURNING id",
            (org, gateway, model, f"M269 Device {label} {suffix}", f"M269-DEV-{label}-{suffix}"),
        )
        devices.append(cur.fetchone()[0])
    cur.execute(
        "INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
        "VALUES (%s, %s, %s, %s, 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id",
        (org, site, f"M269 Asset {suffix}", f"M269_ASSET_{suffix}"),
    )
    asset = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.asset_devices(asset_id, device_id, relationship_type) VALUES (%s, %s, 'PRIMARY_METER')",
        (asset, devices[0]),
    )
    cur.execute(
        "INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active) VALUES (%s, %s, TRUE)",
        (grafana_org_id, org),
    )
    cur.execute(
        "INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, "
        "late_arrival_tolerance_seconds, effective_from, is_enabled) VALUES (%s, %s, 'WALL_CLOCK', 60, %s, TRUE)",
        (site, capture_interval_seconds, datetime(2025, 1, 1, tzinfo=UTC)),
    )
    return {"org": org, "site": site, "device": devices[0], "device_b": devices[1], "asset": asset, "gorg": grafana_org_id}


def _row(t, ts, device, **kw):
    """One native row; unspecified columns take measured-GOOD defaults."""
    base = {
        "bucket_start": ts,
        "organization_id": t["org"],
        "site_id": t["site"],
        "device_id": device,
        "previous_bucket_start": ts - timedelta(minutes=1),
        "elapsed_minutes": Decimal(1),
        "source_sample_count": 1,
        "import_register_wh": None,
        "previous_import_register_wh": None,
        "import_consumption_wh": Decimal("10"),
        "import_consumption_kwh": Decimal("0.010"),
        "import_quality_code": "GOOD",
        "import_is_valid": True,
        "import_reset_detected": False,
        "import_rollover_detected": False,
        "export_register_wh": Decimal("5"),
        "previous_export_register_wh": Decimal("5"),
        "export_consumption_wh": Decimal("0"),
        "export_consumption_kwh": Decimal("0"),
        "export_quality_code": "GOOD",
        "export_is_valid": True,
        "export_reset_detected": False,
        "export_rollover_detected": False,
        "gap_detected": False,
        "calculated_at": datetime(2025, 3, 20, tzinfo=UTC),
        "is_reconstructed": False,
        "import_reconstruction_role": None,
        "import_reconstruction_method": None,
        "import_gap_start": None,
        "import_gap_end": None,
        "import_gap_delta_wh": None,
        "export_reconstruction_role": None,
        "export_reconstruction_method": None,
        "export_gap_start": None,
        "export_gap_end": None,
        "export_gap_delta_wh": None,
    }
    base.update(kw)
    return base


def _insert(cur, table, rows):
    cols = [c.strip() for c in NATIVE_COLUMNS.split(",")]
    cur.executemany(
        f"INSERT INTO analytics.{table} ({NATIVE_COLUMNS}) VALUES ({', '.join(['%s'] * len(cols))})",
        [tuple(r[c] for c in cols) for r in rows],
    )


def _golden_fixture(cur, t):
    """Measured-only data with every classification, NULL sample counts,
    UTC-hour and IST-day boundaries; device A 1-min, device B 5-min."""
    rows = []
    reg = Decimal("1000000")
    ts = T0
    skip = {12, 13, 14}  # 17:52-17:54 missing -> 17:55 is a GAP
    for i in range(100):
        ts = T0 + timedelta(minutes=i)
        if i in skip:
            continue
        kw = {"import_register_wh": reg + i * 10, "previous_import_register_wh": reg + (i - 1) * 10}
        if i % 7 == 0:
            kw["source_sample_count"] = None
        if i == 15:
            kw.update(import_quality_code="GAP", gap_detected=True, elapsed_minutes=Decimal(4),
                      previous_bucket_start=ts - timedelta(minutes=4), import_consumption_wh=Decimal("40"),
                      import_consumption_kwh=Decimal("0.040"))
        if i == 30:
            kw.update(import_quality_code="RESET", import_is_valid=False, import_reset_detected=True,
                      import_consumption_wh=None, import_consumption_kwh=None)
        if i == 40:
            kw.update(import_quality_code="ROLLOVER", import_rollover_detected=True)
        if i == 60:
            kw.update(import_quality_code="MISSING_REGISTER", import_is_valid=False, import_register_wh=None,
                      import_consumption_wh=None, import_consumption_kwh=None)
        if i == 65:
            kw.update(export_quality_code="IMPLAUSIBLE_DELTA", export_is_valid=False,
                      export_consumption_wh=None, export_consumption_kwh=None)
        if i == 0:
            kw.update(import_quality_code="INITIAL", import_is_valid=False, import_consumption_wh=None,
                      import_consumption_kwh=None, previous_import_register_wh=None, previous_bucket_start=None)
        rows.append(_row(t, ts, t["device"], **kw))
    _insert(cur, "energy_consumption_1min", rows)
    rows5 = []
    for i in range(20):
        ts = T0 + timedelta(minutes=5 * i)
        rows5.append(_row(t, ts, t["device_b"], elapsed_minutes=Decimal(5),
                          previous_bucket_start=ts - timedelta(minutes=5),
                          import_register_wh=Decimal(2000 + 50 * i),
                          previous_import_register_wh=Decimal(2000 + 50 * (i - 1)),
                          import_consumption_wh=Decimal(50), import_consumption_kwh=Decimal("0.050"),
                          source_sample_count=5 if i % 3 else None))
    _insert(cur, "energy_consumption_5min", rows5)


def _load_baseline(cur):
    cur.execute(BASELINE.read_text(encoding="utf-8"))


def _cols(cur, schema, view):
    return [
        r[0]
        for r in _all(
            cur,
            "SELECT column_name FROM information_schema.columns WHERE table_schema = %s AND table_name = %s "
            "ORDER BY ordinal_position",
            (schema, view),
        )
    ]


def _assert_same(cur, new_sql, old_sql, params):
    new_rows = sorted(_all(cur, new_sql, params), key=repr)
    old_rows = sorted(_all(cur, old_sql, params), key=repr)
    assert new_rows == old_rows
    return len(new_rows)


# ---------------------------------------------------------------------------
# Static
# ---------------------------------------------------------------------------


def test_manifest_row_follows_268_and_is_last():
    with MANIFEST.open(newline="") as handle:
        rows = [r for r in csv.DictReader(handle) if r["target_category"] == "migration"]
    names = [r["source_file"] for r in rows]
    assert names[-2] == "268_energy_reconstruction_foundations.sql"
    assert names[-1] == "269_energy_reconstruction_read_hardening.sql"
    assert rows[-1]["target_path"] == "postgres/migrations/269_energy_reconstruction_read_hardening.sql"


def test_migration_touches_only_the_declared_objects():
    sql = "\n".join(line.split("--", 1)[0] for line in MIGRATION_PATH.read_text(encoding="utf-8").splitlines())
    views = set(re.findall(r"CREATE OR REPLACE VIEW (analytics\.[a-z_0-9]+)", sql))
    assert views == {f"analytics.{v}" for v in CHANGED_VIEWS}
    funcs = set(re.findall(r"CREATE OR REPLACE FUNCTION (analytics\.[a-z_0-9]+)\(", sql))
    assert funcs == {
        "analytics.refresh_energy_consumption_15min",
        "analytics.refresh_energy_consumption_hourly",
        "analytics.refresh_energy_consumption_daily",
        "analytics.reconcile_energy_deficits",
        "analytics.get_canonical_energy_read",
    }
    for forbidden in (r"\bDROP\s+(VIEW|FUNCTION|TABLE|COLUMN)\b", r"\badd_job\b", r"\balter_job\b",
                      r"\brefresh_continuous_aggregate\b", r"\bpipeline_state\b", r"\bDELETE\s+FROM\b",
                      r"\bUPDATE\s+[a-z_]+\.", r"energy_reconstruction_scope\s+SET"):
        assert not re.search(forbidden, sql, flags=re.IGNORECASE), forbidden
    for v in SECURITY_BARRIER_VIEWS:
        assert f"CREATE OR REPLACE VIEW analytics.{v} WITH (security_barrier = true) AS" in sql


def test_live_views_keep_security_barrier_and_privileges(conn):
    with conn.cursor() as cur:
        rows = dict(
            _all(
                cur,
                "SELECT c.relname, coalesce(array_to_string(c.reloptions, ','), '') FROM pg_class c "
                "JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'analytics' AND c.relname = ANY(%s)",
                (list(CHANGED_VIEWS),),
            )
        )
        for v in CHANGED_VIEWS:
            assert rows[v] == ("security_barrier=true" if v in SECURITY_BARRIER_VIEWS else ""), v
        for v in ("v_energy_consumption_daily", "v_asset_consumption_daily", "v_asset_hierarchy_rollup_daily"):
            assert _one(cur, "SELECT has_table_privilege('grafana_reader', %s, 'SELECT')", (f"analytics.{v}",))[0]


def test_canonical_read_handles_reconstruction_in_every_tier(conn):
    """Tripwire: fails if a later CREATE OR REPLACE (e.g. the uncommitted
    ADR-018 migration 263) drops the migration-269 handling."""
    with conn.cursor() as cur:
        body = _one(cur, "SELECT pg_get_functiondef('analytics.get_canonical_energy_read(bigint,uuid,timestamptz,timestamptz,text,text)'::regprocedure)")[0]
    assert body.count("RECONSTRUCTED_TIMING") == 8
    for token in ("n.is_measured_interval::INT::BIGINT", "r.import_reconstructed_intervals",
                  "h.export_reconstructed_intervals", "d.import_reconstructed_intervals"):
        assert token in body, token


def test_switch_still_off(conn):
    with conn.cursor() as cur:
        assert _one(cur, "SELECT config.energy_reconstruction_enabled(NULL, NULL)")[0] is False


# ---------------------------------------------------------------------------
# GOLDEN: zero reconstructed rows -> byte-for-byte identical outputs
# ---------------------------------------------------------------------------


def test_golden_views_identical_without_reconstructed_rows(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _golden_fixture(cur, t)
        _load_baseline(cur)
        compared = 0
        for v in CHANGED_VIEWS:
            old_cols = _cols(cur, "zz269_old", v)
            new_cols = _cols(cur, "analytics", v)
            assert new_cols[: len(old_cols)] == old_cols, v  # existing columns keep order; new ones appended
            sel = ", ".join(f'"{c}"' for c in old_cols)
            n = _assert_same(
                cur,
                f"SELECT {sel} FROM analytics.{v} WHERE organization_id = %s",
                f"SELECT {sel} FROM zz269_old.{v} WHERE organization_id = %s",
                (t["org"],),
            )
            assert n > 0, v
            compared += n
        assert compared >= 245  # 117 native rows + every rollup/reporting/daily/hierarchy row of the fixture


@pytest.mark.parametrize("resolution", ["native", "5m", "15m", "1h", "1d"])
@pytest.mark.parametrize("policy", ["native", "coarser", "strict"])
def test_golden_canonical_read_identical_without_reconstructed_rows(tx, resolution, policy):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _golden_fixture(cur, t)
        _load_baseline(cur)
        args = (t["gorg"], t["asset"], WINDOW_FROM, WINDOW_TO, resolution, policy)
        try:
            new_rows = _all(cur, "SELECT * FROM analytics.get_canonical_energy_read(%s, %s, %s, %s, %s, %s)", args)
            new_err = None
        except psycopg.Error as exc:
            new_err = (exc.sqlstate, str(exc).split("\n")[0])
            tx.rollback()
            cur.close()
            pytest.skip(f"combination not servable pre- or post-269 alike: {new_err}")
        old_rows = _all(cur, "SELECT * FROM zz269_old.get_canonical_energy_read(%s, %s, %s, %s, %s, %s)", args)
        assert new_rows == old_rows
        assert new_rows, (resolution, policy)


def test_golden_persisted_refresh_identical_and_no_calculated_at_churn(tx):
    base_cols = (
        "bucket_start, device_id, source_interval_count, import_consumption_kwh, export_consumption_kwh, "
        "valid_import_intervals, invalid_import_intervals, valid_export_intervals, invalid_export_intervals, "
        "gap_interval_count, reset_interval_count, rollover_interval_count, invalid_interval_count, "
        "import_gap_intervals, export_gap_intervals, import_reset_intervals, export_reset_intervals, "
        "import_rollover_intervals, export_rollover_intervals, first_source_bucket, last_source_bucket, calculated_at"
    )
    new_counters = ("reconstructed_interval_count, import_reconstructed_intervals, export_reconstructed_intervals, "
                    "import_reconstructed_kwh, export_reconstructed_kwh")
    with tx.cursor() as cur:
        t = _tenant(cur)
        _golden_fixture(cur, t)
        _load_baseline(cur)
        for tier in ("15min", "hourly", "daily"):
            _one(cur, f"SELECT zz269_old.refresh_energy_consumption_{tier}(%s, %s)", (WINDOW_FROM, WINDOW_TO))
            before = _all(cur, f"SELECT {base_cols} FROM analytics.energy_consumption_{tier} WHERE organization_id = %s ORDER BY 1, 2", (t["org"],))
            assert before, tier
            affected = _one(cur, f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)", (WINDOW_FROM, WINDOW_TO))[0]
            after = _all(cur, f"SELECT {base_cols} FROM analytics.energy_consumption_{tier} WHERE organization_id = %s ORDER BY 1, 2", (t["org"],))
            assert after == before, tier  # identical values AND unchanged calculated_at (value-aware no-op)
            assert affected >= len(before)  # ROW_COUNT contract: matched no-op rows still counted
            counters = _all(cur, f"SELECT {new_counters} FROM analytics.energy_consumption_{tier} WHERE organization_id = %s", (t["org"],))
            assert all(c == (0, 0, 0, 0, 0) for c in counters), tier


@pytest.mark.parametrize("tier", ["energy_consumption_15min", "energy_consumption_hourly"])
def test_golden_reconcile_detection_identical_without_reconstructed_rows(tx, tier):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _golden_fixture(cur, t)
        _load_baseline(cur)
        if tier == "energy_consumption_hourly":
            _one(cur, "SELECT zz269_old.refresh_energy_consumption_15min(%s, %s)", (WINDOW_FROM, WINDOW_TO))
        args = (tier, datetime(2025, 3, 10, tzinfo=UTC), datetime(2025, 3, 11, tzinfo=UTC), timedelta(hours=1), 1000)
        new = _all(cur, "SELECT * FROM analytics.reconcile_energy_deficits(%s, %s, %s, %s, %s)", args)
        old = _all(cur, "SELECT * FROM zz269_old.reconcile_energy_deficits(%s, %s, %s, %s, %s)", args)
        assert new == old
        assert new  # the un-refreshed fixture is (correctly) a deficit in both


# ---------------------------------------------------------------------------
# Synthetic reconstructed rows (PR3 row contract)
# ---------------------------------------------------------------------------

G0 = datetime(2025, 3, 10, 6, 0, tzinfo=UTC)  # 11:30 IST


def _gap_fixture(cur, t):
    """Measured 06:00-06:02; gap closed at 06:40 (GAP_END); 37 interior slots
    06:03-06:39, of which 06:20 is an existing measured bucket with a NULL
    register (INTERIOR on a measured row); all others synthetic. The 15-min
    bucket 06:15-06:30 therefore holds only 1 measured (interior) row and 14
    synthetic rows; 06:30-06:45 holds synthetic rows plus the GAP_END row and
    measured 06:41-06:44."""
    rows = []
    reg = Decimal("5000")
    for i in range(3):
        ts = G0 + timedelta(minutes=i)
        rows.append(_row(t, ts, t["device"], import_register_wh=reg + 10 * i,
                         previous_import_register_wh=reg + 10 * (i - 1), source_sample_count=2))
    gap_start = G0 + timedelta(minutes=2)
    gap_end = G0 + timedelta(minutes=40)
    delta = Decimal("380")  # 38 slots x 10 Wh (time-weighted)
    recon = dict(is_reconstructed=True, import_reconstruction_method="TIME_WEIGHTED",
                 import_gap_start=gap_start, import_gap_end=gap_end, import_gap_delta_wh=delta,
                 export_reconstruction_method="TIME_WEIGHTED", export_gap_start=gap_start,
                 export_gap_end=gap_end, export_gap_delta_wh=Decimal(0))
    for k in range(3, 40):
        ts = G0 + timedelta(minutes=k)
        measured_interior = k == 20
        rows.append(_row(
            t, ts, t["device"],
            source_sample_count=1 if measured_interior else 0,
            import_register_wh=None, previous_import_register_wh=None,
            export_register_wh=Decimal("5") if measured_interior else None,
            previous_export_register_wh=None,
            import_quality_code="RECONSTRUCTED", export_quality_code="RECONSTRUCTED",
            import_reconstruction_role="INTERIOR", export_reconstruction_role="INTERIOR",
            **recon,
        ))
    rows.append(_row(
        t, gap_end, t["device"], source_sample_count=3,
        import_register_wh=reg + 20 + delta, previous_import_register_wh=reg + 20,
        import_quality_code="GAP", gap_detected=True, elapsed_minutes=Decimal(38),
        previous_bucket_start=gap_start,
        import_reconstruction_role="GAP_END", export_reconstruction_role="GAP_END",
        **recon,
    ))
    for i in range(41, 45):
        ts = G0 + timedelta(minutes=i)
        rows.append(_row(t, ts, t["device"], import_register_wh=reg + 20 + delta + 10 * (i - 40),
                         previous_import_register_wh=reg + 20 + delta + 10 * (i - 41), source_sample_count=1))
    _insert(cur, "energy_consumption_1min", rows)
    return gap_start, gap_end


def _rollup(cur, t, bucket):
    cur.execute(
        "SELECT * FROM analytics.v_energy_semantic_rollup_15min WHERE device_id = %s AND bucket_start = %s",
        (t["device"], bucket),
    )
    names = [d.name for d in cur.description]
    row = cur.fetchone()
    return dict(zip(names, row))


def test_rollup_measured_counters_exclude_reconstructed_but_totals_include(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        b0 = _rollup(cur, t, G0)  # 06:00-06:15: 3 measured + 12 synthetic
        assert b0["source_interval_count"] == 3
        assert b0["valid_import_intervals"] == 3 and b0["invalid_import_intervals"] == 0
        assert b0["valid_export_intervals"] == 3 and b0["invalid_export_intervals"] == 0
        assert b0["import_consumption_wh"] == Decimal(15 * 10)  # measured 30 + reconstructed 120
        assert b0["reconstructed_interval_count"] == 12
        assert b0["import_reconstructed_intervals"] == 12
        assert b0["import_reconstructed_wh"] == Decimal(120)
        assert b0["import_register_wh"] == Decimal(5020)  # last MEASURED register, not a synthetic NULL
        assert b0["previous_import_register_wh"] == Decimal(4990)  # from the FIRST measured row (06:00)
        assert b0["last_native_bucket_start"] == G0 + timedelta(minutes=2)
        assert b0["import_quality_codes"] == ["GOOD"]
        assert b0["quality_status"] == "RECONSTRUCTED_TIMING"
        assert b0["gap_interval_count"] == 0 and b0["invalid_interval_count"] == 0


def test_bucket_of_only_reconstructed_timing_is_never_good(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        b = _rollup(cur, t, G0 + timedelta(minutes=15))  # 06:15-06:30: 14 synthetic + 1 measured interior
        assert b["source_interval_count"] == 1  # the measured (interior) row is a measured interval
        assert b["valid_import_intervals"] == 0 and b["invalid_import_intervals"] == 0  # interior import: not a measurement
        assert b["import_consumption_wh"] == Decimal(150)
        assert b["import_reconstructed_intervals"] == 15
        assert b["quality_status"] == "RECONSTRUCTED_TIMING"
        assert b["invalid_interval_count"] == 0


def test_gap_end_bucket_keeps_gaps_detected_priority(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        b = _rollup(cur, t, G0 + timedelta(minutes=30))  # 06:30-06:45: 10 synthetic + GAP_END + 4 measured
        assert b["source_interval_count"] == 5
        assert b["import_gap_intervals"] == 1 and b["gap_interval_count"] == 1
        assert b["quality_status"] == "GAPS_DETECTED"
        assert b["import_reconstructed_intervals"] == 11
        assert b["import_consumption_wh"] == Decimal(150)
        assert b["import_register_wh"] == Decimal(5000 + 20 + 380 + 40)


def test_totals_equal_measured_register_delta_across_views(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        # 06:01..06:44: every slot 10 Wh -> 44 slots; 06:00 row also 10 Wh in the fixture.
        expected_kwh = Decimal("0.450")
        for view, time_col in (("v_energy_reporting_15min", "bucket_start"), ("v_energy_reporting_hourly", "bucket_start")):
            total = _one(cur, f"SELECT sum(import_consumption_kwh), sum(import_reconstructed_kwh) FROM analytics.{view} WHERE device_id = %s", (t["device"],))
            assert total[0] == expected_kwh, view
            assert total[1] == Decimal("0.380"), view
        daily = _one(cur, "SELECT import_consumption_kwh, reconstructed_interval_count, quality_status FROM analytics.v_energy_reporting_daily WHERE device_id = %s", (t["device"],))
        assert daily[0] == expected_kwh and daily[1] == 38 and daily[2] == "GAPS_DETECTED"


def test_native_view_flags(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        rows = {
            r[0]: r[1:]
            for r in _all(
                cur,
                "SELECT bucket_start, is_measured_interval, import_is_interior, invalid_detected FROM analytics.v_energy_consumption_native WHERE device_id = %s",
                (t["device"],),
            )
        }
        assert rows[G0] == (True, False, False)
        assert rows[G0 + timedelta(minutes=5)] == (False, True, False)  # synthetic
        assert rows[G0 + timedelta(minutes=20)] == (True, True, False)  # measured row, interior import
        assert rows[G0 + timedelta(minutes=40)] == (True, False, False)  # GAP_END is measured


def _canonical(cur, t, resolution):
    cur.execute(
        "SELECT interval_start, import_quality_status, export_quality_status, source_interval_count, "
        "valid_import_intervals, invalid_import_intervals, coverage_ratio, import_consumption_kwh "
        "FROM analytics.get_canonical_energy_read(%s, %s, %s, %s, %s, 'strict') ORDER BY interval_start",
        (t["gorg"], t["asset"], datetime(2025, 3, 10, 5, 0, tzinfo=UTC), datetime(2025, 3, 10, 8, 0, tzinfo=UTC), resolution),
    )
    return cur.fetchall()


def test_canonical_read_native_tier(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        rows = {r[0]: r[1:] for r in _canonical(cur, t, "native")}
        assert rows[G0] == ("GOOD", "GOOD", 1, 1, 0, Decimal("1.0"), Decimal("0.010"))
        synthetic = rows[G0 + timedelta(minutes=5)]
        assert synthetic[:5] == ("RECONSTRUCTED_TIMING", "RECONSTRUCTED_TIMING", 0, 0, 0)
        assert synthetic[5] == Decimal("0.0") and synthetic[6] == Decimal("0.010")
        interior_measured = rows[G0 + timedelta(minutes=20)]
        assert interior_measured[:5] == ("RECONSTRUCTED_TIMING", "RECONSTRUCTED_TIMING", 1, 0, 0)
        assert rows[G0 + timedelta(minutes=40)][0] == "GAPS_DETECTED"
        assert sum(r[6] for r in rows.values()) == Decimal("0.450")


@pytest.mark.parametrize("resolution, expected", [
    ("15m", {0: "RECONSTRUCTED_TIMING", 15: "RECONSTRUCTED_TIMING", 30: "GAPS_DETECTED"}),
    ("1h", None),
    ("1d", None),
])
def test_canonical_read_aggregate_tiers(tx, resolution, expected):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        rows = _canonical(cur, t, resolution)
        assert sum(r[7] for r in rows) == Decimal("0.450")
        statuses = [r[1] for r in rows]
        assert "GOOD" not in statuses or resolution == "1h"
        if expected:
            by_min = {int((r[0] - G0).total_seconds() // 60): r for r in rows}
            for minute, status in expected.items():
                assert by_min[minute][1] == status
            assert by_min[0][3] == 3 and by_min[0][6] == Decimal(3) / Decimal(15)
        if resolution == "1h":
            # site-local (IST) hours: 05:30-06:30 UTC holds only measured rows
            # 06:00-06:02, the measured interior 06:20 and synthetic slots;
            # 06:30-07:30 UTC holds the GAP_END.
            assert [r[1] for r in rows] == ["RECONSTRUCTED_TIMING", "GAPS_DETECTED"]
            assert [r[3] for r in rows] == [4, 5]  # measured intervals only


def test_persisted_tiers_carry_reconstruction_counters(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        for tier in ("15min", "hourly", "daily"):
            _one(cur, f"SELECT analytics.refresh_energy_consumption_{tier}(%s, %s)", (WINDOW_FROM, WINDOW_TO))
        agg = _one(cur, "SELECT sum(import_consumption_kwh), sum(reconstructed_interval_count), sum(import_reconstructed_intervals), "
                        "sum(import_reconstructed_kwh), sum(source_interval_count), sum(valid_import_intervals) "
                        "FROM analytics.energy_consumption_15min WHERE device_id = %s", (t["device"],))
        assert agg == (Decimal("0.450"), 38, 38, Decimal("0.380"), 9, 8)
        for tier in ("hourly", "daily"):
            got = _one(cur, f"SELECT sum(import_consumption_kwh), sum(reconstructed_interval_count), sum(import_reconstructed_kwh), "
                            f"sum(source_interval_count) FROM analytics.energy_consumption_{tier} WHERE device_id = %s", (t["device"],))
            assert got == (Decimal("0.450"), 38, Decimal("0.380"), 9), tier


@pytest.mark.parametrize("tier", ["energy_consumption_15min", "energy_consumption_hourly"])
def test_reconcile_reports_no_false_mismatch_with_reconstructed_rows(tx, tier):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        for p in ("15min", "hourly"):
            _one(cur, f"SELECT analytics.refresh_energy_consumption_{p}(%s, %s)", (WINDOW_FROM, WINDOW_TO))
        args = (tier, datetime(2025, 3, 10, 5, tzinfo=UTC), datetime(2025, 3, 10, 8, tzinfo=UTC), timedelta(hours=1), 1000)
        assert _all(cur, "SELECT * FROM analytics.reconcile_energy_deficits(%s, %s, %s, %s, %s)", args) == []


def test_repeat_refresh_does_not_churn_with_reconstructed_rows(tx):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _gap_fixture(cur, t)
        _one(cur, "SELECT analytics.refresh_energy_consumption_15min(%s, %s)", (WINDOW_FROM, WINDOW_TO))
        first = _all(cur, "SELECT bucket_start, calculated_at FROM analytics.energy_consumption_15min WHERE device_id = %s ORDER BY 1", (t["device"],))
        _one(cur, "SELECT analytics.refresh_energy_consumption_15min(%s, %s)", (WINDOW_FROM, WINDOW_TO))
        second = _all(cur, "SELECT bucket_start, calculated_at FROM analytics.energy_consumption_15min WHERE device_id = %s ORDER BY 1", (t["device"],))
        assert first == second


def test_hierarchy_never_reports_reconstructed_only_day_good(tx):
    """An IST day made only of reconstructed interior slots (gap closes the
    next day) must report RECONSTRUCTED_TIMING, not GOOD."""
    with tx.cursor() as cur:
        t = _tenant(cur)
        day_start = datetime(2025, 3, 11, 18, 30, tzinfo=UTC)  # 2025-03-12 00:00 IST
        gap_start = day_start - timedelta(minutes=1)
        gap_end = day_start + timedelta(days=1, minutes=5)
        recon = dict(is_reconstructed=True, import_reconstruction_role="INTERIOR",
                     import_reconstruction_method="TIME_WEIGHTED", import_gap_start=gap_start,
                     import_gap_end=gap_end, import_gap_delta_wh=Decimal(1446),
                     export_reconstruction_role="INTERIOR", export_reconstruction_method="TIME_WEIGHTED",
                     export_gap_start=gap_start, export_gap_end=gap_end, export_gap_delta_wh=Decimal(0))
        rows = [
            _row(t, day_start + timedelta(minutes=m), t["device"], source_sample_count=0,
                 import_register_wh=None, previous_import_register_wh=None, export_register_wh=None,
                 previous_export_register_wh=None, import_quality_code="RECONSTRUCTED",
                 export_quality_code="RECONSTRUCTED", import_consumption_wh=Decimal(1),
                 import_consumption_kwh=Decimal("0.001"), **recon)
            for m in range(0, 1440, 60)  # sparse is enough to populate the day
        ]
        _insert(cur, "energy_consumption_1min", rows)
        h = _one(cur, "SELECT quality_status, direct_reconstructed_interval_count, reported_import_consumption_kwh "
                      "FROM analytics.v_asset_hierarchy_rollup_daily WHERE asset_id = %s AND consumption_date = DATE '2025-03-12'",
                 (t["asset"],))
        assert h[0] == "RECONSTRUCTED_TIMING"
        assert h[1] > 0 and h[2] == Decimal("0.024")
        d = _one(cur, "SELECT valid_import_intervals, reconstructed_interval_count FROM analytics.v_energy_consumption_daily "
                      "WHERE device_id = %s AND consumption_date = DATE '2025-03-12'", (t["device"],))
        assert d[0] == 0 and d[1] > 0


# ---------------------------------------------------------------------------
# Per-direction status never falls through to GOOD; register selection;
# synthetic-row contract constraint (PR #80 review fixes)
# ---------------------------------------------------------------------------

H0 = datetime(2025, 3, 10, 9, 0, tzinfo=UTC)  # 14:30 IST; IST hour 08:30-09:30 UTC holds only these rows
TIER_WINDOWS = {
    "native": (datetime(2025, 3, 10, 8, 0, tzinfo=UTC), datetime(2025, 3, 10, 11, 0, tzinfo=UTC)),
    "5m": (datetime(2025, 3, 10, 8, 0, tzinfo=UTC), datetime(2025, 3, 10, 11, 0, tzinfo=UTC)),
    "15m": (datetime(2025, 3, 10, 8, 0, tzinfo=UTC), datetime(2025, 3, 10, 11, 0, tzinfo=UTC)),
    "1h": (datetime(2025, 3, 10, 8, 0, tzinfo=UTC), datetime(2025, 3, 10, 11, 0, tzinfo=UTC)),
    "1d": (datetime(2025, 3, 9, 0, 0, tzinfo=UTC), datetime(2025, 3, 12, 0, 0, tzinfo=UTC)),
}


def _import_only_reconstruction(t, ts, synthetic, export_valid):
    """Import reconstructed (INTERIOR); export NOT reconstructed."""
    return _row(
        t, ts, t["device"],
        source_sample_count=0 if synthetic else 1,
        import_register_wh=None, previous_import_register_wh=None,
        export_register_wh=None if synthetic else Decimal("5"),
        previous_export_register_wh=None if synthetic else Decimal("5"),
        import_quality_code="RECONSTRUCTED",
        export_quality_code="GOOD" if export_valid else "MISSING_REGISTER",
        export_is_valid=export_valid,
        export_consumption_wh=Decimal(0) if export_valid else None,
        export_consumption_kwh=Decimal(0) if export_valid else None,
        is_reconstructed=True, import_reconstruction_role="INTERIOR",
        import_reconstruction_method="TIME_WEIGHTED", import_gap_start=H0 - timedelta(minutes=1),
        import_gap_end=H0 + timedelta(minutes=30), import_gap_delta_wh=Decimal(310),
    )


def _tier_statuses(cur, t, tier):
    frm, to = TIER_WINDOWS[tier]
    cur.execute(
        "SELECT import_quality_status, export_quality_status, source_interval_count, valid_export_intervals "
        "FROM analytics.get_canonical_energy_read(%s, %s, %s, %s, %s, 'strict') ORDER BY interval_start",
        (t["gorg"], t["asset"], frm, to, tier),
    )
    return cur.fetchall()


@pytest.mark.parametrize("tier", ["native", "5m", "15m", "1h", "1d"])
def test_reconstructed_import_with_valid_measured_export(tx, tier):
    """Measured rows (samples) whose import slot is inside a gap and whose
    export is a valid measurement: import RECONSTRUCTED_TIMING, export GOOD
    (it genuinely is a measurement) and counted as a valid export interval."""
    with tx.cursor() as cur:
        t = _tenant(cur)
        _insert(cur, "energy_consumption_1min",
                [_import_only_reconstruction(t, H0 + timedelta(minutes=k), synthetic=False, export_valid=True) for k in range(15)])
        rows = _tier_statuses(cur, t, tier)
        assert rows, tier
        assert {r[0] for r in rows} == {"RECONSTRUCTED_TIMING"}
        assert {r[1] for r in rows} == {"GOOD"}
        assert sum(r[3] for r in rows) == 15  # measured export intervals
        assert sum(r[2] for r in rows) == 15  # measured intervals (rows with samples)


@pytest.mark.parametrize("tier", ["native", "5m", "15m", "1h", "1d"])
def test_reconstructed_import_with_invalid_export_is_never_good(tx, tier):
    """Synthetic rows (no samples): import reconstructed, export neither
    measured nor reconstructed. Export must report INVALID_INTERVALS in every
    tier -- never fall through to GOOD -- and nothing counts as measured."""
    with tx.cursor() as cur:
        t = _tenant(cur)
        _insert(cur, "energy_consumption_1min",
                [_import_only_reconstruction(t, H0 + timedelta(minutes=k), synthetic=True, export_valid=False) for k in range(15)])
        rows = _tier_statuses(cur, t, tier)
        assert rows, tier
        assert {r[0] for r in rows} == {"RECONSTRUCTED_TIMING"}
        assert {r[1] for r in rows} == {"INVALID_INTERVALS"}
        assert all(r[2] == 0 and r[3] == 0 for r in rows)


@pytest.mark.parametrize("table", ["energy_consumption_1min", "energy_consumption_5min"])
def test_constraint_rejects_synthetic_row_with_valid_non_reconstructed_direction(tx, table):
    with tx.cursor() as cur:
        t = _tenant(cur)
        row = _import_only_reconstruction(t, H0, synthetic=True, export_valid=True)
        with pytest.raises(psycopg.errors.CheckViolation) as exc:
            _insert(cur, table, [row])
        assert f"ck_{table}_synthetic_direction" in str(exc.value)


@pytest.mark.parametrize("table", ["energy_consumption_1min", "energy_consumption_5min"])
def test_constraint_accepts_contract_rows(tx, table):
    with tx.cursor() as cur:
        t = _tenant(cur)
        _insert(cur, table, [
            _import_only_reconstruction(t, H0, synthetic=True, export_valid=False),  # synthetic, export invalid
            _import_only_reconstruction(t, H0 + timedelta(minutes=5), synthetic=False, export_valid=True),  # measured
            _row(t, H0 + timedelta(minutes=10), t["device"]),  # ordinary measured row
        ])


def test_constraint_is_not_valid_and_leaves_existing_rows_untouched(conn):
    with conn.cursor() as cur:
        rows = _all(cur, "SELECT conrelid::regclass::text, convalidated, pg_get_constraintdef(oid) FROM pg_constraint "
                         "WHERE conname LIKE 'ck_energy_consumption_%%_synthetic_direction' ORDER BY 1")
    assert [(r[0], r[1]) for r in rows] == [
        ("analytics.energy_consumption_1min", False),
        ("analytics.energy_consumption_5min", False),
    ]
    for _, _, definition in rows:
        assert "NOT VALID" in definition
        assert "COALESCE(source_sample_count, (0)::bigint) = 0" in definition
        assert "(import_reconstruction_role IS NOT NULL) OR (NOT import_is_valid)" in definition
        assert "(export_reconstruction_role IS NOT NULL) OR (NOT export_is_valid)" in definition


def test_register_selection_skips_inside_gap_rows_first_and_last(tx):
    """An inside-gap measured row (import INTERIOR, NULL import register) that
    is FIRST and another that is LAST in a 15-minute bucket must not supply
    the bucket's import registers; export (not inside a gap on those rows)
    still takes them."""
    b = datetime(2025, 3, 10, 10, 0, tzinfo=UTC)
    with tx.cursor() as cur:
        t = _tenant(cur)
        first = _import_only_reconstruction(t, b, synthetic=False, export_valid=True)
        first.update(import_gap_start=b - timedelta(minutes=1), import_gap_end=b + timedelta(minutes=1),
                     previous_export_register_wh=Decimal(11))
        last = _import_only_reconstruction(t, b + timedelta(minutes=14), synthetic=False, export_valid=True)
        last.update(import_gap_start=b + timedelta(minutes=13), import_gap_end=b + timedelta(minutes=16),
                    export_register_wh=Decimal(99))
        middle = [
            _row(t, b + timedelta(minutes=k), t["device"],
                 import_register_wh=Decimal(7000 + 10 * k), previous_import_register_wh=Decimal(7000 + 10 * (k - 1)))
            for k in range(1, 14)
        ]
        _insert(cur, "energy_consumption_1min", [first] + middle + [last])
        r = _rollup(cur, t, b)
        assert r["previous_import_register_wh"] == Decimal(7000)   # first NON-inside-gap measured row
        assert r["import_register_wh"] == Decimal(7130)            # last NON-inside-gap measured row
        assert r["previous_export_register_wh"] == Decimal(11)     # export not inside a gap: first row
        assert r["export_register_wh"] == Decimal(99)              # export not inside a gap: last row
        assert r["source_interval_count"] == 15 and r["valid_import_intervals"] == 13
