"""Migration 310 (preserved packet backfill) is registered once in the
migration manifest, directly after 309."""

from __future__ import annotations

import csv
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "310_preserved_rtdata_backfill.sql"


def test_manifest_registers_310_after_309() -> None:
    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    assert files.count(MIGRATION.name) == 1
    assert files[files.index(MIGRATION.name) - 1] == "309_report_export_jobs.sql"


def test_migration_has_no_transaction_control_and_lf_endings() -> None:
    text = MIGRATION.read_bytes()
    assert b"\r\n" not in text
    body = text.decode("utf-8").upper()
    assert "\nBEGIN;" not in body and "\nCOMMIT;" not in body
