"""Migration 311: telemetry.recover_failed_raw_messages() bounds its two
normalized_points lookups by the candidate's own event-time span.

The body is migration 305's verbatim plus the migration-311 fragments only, and
with the bounds passed as parameters (as plpgsql passes them) TimescaleDB
excludes the out-of-window chunks at executor startup instead of scanning every
chunk. End-to-end recovery behaviour is covered, unchanged, by
test_routing_recovery_queue.py (quarantine -> recovery -> queue -> sweep).
"""

from __future__ import annotations

import difflib
import re
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO, Tenant

REPO = Path(__file__).resolve().parents[2]
M305 = REPO / "postgres" / "migrations" / "305_routing_recovery_queue.sql"
M311 = REPO / "postgres" / "migrations" / "311_recovery_lookup_event_time_bound.sql"
SIG = "telemetry.recover_failed_raw_messages(integer)"
BODY_MD5 = "31f4db2fbe27b6b072c0aa17bf5660d9"
BOUND = "np.event_time>=v_event_min-INTERVAL '1 day' AND np.event_time<v_event_max+INTERVAL '1 day'"


def _body(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    m = re.search(r"CREATE OR REPLACE PROCEDURE telemetry\.recover_failed_raw_messages\(IN p_limit integer DEFAULT 100\)\n.*?AS \$procedure\$(.*?)\$procedure\$;", text, re.S)
    assert m, path.name
    return m.group(1)


@pytest.fixture
def tx():
    with psycopg.connect(CONNINFO) as connection:
        yield connection
        connection.rollback()


def test_deployed_body_is_the_migration_311_body(tx):
    md5, src = tx.execute("SELECT md5(replace(prosrc, E'\\r', '')), prosrc FROM pg_proc WHERE oid = %s::regprocedure", (SIG,)).fetchone()
    assert md5 == BODY_MD5
    assert src.replace("\r", "") == _body(M311)
    assert src.count("-- migration 311") == 4
    assert src.count(BOUND) == 2


def test_migration_311_only_adds_to_the_migration_305_body():
    old = _body(M305).splitlines()
    new = _body(M311).splitlines()
    diff = [d for d in difflib.ndiff(old, new) if d[:2] in ("- ", "+ ")]
    removed = [d for d in diff if d.startswith("- ")]
    added = [d[2:] for d in diff if d.startswith("+ ")]
    assert removed == []
    # Two declarations, the per-candidate span (comment + SELECT + COALESCEs + blank), two bounds.
    assert sum("-- migration 311" in a for a in added) == 4
    assert sum(BOUND in a for a in added) == 2
    assert any("INTO v_event_min, v_event_max" in a for a in added)
    assert any("v_event_min:=COALESCE(v_event_min,f.raw_received_at);" in a for a in added)
    assert any("WHERE rm.received_at=f.raw_received_at AND rm.id=f.raw_message_id" in a for a in added)
    assert "telemetry.normalized_points" not in "\n".join(added)   # no new normalized_points access


def test_bounded_lookup_excludes_out_of_window_chunks_with_parameters(tx):
    from tests.test_analytics_point_series_read import seed_raw

    t = Tenant(tx.cursor())
    device = t.device("Bound Meter")
    point = tx.execute("SELECT id FROM metadata.logical_points WHERE name = 'ACTIVE_POWER_TOTAL'").fetchone()[0]
    now = datetime.now(timezone.utc).replace(microsecond=0)
    recent = now - timedelta(hours=3)
    old = now - timedelta(days=60)            # a different (weekly) chunk
    seed_raw(t, device, point, recent, 10)
    seed_raw(t, device, point, old, 10)
    chunks = tx.execute(
        "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_schema = 'telemetry' AND hypertable_name = 'normalized_points'"
    ).fetchone()[0]
    assert chunks >= 2

    # Client-side binding: PREPARE's $n placeholders must reach the server as
    # SQL text, not as parameters of the outer statement.
    cc = psycopg.ClientCursor(tx)
    cc.execute("SET LOCAL plan_cache_mode = force_generic_plan")
    cc.execute(
        "PREPARE p311(uuid, timestamptz, timestamptz, timestamptz) AS "
        "SELECT 1 FROM telemetry.normalized_points np "
        "WHERE np.device_id = $1 AND np.event_time = $2 "
        "AND np.event_time >= $3 - INTERVAL '1 day' AND np.event_time < $4 + INTERVAL '1 day'"
    )
    cc.execute("EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) EXECUTE p311(%s, %s, %s, %s)", (device, recent, recent, recent))
    plan = "\n".join(r[0] for r in cc.fetchall())
    excluded = re.search(r"Chunks excluded during startup: (\d+)", plan)
    assert excluded and int(excluded.group(1)) >= 1, plan
    assert int(excluded.group(1)) >= chunks - 2, plan
    cc.execute("EXECUTE p311(%s, %s, %s, %s)", (device, recent, recent, recent))
    assert cc.fetchone() == (1,)
    cc.execute("EXECUTE p311(%s, %s, %s, %s)", (device, old, recent, recent))
    assert cc.fetchone() is None                     # outside the bound: not found
    cc.execute("DEALLOCATE p311")


def test_manifest_registers_311_after_310_with_lf_and_no_transaction_control():
    import csv

    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    assert files.count(M311.name) == 1
    assert files[files.index(M311.name) - 1] == "310_preserved_rtdata_backfill.sql"
    raw = M311.read_bytes()
    assert b"\r\n" not in raw
    assert "\nBEGIN;" not in raw.decode("utf-8").upper() and "\nCOMMIT;\n" not in raw.decode("utf-8").split("$procedure$")[0].upper()


ROLLBACK_311 = REPO / "postgres" / "maintenance" / "311_recovery_lookup_event_time_bound_rollback.sql"


def _script_body(path):
    text = path.read_text(encoding="utf-8")
    assert text.count("\nBEGIN;\n") == 1 and text.rstrip().endswith("COMMIT;")
    return text.split("\nBEGIN;\n", 1)[1].rsplit("COMMIT;", 1)[0]


def test_rollback_restores_the_migration_305_body_and_then_refuses(tx):
    tx.execute(_script_body(ROLLBACK_311))
    md5 = tx.execute("SELECT md5(replace(prosrc, E'\\r', '')) FROM pg_proc WHERE oid = %s::regprocedure", (SIG,)).fetchone()[0]
    assert md5 == "76e7c9e2140fe46a3012e7f654a80294"
    with pytest.raises(psycopg.errors.RaiseException, match="311 rollback refused"):
        with tx.transaction():
            tx.execute(_script_body(ROLLBACK_311))


def test_rollback_restores_exactly_the_body_in_migration_305():
    assert _body(ROLLBACK_311) == _body(M305)
    assert b"\r" not in ROLLBACK_311.read_bytes()   # the guards use the E'\r' escape, not a raw CR
