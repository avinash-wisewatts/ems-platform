"""Tests for migration 270: selective device reads in
analytics.get_canonical_energy_read (performance only).

* Static contract checks on the migration file and manifest.
* GOLDEN equality: migration 263's exact function body is recreated as
  zz270_old.get_canonical_energy_read inside a rolled-back transaction and
  compared, on identical data, with the live (migration 270) function in
  every tier and fallback policy -- including a non-minute-aligned p_from,
  missing Import/Export bindings, Import and Export on different devices,
  and source switches inside a bucket (1-minute and 5-minute sources).
* PLAN SHAPE: auto_explain captures the function's nested plans. Every scan
  of analytics.energy_consumption_1min/_5min (or their chunks) carries a
  device_id = ANY(...) predicate, and no aggregate produces more groups
  than the bound devices can -- under
  both custom and generic plans. The same check fails for the migration 263
  body (negative control), so it is sensitive to the regression.

Every write happens inside a transaction that is rolled back.
"""

import csv
import json
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
MIGRATIONS = REPO / "postgres" / "migrations"
MIGRATION_PATH = MIGRATIONS / "270_canonical_energy_read_selective_device_reads.sql"
MIGRATION_263 = MIGRATIONS / "263_asset_energy_consumption_asset_points_attribution.sql"
MANIFEST = REPO / "postgres" / "restructure_manifest.csv"

UTC = timezone.utc
T0 = datetime(2025, 3, 10, 17, 40, tzinfo=UTC)  # crosses UTC 18:00/19:00 and IST midnight (18:30 UTC)
SPAN_MINUTES = 150
TIERS = ("native", "5m", "15m", "1h", "1d")
NOISE_DEVICES = 6

