"""Migration 297: reconciliation window grain alignment (plan T1.1 / CI-3).

Behavioural coverage (unaligned checkpoints, genuine-gap repair) lives in
scripts/test/assert_analytical_reconciliation.sh section U. These tests pin the
migration file contract, the manifest registration and the installed bodies.
"""

from __future__ import annotations

import csv
import hashlib
import re
from pathlib import Path

import psycopg

from tests.test_asset_energy_tier_read import CONNINFO

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres" / "migrations" / "297_reconcile_window_grain_alignment.sql"

OLD_MD5 = {
    "analytics.reconcile_energy_consumption_15min": "9084fb8ba971bba246699c489df17d85",
    "analytics.reconcile_energy_consumption_daily": "7ba7388b76488536ef41040d5b3f528a",
    "telemetry.reconcile_environment_daily": "35ff7b9caf33aa0362d9096ad6090d98",
}
NEW_MD5 = {
    "analytics.reconcile_energy_consumption_15min": "c0426e6b647e4ebb3b711c171270fe65",
    "analytics.reconcile_energy_consumption_daily": "8789f6eae5b4d92c0a3374629141ae29",
    "telemetry.reconcile_environment_daily": "e71b2511ee69b1a7f273249c31979dbe",
}


def _bodies(sql: str) -> dict[str, str]:
    out = {}
    for name in NEW_MD5:
        start = sql.index(f"CREATE OR REPLACE PROCEDURE {name}(")
        a = sql.index("$procedure$", start) + len("$procedure$")
        b = sql.index("$procedure$", a)
        out[name] = sql[a:b]
    return out


def test_migration_file_is_lf_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    text = raw.decode("utf-8")
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", text, re.MULTILINE)


def test_migration_pins_old_and_new_bodies():
    text = MIGRATION.read_text(encoding="utf-8")
    for name, md5 in OLD_MD5.items():
        assert f"'{md5}'" in text, f"precondition md5 for {name} missing"
    for name, md5 in NEW_MD5.items():
        assert f"'{md5}'" in text, f"postcondition md5 for {name} missing"
    for name, body in _bodies(text).items():
        assert hashlib.md5(body.encode()).hexdigest() == NEW_MD5[name], name


def test_migration_changes_only_the_window_bounds():
    bodies = _bodies(MIGRATION.read_text(encoding="utf-8"))
    b15 = bodies["analytics.reconcile_energy_consumption_15min"]
    assert "v_cp := date_bin(v_coarse, v_cp, TIMESTAMPTZ '2000-01-01 00:00:00+00');" in b15
    assert b15.count("v_ws :=") == 1
    for name in ("analytics.reconcile_energy_consumption_daily", "telemetry.reconcile_environment_daily"):
        body = bodies[name]
        assert body.count("AND d0.local_end_utc   <= v_cp) dy") == 1, name
        assert "FROM days dy\n" not in body, name
        assert body.count("v_ws := v_cp - v_rw;") == 1, name


def test_installed_bodies_owner_and_search_path():
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        for name, md5 in NEW_MD5.items():
            cur.execute(
                """
                SELECT md5(replace(p.prosrc, E'\\r', '')), pg_get_userbyid(p.proowner),
                       p.prosecdef, p.proconfig
                FROM pg_proc p WHERE p.oid = %s::regprocedure
                """,
                (f"{name}(integer,jsonb)",),
            )
            got_md5, owner, secdef, config = cur.fetchone()
            assert got_md5 == md5, name
            assert owner == "ems_admin", name
            assert secdef is True, name
            assert config and config[0].startswith("search_path=pg_catalog"), name


def test_manifest_registers_migration_297():
    manifest = ROOT / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    row = rows[files.index("297_reconcile_window_grain_alignment.sql")]
    assert row["target_path"] == "postgres/migrations/297_reconcile_window_grain_alignment.sql"
    assert files.index("297_reconcile_window_grain_alignment.sql") > files.index("295_standin_energy_assignment_narrowing.sql")
