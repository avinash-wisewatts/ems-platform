"""Migration 312 (Reports asset selection and 1-minute read) is registered
once in the migration manifest, after the highest earlier migration (310, or
311 once that is merged)."""

from __future__ import annotations

import csv
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MIGRATION = REPO / "postgres" / "migrations" / "312_report_export_asset_selection_1m.sql"


def test_manifest_registers_312_after_the_previous_migration() -> None:
    rows = list(csv.DictReader((REPO / "postgres" / "restructure_manifest.csv").read_text(encoding="utf-8").splitlines()))
    files = [r["source_file"] for r in rows if r["target_category"] == "migration"]
    assert files.count(MIGRATION.name) == 1
    assert files[files.index(MIGRATION.name) - 1] in (
        "310_preserved_rtdata_backfill.sql",
        "311_recovery_lookup_event_time_bound.sql",
    )


def test_migration_has_no_transaction_control_and_lf_endings() -> None:
    text = MIGRATION.read_bytes()
    assert b"\r\n" not in text
    body = text.decode("utf-8").upper()
    assert "\nBEGIN;" not in body and "\nCOMMIT;" not in body
