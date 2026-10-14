"""Migration 301: device_telemetry_state upserts lock rows in device_id order
in both writers (job 1000 vs job 1060 deadlock fix).

These tests pin the migration file contract: it re-issues exactly the two
loader procedures, each body identical to its previous definition (migration
221 / 007) except one ORDER BY line before the device_telemetry_state
ON CONFLICT, and it changes no job, schema or data. Lock-order behaviour,
the deadlock reproduction and the fixed pair run against a database in
scripts/test/assert_device_telemetry_state_upsert_lock_order.sh.
"""

from __future__ import annotations

import csv
import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "postgres" / "migrations"
MIGRATION = MIGRATIONS / "301_device_telemetry_state_upsert_lock_order.sql"

NORMALIZED = "telemetry.load_normalized_points_incremental"
RAW_RECEIPT = "telemetry.load_device_raw_receipt_state_incremental"


def _lf(path: Path) -> str:
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def _code(text: str) -> str:
    """The migration without its comments."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))


def _procedure(text: str, name: str) -> str:
    """The CREATE OR REPLACE PROCEDURE statement for name, through its closing $$;."""
    start = text.index(f"CREATE OR REPLACE PROCEDURE {name}\n")
    return text[start : text.index("\n$$;", start) + len("\n$$;")]


def _body(procedure: str) -> str:
    return procedure[procedure.index("AS $$") + len("AS $$") : procedure.rindex("$$;")]


def _md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def test_migration_file_is_lf_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", raw.decode("utf-8"), re.MULTILINE)


def test_migration_redefines_only_the_two_loaders():
    text = _lf(MIGRATION)
    code = _code(text)
    assert re.findall(r"CREATE OR REPLACE (?:PROCEDURE|FUNCTION) (\S+)", code) == [NORMALIZED, RAW_RECEIPT]
    # Outside the two (verbatim) procedure bodies: only the DO pre/postcondition blocks.
    for name in (NORMALIZED, RAW_RECEIPT):
        text = text.replace(_procedure(text, name), "")
    code = _code(text)
    assert not re.search(
        r"\b(DROP|TRUNCATE|GRANT|REVOKE|COMMENT ON)\b|\bALTER\s+(TABLE|PROCEDURE|FUNCTION|VIEW|SYSTEM)\b"
        r"|\bCREATE\s+(TABLE|INDEX|VIEW|TRIGGER)\b",
        code,
        re.IGNORECASE,
    )
    for job_call in ("alter_job", "add_job", "delete_job", "set_config", "ALTER ROLE", "ALTER DATABASE"):
        assert job_call not in code


def test_each_body_differs_from_the_previous_definition_only_by_its_order_by_line():
    new = _lf(MIGRATION)
    old_normalized = _procedure(_lf(MIGRATIONS / "221_normalization_selected_elements_pk_join.sql"), NORMALIZED)
    old_raw_receipt = _procedure(_lf(MIGRATIONS / "007_site_frequency_normalization_recovery.sql"), RAW_RECEIPT)

    assert _procedure(new, NORMALIZED) == old_normalized.replace(
        "    GROUP BY b.device_id\n    ON CONFLICT (device_id) DO UPDATE",
        "    GROUP BY b.device_id\n    ORDER BY b.device_id\n    ON CONFLICT (device_id) DO UPDATE",
    )
    assert _procedure(new, RAW_RECEIPT) == old_raw_receipt.replace(
        "    FROM tmp_raw_receipt_batch\n    ON CONFLICT (device_id) DO UPDATE\n    SET latest_received_timestamp",
        "    FROM tmp_raw_receipt_batch\n    ORDER BY device_id\n    ON CONFLICT (device_id) DO UPDATE\n    SET latest_received_timestamp",
    )
    # The device_raw_receipt_state upsert (single writer) is left unordered.
    assert _procedure(new, RAW_RECEIPT).count("ORDER BY device_id\n") == 1


def test_md5_pins_match_the_previous_and_new_bodies():
    new = _lf(MIGRATION)
    old_normalized = _body(_procedure(_lf(MIGRATIONS / "221_normalization_selected_elements_pk_join.sql"), NORMALIZED))
    old_raw_receipt = _body(_procedure(_lf(MIGRATIONS / "007_site_frequency_normalization_recovery.sql"), RAW_RECEIPT))
    new_normalized = _body(_procedure(new, NORMALIZED))
    new_raw_receipt = _body(_procedure(new, RAW_RECEIPT))

    # Live staging and production bodies (2026-10-14) hash to the "old" values.
    assert _md5(old_normalized) == "cb1b3f00129bbc2c6c8e85b06905e540"
    assert _md5(old_raw_receipt) == "e9b3522a2e4189ad8d34eb885b875303"
    assert _md5(new_normalized) == "f1b39ab20a2cd3a4059147d0bb1bef8e"
    assert _md5(new_raw_receipt) == "7e2112edee424957ea00289ce449a622"
    code = _code(new)
    for pin in (_md5(old_normalized), _md5(old_raw_receipt), _md5(new_normalized), _md5(new_raw_receipt)):
        assert pin in code


def test_manifest_registers_migration_301():
    manifest = ROOT / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    row = rows[files.index("301_device_telemetry_state_upsert_lock_order.sql")]
    assert row["target_path"] == "postgres/migrations/301_device_telemetry_state_upsert_lock_order.sql"
    assert files.index("301_device_telemetry_state_upsert_lock_order.sql") > files.index(
        "298_demand_job_quarter_hour_schedule.sql"
    )


def test_lock_order_assertions_run_in_the_integration_suite():
    runner = (ROOT / "scripts" / "test" / "run_integration_environment.sh").read_text(encoding="utf-8")
    assert "assert_device_telemetry_state_upsert_lock_order.sh" in runner
