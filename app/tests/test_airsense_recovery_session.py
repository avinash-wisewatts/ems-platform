"""scripts/maintenance/airsense_recovery_session.sql is migration 310 as
session-only objects: identical bodies apart from the documented renames, and
identical results on the same packets.
"""

from __future__ import annotations

import importlib.util
import re
from datetime import timedelta
from pathlib import Path

import psycopg

from tests.test_asset_energy_tier_read import CONNINFO
from tests.test_preserved_rtdata_backfill import BASE, FROM, TO, Site, airsense

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "310_preserved_rtdata_backfill.sql"
SESSION = REPO / "scripts" / "maintenance" / "airsense_recovery_session.sql"
GENERATOR = REPO / "scripts" / "maintenance" / "generate_airsense_recovery_session.py"
NAMES = ("preserved_rtdata_packets", "preserved_rtdata_samples", "preserved_rtdata_points", "backfill_preserved_rtdata")


def _generator():
    spec = importlib.util.spec_from_file_location("generate_airsense_recovery_session", GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _function(sql: str, schema: str, name: str) -> str:
    m = re.search(rf"^CREATE FUNCTION {schema}\.{name}\n.*?^\$function\$;\n", sql, re.S | re.M)
    assert m, f"{schema}.{name} not found"
    return m.group(0)


# ---------------------------------------------------------------------------
# Identity (text)
# ---------------------------------------------------------------------------


def test_committed_session_script_is_the_generator_output():
    assert SESSION.read_bytes() == _generator().render().encode("utf-8")
    assert b"\r\n" not in SESSION.read_bytes()


def test_function_bodies_match_migration_310_except_the_documented_renames():
    migration = MIGRATION.read_text(encoding="utf-8")
    session = SESSION.read_text(encoding="utf-8")
    for name in NAMES[1:]:
        source = _function(migration, "telemetry", name)
        expected = source
        for n in NAMES:
            expected = re.sub(rf"\btelemetry\.{n}\b", f"pg_temp.{n}", expected)
        # The advisory-lock key is the one documented exception: it is kept.
        expected = expected.replace("hashtext('pg_temp.backfill_preserved_rtdata')", "hashtext('telemetry.backfill_preserved_rtdata')")
        assert _function(session, "pg_temp", name) == expected


def test_packet_table_and_preconditions_are_verbatim():
    migration = MIGRATION.read_text(encoding="utf-8")
    session = SESSION.read_text(encoding="utf-8")
    table = re.search(r"^CREATE TABLE telemetry\.preserved_rtdata_packets\n.*?^\);\n", migration, re.S | re.M).group(0)
    assert table.replace("CREATE TABLE telemetry.", "CREATE TEMP TABLE pg_temp.", 1) in session
    pre = re.search(r"^DO \$\$\n.*?^END \$\$;\n", migration, re.S | re.M).group(0)
    assert pre in session


def test_session_script_creates_nothing_persistent():
    session = SESSION.read_text(encoding="utf-8")
    body = "\n".join(line for line in session.splitlines() if not line.lstrip().startswith("--"))
    for created in re.findall(r"CREATE\s+(?:TEMP\s+TABLE|FUNCTION|TABLE|VIEW|INDEX|PROCEDURE)\s+([\w.]+)", body):
        assert created.startswith("pg_temp."), created
    for statement in ("ALTER ", "GRANT ", "REVOKE ", "COMMENT ON", "DROP FUNCTION", "BEGIN;", "COMMIT;"):
        assert statement not in body, statement
    assert "hashtext('telemetry.backfill_preserved_rtdata')" in body


# ---------------------------------------------------------------------------
# Parity (database): same packets -> same plan, same dry run, same writes
# ---------------------------------------------------------------------------


def _rows(cur, sql, args=()):
    cur.execute(sql, args)
    return sorted(cur.fetchall(), key=repr)


def test_session_functions_return_exactly_what_migration_310_returns():
    with psycopg.connect(CONNINFO) as conn:
        cur = conn.cursor()
        cur.execute(SESSION.read_text(encoding="utf-8"))
        site = Site(cur)
        z1, u1 = site.device("Zone1")
        lobby, ul = site.device("Lobby")
        devices = [z1, lobby]
        packets = [
            (BASE + timedelta(seconds=36), [airsense(u1, BASE + timedelta(seconds=4)), airsense(ul, BASE + timedelta(seconds=5))]),
            (BASE + timedelta(seconds=50), [airsense(u1, BASE + timedelta(seconds=40), t1=21.0)]),               # same bucket, later
            (BASE + timedelta(minutes=5, seconds=36), [airsense(ul, BASE - timedelta(minutes=40))]),            # late
            (BASE + timedelta(minutes=10, seconds=36), [airsense(u1, BASE + timedelta(minutes=10), drop=("LL",))]),
        ]
        for i, (received, elements) in enumerate(packets):
            site.packet(received, elements, message_id=900_000 + i)
        cur.execute(
            "INSERT INTO pg_temp.preserved_rtdata_packets (raw_received_at, raw_message_id, source_identifier, payload, source_file) "
            "SELECT raw_received_at, raw_message_id, source_identifier, payload, source_file FROM telemetry.preserved_rtdata_packets "
            "WHERE source_file = 'test.csv.gz' AND raw_message_id >= 900000 AND raw_message_id < 900010"
        )
        args = (FROM, TO, devices)
        assert _rows(cur, "SELECT * FROM pg_temp.preserved_rtdata_samples(%s, %s, %s::uuid[])", args) == \
               _rows(cur, "SELECT * FROM telemetry.preserved_rtdata_samples(%s, %s, %s::uuid[])", args)
        assert _rows(cur, "SELECT * FROM pg_temp.preserved_rtdata_points(%s, %s, %s::uuid[])", args) == \
               _rows(cur, "SELECT * FROM telemetry.preserved_rtdata_points(%s, %s, %s::uuid[])", args)
        dry = "SELECT * FROM {}.backfill_preserved_rtdata('op@test', %s, %s, %s::uuid[])"
        session_plan = _rows(cur, dry.format("pg_temp"), args)
        assert session_plan == _rows(cur, dry.format("telemetry"), args)
        confirm = sum(r[10] for r in session_plan)

        # Execute through the session copy, snapshot, roll back, execute through 310: same rows.
        def snapshot():
            return (
                _rows(cur, "SELECT event_time, device_id, logical_point_id, raw_value, numeric_value, quality_code, platform_received_at, raw_message_id "
                           "FROM telemetry.normalized_points WHERE device_id = ANY(%s::uuid[]) AND event_time >= %s AND event_time < %s", (devices, FROM, TO)),
                _rows(cur, "SELECT site_id, bucket_start, device_id, event_time, raw_message_id, status FROM telemetry.capture_bucket_samples WHERE device_id = ANY(%s::uuid[])", (devices,)),
                _rows(cur, "SELECT raw_received_at, raw_message_id, device_id, event_time FROM telemetry.routing_recovery_queue WHERE device_id = ANY(%s::uuid[])", (devices,)),
            )

        cur.execute("SAVEPOINT s")
        via_session = _rows(cur, "SELECT device_id, points_inserted FROM pg_temp.backfill_preserved_rtdata('op@test', %s, %s, %s::uuid[], false, %s)", (*args, confirm))
        session_rows = snapshot()
        cur.execute("ROLLBACK TO SAVEPOINT s")
        via_migration = _rows(cur, "SELECT device_id, points_inserted FROM telemetry.backfill_preserved_rtdata('op@test', %s, %s, %s::uuid[], false, %s)", (*args, confirm))
        assert via_session == via_migration and sum(r[1] for r in via_session) == confirm > 0
        assert snapshot() == session_rows
        conn.rollback()


def test_session_objects_do_not_outlive_the_session():
    with psycopg.connect(CONNINFO) as conn:
        conn.execute(SESSION.read_text(encoding="utf-8"))
        conn.commit()
        assert conn.execute("SELECT to_regprocedure('pg_temp.backfill_preserved_rtdata(text,timestamptz,timestamptz,uuid[],boolean,integer)') IS NOT NULL").fetchone()[0]
    with psycopg.connect(CONNINFO) as other:
        found = other.execute(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
            "WHERE n.nspname LIKE 'pg_temp%%' AND p.proname = ANY(%s)", (list(NAMES[1:]),)
        ).fetchone()[0]
        assert found == 0