NATIVE_COLUMNS = (
    "bucket_start, organization_id, site_id, device_id, previous_bucket_start, elapsed_minutes, "
    "source_sample_count, import_register_wh, previous_import_register_wh, import_consumption_wh, "
    "import_consumption_kwh, import_quality_code, import_is_valid, import_reset_detected, "
    "import_rollover_detected, export_register_wh, previous_export_register_wh, export_consumption_wh, "
    "export_consumption_kwh, export_quality_code, export_is_valid, export_reset_detected, "
    "export_rollover_detected, gap_detected, calculated_at"
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


def _tenant(cur, n_devices):
    """Org -> site (Asia/Kolkata) -> gateway -> n profiled devices -> asset
    -> Grafana org map -> 60 s capture policy. No asset_points bindings."""
    suffix = f"{random.randrange(10**9):09d}"
    grafana_org_id = 710000 + random.randrange(99999)
    cur.execute("SELECT id FROM config.device_categories WHERE lower(name) = 'energy meter' LIMIT 1")
    category = cur.fetchone()[0]
    cur.execute(
        "INSERT INTO metadata.device_models(vendor, model, device_type, device_category_id) "
        "VALUES ('WiseWatts Test', 'M270 Test Meter', 'Energy Meter', %s) "
        "ON CONFLICT (lower(COALESCE(vendor, '')), lower(model)) DO UPDATE SET device_category_id = EXCLUDED.device_category_id "
        "RETURNING id",
        (category,),
    )
    model = cur.fetchone()[0]
    org = _one(cur, "INSERT INTO metadata.organizations(name, code, timezone) VALUES (%s, %s, 'Asia/Kolkata') RETURNING id",
               (f"M270 Org {suffix}", f"M270_ORG_{suffix}"))[0]
    site = _one(cur, "INSERT INTO metadata.sites(organization_id, name, code, timezone, is_active) "
                     "VALUES (%s, %s, %s, 'Asia/Kolkata', TRUE) RETURNING id",
                (org, f"M270 Site {suffix}", f"M270_SITE_{suffix}"))[0]
    gateway = _one(cur, "INSERT INTO metadata.gateways(organization_id, site_id, name, external_id) "
                        "VALUES (%s, %s, %s, %s) RETURNING id",
                   (org, site, f"M270 GW {suffix}", f"M270-GW-{suffix}"))[0]
    profile = _one(cur, "SELECT id FROM config.device_profiles WHERE profile_code = 'ENERGY_METER_ENISCOPE_V1'")[0]
    devices = []
    for i in range(n_devices):
        devices.append(_one(
            cur,
            "INSERT INTO metadata.devices(organization_id, gateway_id, device_model_id, profile_id, name, external_id) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (org, gateway, model, profile, f"M270 Device {i} {suffix}", f"M270-DEV-{i}-{suffix}"),
        )[0])
    asset = _one(cur, "INSERT INTO metadata.assets(organization_id, site_id, name, external_id, metering_requirement, lifecycle_status) "
                      "VALUES (%s, %s, %s, %s, 'DIRECT_METER_REQUIRED', 'ACTIVE') RETURNING id",
                 (org, site, f"M270 Asset {suffix}", f"M270_ASSET_{suffix}"))[0]
    cur.execute("INSERT INTO metadata.grafana_organization_map(grafana_org_id, organization_id, is_active) VALUES (%s, %s, TRUE)",
                (grafana_org_id, org))
    cur.execute(
        "INSERT INTO config.telemetry_capture_policies(site_id, capture_interval_seconds, alignment_mode, "
        "late_arrival_tolerance_seconds, effective_from, is_enabled) VALUES (%s, 60, 'WALL_CLOCK', 60, %s, TRUE)",
        (site, datetime(2025, 1, 1, tzinfo=UTC)),
    )
    return {"org": org, "site": site, "devices": devices, "asset": asset, "gorg": grafana_org_id}


def _bind(cur, t, device, point, effective_from, effective_to=None):
    cur.execute(
        "INSERT INTO metadata.asset_points(asset_id, device_id, logical_point_id, organization_id, effective_from, effective_to) "
        "SELECT %s, %s, lp.id, %s, %s, %s FROM metadata.logical_points lp WHERE lp.name = %s",
        (t["asset"], device, t["org"], effective_from, effective_to, point),
    )
    assert cur.rowcount == 1


def _row(t, ts, device, step_minutes, seq, device_no):
    """One measured native row; import/export deltas differ per device so a
    wrong attribution changes every total."""
    imp = Decimal(10 + device_no) * step_minutes
    exp = Decimal(device_no) * step_minutes
    kw = {
        "bucket_start": ts, "organization_id": t["org"], "site_id": t["site"], "device_id": device,
        "previous_bucket_start": ts - timedelta(minutes=step_minutes), "elapsed_minutes": Decimal(step_minutes),
        "source_sample_count": 1 if seq % 5 else None,
        "import_register_wh": Decimal(100000) + imp * seq, "previous_import_register_wh": Decimal(100000) + imp * (seq - 1),
        "import_consumption_wh": imp, "import_consumption_kwh": imp / 1000,
        "import_quality_code": "GOOD", "import_is_valid": True, "import_reset_detected": False,
        "import_rollover_detected": False,
        "export_register_wh": Decimal(5000) + exp * seq, "previous_export_register_wh": Decimal(5000) + exp * (seq - 1),
        "export_consumption_wh": exp, "export_consumption_kwh": exp / 1000,
        "export_quality_code": "GOOD", "export_is_valid": True, "export_reset_detected": False,
        "export_rollover_detected": False, "gap_detected": False, "calculated_at": datetime(2025, 3, 20, tzinfo=UTC),
    }
    if seq == 17:
        kw.update(import_quality_code="GAP", gap_detected=True)
    if seq == 23:
        kw.update(import_quality_code="RESET", import_is_valid=False, import_reset_detected=True,
                  import_consumption_wh=None, import_consumption_kwh=None)
    if seq == 29:
        kw.update(export_quality_code="IMPLAUSIBLE_DELTA", export_is_valid=False,
                  export_consumption_wh=None, export_consumption_kwh=None)
    return kw


def _insert(cur, table, rows):
    cols = [c.strip() for c in NATIVE_COLUMNS.split(",")]
    cur.executemany(
        f"INSERT INTO analytics.{table} ({NATIVE_COLUMNS}) VALUES ({', '.join(['%s'] * len(cols))})",
        [tuple(r[c] for c in cols) for r in rows],
    )


def _data(cur, t, five_minute_devices=()):
    """150 minutes of data on every device: 1-minute rows, or 5-minute rows
    for the devices listed in five_minute_devices."""
    for n, device in enumerate(t["devices"]):
        if n in five_minute_devices:
            rows = [_row(t, T0 + timedelta(minutes=5 * i), device, 5, i, n) for i in range(SPAN_MINUTES // 5)]
            _insert(cur, "energy_consumption_5min", rows)
        else:
            rows = [_row(t, T0 + timedelta(minutes=i), device, 1, i, n) for i in range(SPAN_MINUTES)]
            _insert(cur, "energy_consumption_1min", rows)


def _install_263_body(cur):
    """migration 263's exact get_canonical_energy_read, as zz270_old.*."""
    src = MIGRATION_263.read_text(encoding="utf-8").replace("\r", "")
    start = src.index("CREATE OR REPLACE FUNCTION analytics.get_canonical_energy_read(")
    end = src.index("$function$;\n", start) + len("$function$;")
    ddl = src[start:end].replace(
        "CREATE OR REPLACE FUNCTION analytics.get_canonical_energy_read(",
        "CREATE OR REPLACE FUNCTION zz270_old.get_canonical_energy_read(", 1)
    cur.execute("CREATE SCHEMA IF NOT EXISTS zz270_old")
    cur.execute(ddl)


def _read(cur, schema, t, tier, p_from, p_to, policy="native"):
    return _all(
        cur,
        f"SELECT * FROM {schema}.get_canonical_energy_read(%s, %s, %s, %s, %s, %s) ORDER BY interval_start",
        (t["gorg"], t["asset"], p_from, p_to, tier, policy),
    )


P_FROMS = (
    T0 - timedelta(hours=1),                              # aligned, before the data
    T0 + timedelta(minutes=7, seconds=23),                # non-minute-aligned, inside a 5m/15m bucket
    T0 + timedelta(minutes=12, seconds=30),               # non-minute-aligned, inside a 5-minute native bucket
)
P_TO = T0 + timedelta(minutes=SPAN_MINUTES - 13, seconds=17)  # non-aligned end


def _assert_same_everywhere(cur, t, policies=("native",)):
    """New == migration 263 body for every tier, p_from variant and policy.
    Returns the new rows keyed by (tier, p_from)."""
    _install_263_body(cur)
    out = {}
    for policy in policies:
        for tier in TIERS:
            for p_from in P_FROMS:
                new = _read(cur, "analytics", t, tier, p_from, P_TO, policy)
                old = _read(cur, "zz270_old", t, tier, p_from, P_TO, policy)
                assert new == old, (tier, p_from, policy)
                out[(tier, p_from, policy)] = new
    return out


# ---------------------------------------------------------------------------
# Static
# ---------------------------------------------------------------------------


def test_manifest_row_directly_follows_263():
    with MANIFEST.open(newline="") as handle:
        rows = [r for r in csv.DictReader(handle) if r["target_category"] == "migration"]
    names = [r["source_file"] for r in rows]
    idx = names.index(MIGRATION_PATH.name)
    assert names[idx - 1] == MIGRATION_263.name
    assert rows[idx]["target_path"] == f"postgres/migrations/{MIGRATION_PATH.name}"


def test_migration_touches_only_the_canonical_read():
    sql = "\n".join(line.split("--", 1)[0] for line in MIGRATION_PATH.read_text(encoding="utf-8").splitlines())
    assert re.findall(r"CREATE OR REPLACE (\w+) ([a-z_0-9.]+)", sql) == [("FUNCTION", "analytics.get_canonical_energy_read")]
    for forbidden in (r"\bCREATE\s+(UNIQUE\s+)?INDEX\b", r"\bDROP\b", r"\bALTER\b", r"\bGRANT\b", r"\bREVOKE\b",
                      r"\badd_job\b", r"\balter_job\b", r"\bINSERT\s+INTO\b", r"\bDELETE\s+FROM\b",
                      r"\bUPDATE\s+[a-z_]+\.", r"energy_consumption_(15min|hourly|daily)\b"):
        assert not re.search(forbidden, sql, flags=re.IGNORECASE), forbidden


def test_live_body_has_one_device_filter_per_direction_and_tier(conn):
    with conn.cursor() as cur:
        body = _one(cur, "SELECT prosrc FROM pg_proc WHERE oid = "
                         "'analytics.get_canonical_energy_read(bigint, uuid, timestamptz, timestamptz, text, text)'::regprocedure")[0]
    for alias in ("n", "r", "h", "d"):
        assert body.count(f"{alias}.device_id = ANY(v_import_devices)") == 1, alias
        assert body.count(f"{alias}.device_id = ANY(v_export_devices)") == 1, alias
    assert "base AS NOT MATERIALIZED (" in body
    assert body.count("n.bucket_start >= v_effective_from - INTERVAL '5 minutes'") == 2


# ---------------------------------------------------------------------------
# Golden equality with the migration 263 body
# ---------------------------------------------------------------------------


def test_golden_same_device_both_directions_all_policies(tx):
    with tx.cursor() as cur:
        t = _tenant(cur, 1 + NOISE_DEVICES)
        a = t["devices"][0]
        _bind(cur, t, a, "ENERGY_IMPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _bind(cur, t, a, "ENERGY_EXPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _data(cur, t)
        out = _assert_same_everywhere(cur, t, policies=("native", "coarser", "strict"))
        rows = out[("native", P_FROMS[1], "native")]
        assert rows and all(r[5] == a for r in rows)


def test_golden_import_and_export_on_different_devices(tx):
    with tx.cursor() as cur:
        t = _tenant(cur, 2 + NOISE_DEVICES)
        a, b = t["devices"][:2]
        _bind(cur, t, a, "ENERGY_IMPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _bind(cur, t, b, "ENERGY_EXPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _data(cur, t)
        out = _assert_same_everywhere(cur, t)
        rows = out[("native", P_FROMS[0], "native")]
        # export on device 1 is 1 Wh/min, import on device 0 is 10 Wh/min
        assert {r[8] for r in rows if r[8] is not None} == {Decimal("0.001")}
        assert Decimal("0.010") in {r[7] for r in rows}


@pytest.mark.parametrize("bound", ["ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL", None])
def test_golden_missing_bindings(tx, bound):
    with tx.cursor() as cur:
        t = _tenant(cur, 1 + NOISE_DEVICES)
        if bound:
            _bind(cur, t, t["devices"][0], bound, datetime(2025, 1, 1, tzinfo=UTC))
        _data(cur, t)
        out = _assert_same_everywhere(cur, t)
        for tier in TIERS:
            rows = out[(tier, P_FROMS[0], "native")]
            if bound is None:
                assert rows == [], tier
            elif bound == "ENERGY_IMPORT_TOTAL":
                assert rows and all(r[8] is None and r[10] is None for r in rows), tier
            else:
                assert rows and all(r[7] is None and r[9] is None and r[5] is None for r in rows), tier


@pytest.mark.parametrize("switch_both", [True, False])
def test_golden_source_switch_inside_a_bucket(tx, switch_both):
    """Cutover at a non-minute-aligned instant inside a 5m, 15m and 1h
    bucket; the incoming source wins the straddling bucket (migration 263)."""
    cutover = T0 + timedelta(minutes=52, seconds=30)
    with tx.cursor() as cur:
        t = _tenant(cur, 2 + NOISE_DEVICES)
        a, b = t["devices"][:2]
        _bind(cur, t, a, "ENERGY_IMPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC), cutover)
        _bind(cur, t, b, "ENERGY_IMPORT_TOTAL", cutover)
        if switch_both:
            _bind(cur, t, a, "ENERGY_EXPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC), cutover)
            _bind(cur, t, b, "ENERGY_EXPORT_TOTAL", cutover)
        else:
            _bind(cur, t, a, "ENERGY_EXPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _data(cur, t)
        out = _assert_same_everywhere(cur, t)
        by_start = {r[3]: r for r in out[("15m", P_FROMS[0], "native")]}
        straddling = by_start[T0 + timedelta(minutes=50)]
        assert straddling[7] == Decimal("0.165")  # device 1 (11 Wh/min) x 15 -- incoming source wins
        assert straddling[8] == (Decimal("0.015") if switch_both else Decimal("0"))


def test_golden_switch_to_five_minute_source_and_non_aligned_p_from(tx):
    """The native tier's time bound keeps a 5-minute bucket that starts
    before a non-minute-aligned p_from but overlaps it."""
    with tx.cursor() as cur:
        t = _tenant(cur, 2 + NOISE_DEVICES)
        a, c = t["devices"][:2]
        cutover = T0 + timedelta(minutes=47, seconds=10)
        for point in ("ENERGY_IMPORT_TOTAL", "ENERGY_EXPORT_TOTAL"):
            _bind(cur, t, c, point, datetime(2025, 1, 1, tzinfo=UTC), cutover)
            _bind(cur, t, a, point, cutover)
        _data(cur, t, five_minute_devices={1})
        out = _assert_same_everywhere(cur, t)
        native = out[("native", P_FROMS[2], "native")]  # p_from = T0+12:30, inside C's T0+10 bucket
        assert native[0][3] == T0 + timedelta(minutes=10)
        assert native[0][4] == T0 + timedelta(minutes=15)


# ---------------------------------------------------------------------------
# Plan shape (auto_explain on the function's nested statements)
# ---------------------------------------------------------------------------


SOURCE_TABLES = ("analytics.energy_consumption_1min", "analytics.energy_consumption_5min")


def _source_relations(cur):
    names = {t.split(".")[1] for t in SOURCE_TABLES}
    for table in SOURCE_TABLES:
        for (chunk,) in _all(cur, "SELECT c::regclass::text FROM show_chunks(%s::regclass) c", (table,)):
            names.add(chunk.split(".")[-1])
    return names


def _nodes(plan):
    yield plan
    for child in plan.get("Plans", []):
        yield from _nodes(child)


def _captured_plans(cur, notices, schema, t, tier):
    notices.clear()
    _read(cur, schema, t, tier, T0 - timedelta(hours=1), T0 + timedelta(hours=4))
    plans = []
    for msg in notices:
        if "plan:" not in msg:
            continue
        doc = json.loads(msg.split("plan:", 1)[1])
        if "_rows AS" in doc.get("Query Text", ""):
            plans.append(doc["Plan"])
    return plans


def _is_source_scan(node, source_relations):
    """A scan of an energy source hypertable or chunk. The TimescaleDB
    ChunkAppend node on the hypertable carries no predicate of its own; its
    chunk scans do."""
    return (node.get("Relation Name") in source_relations
            and node.get("Custom Plan Provider") != "ChunkAppend")


def _plan_violations(plans, source_relations, max_groups):
    """Scans of energy source relations without a device predicate, and
    aggregates producing more groups than the bound devices can."""
    out = []
    for plan in plans:
        for node in _nodes(plan):
            rows = node.get("Actual Rows", 0) * node.get("Actual Loops", 1)
            if _is_source_scan(node, source_relations):
                # Predicates of the scan and of its own index sub-nodes
                # (Bitmap Index Scan, compressed-chunk index scan).
                preds = " ".join(str(n.get(k, "")) for n in _nodes(node) for k in ("Index Cond", "Filter", "Recheck Cond"))
                if not re.search(r"device_id = ANY", preds):
                    out.append(f"{node['Node Type']} on {node['Relation Name']} without device predicate")
            if node["Node Type"] == "Aggregate" and rows > max_groups:
                out.append(f"{node.get('Strategy')} aggregate produced {rows} groups > {max_groups}")
    return out


@pytest.fixture
def plan_tx(tx):
    notices = []
    tx.add_notice_handler(lambda d: notices.append(d.message_primary))
    with tx.cursor() as cur:
        cur.execute("LOAD 'auto_explain'")
        cur.execute("SET auto_explain.log_min_duration = 0")
        cur.execute("SET auto_explain.log_nested_statements = on")
        cur.execute("SET auto_explain.log_analyze = on")
        cur.execute("SET auto_explain.log_timing = off")
        cur.execute("SET auto_explain.log_format = 'json'")
        cur.execute("SET auto_explain.log_level = 'notice'")
        cur.execute("SET client_min_messages = 'notice'")
        t = _tenant(cur, 2 + NOISE_DEVICES)
        a, b = t["devices"][:2]
        _bind(cur, t, a, "ENERGY_IMPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _bind(cur, t, b, "ENERGY_EXPORT_TOTAL", datetime(2025, 1, 1, tzinfo=UTC))
        _data(cur, t)
        cur.execute("ANALYZE analytics.energy_consumption_1min")
        _install_263_body(cur)
        yield cur, notices, t, _source_relations(cur)


# Upper bound on groups any aggregate may produce when only the two bound
# devices are read: one group per device per 1-minute bucket. Reading the
# six unbound devices too produces up to 4x this.
MAX_GROUPS = 2 * SPAN_MINUTES


@pytest.mark.parametrize("plan_cache_mode", ["force_custom_plan", "force_generic_plan"])
@pytest.mark.parametrize("tier", TIERS)
def test_every_tier_pushes_the_device_predicate_into_the_source_reads(plan_tx, tier, plan_cache_mode):
    cur, notices, t, relations = plan_tx
    cur.execute(f"SET plan_cache_mode = {plan_cache_mode}")
    plans = _captured_plans(cur, notices, "analytics", t, tier)
    assert plans, "auto_explain captured no import_rows/export_rows plan"
    assert any(_is_source_scan(n, relations) for p in plans for n in _nodes(p)), \
        "the captured plan has no scan of an energy source relation"
    assert _plan_violations(plans, relations, MAX_GROUPS) == []


@pytest.mark.parametrize("tier", TIERS)
def test_plan_check_detects_the_migration_263_regression(plan_tx, tier):
    """Negative control: the same check fails for the migration 263 body,
    which restricts devices only through the window join."""
    cur, notices, t, relations = plan_tx
    plans = _captured_plans(cur, notices, "zz270_old", t, tier)
    assert plans
    assert _plan_violations(plans, relations, MAX_GROUPS) != []
