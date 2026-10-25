"""scripts/release/check_pending_migrations.sh: the release precheck that
refuses a deploy unless the target runner would apply exactly the declared
migrations and nothing scoped away from the environment.

Pure file inputs: no database. The real repository manifest and scope file are
used where it matters (309 / 310 / 312 staging-only; 311 the next production
migration after 308).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "release" / "check_pending_migrations.sh"
MANIFEST = REPO / "postgres" / "restructure_manifest.csv"
SCOPE = REPO / "postgres" / "migration_environment_scope.csv"


def _ids_through(last: str) -> list[str]:
    ids = []
    for line in MANIFEST.read_text(encoding="utf-8").splitlines()[1:]:
        source_file, category = line.split(",")[:2]
        if category == "migration":
            ids.append(source_file[: -len(".sql")])
            if source_file.startswith(last):
                break
    return ids


def _run(tmp_path, *, environment="production", manifest=MANIFEST, scope=SCOPE, scope_aware="yes",
         deny=SCOPE, ledger_ids=(), expected="311"):
    ledger = tmp_path / "ledger.txt"
    ledger.write_text("\n".join(ledger_ids) + "\n", encoding="utf-8")
    result = subprocess.run(
        ["bash", str(SCRIPT), "--environment", environment, "--manifest", str(manifest),
         "--scope", str(scope), "--scope-aware", scope_aware, "--deny-scope", str(deny),
         "--ledger", str(ledger), "--expected", expected],
        capture_output=True, text=True, timeout=60,
    )
    return result.returncode, result.stdout + result.stderr


PRODUCTION_LEDGER = _ids_through("308_")          # production today: head 308


def test_production_today_applies_exactly_311(tmp_path):
    code, out = _run(tmp_path, ledger_ids=PRODUCTION_LEDGER)
    assert code == 0, out
    assert "Would apply (1): 311_recovery_lookup_event_time_bound" in out


def test_an_undeclared_pending_migration_is_refused(tmp_path):
    code, out = _run(tmp_path, ledger_ids=PRODUCTION_LEDGER, expected="none")
    assert code == 1 and "311_recovery_lookup_event_time_bound would be applied but was not declared" in out


def test_a_declared_but_absent_migration_is_refused(tmp_path):
    code, out = _run(tmp_path, ledger_ids=PRODUCTION_LEDGER, expected="311,313")
    assert code == 1 and "declared '313' matches 0 pending" in out


def test_declaring_a_staging_only_migration_does_not_make_it_deployable(tmp_path):
    code, out = _run(tmp_path, ledger_ids=PRODUCTION_LEDGER, expected="309,311")
    assert code == 1 and "declared '309' matches 0 pending" in out


def test_rollback_to_a_scope_unaware_runner_with_staging_only_rows_is_refused(tmp_path):
    # An old commit: same manifest rows 309 / 310 / 312 pending, but its runner
    # ignores the scope file (and has none). The staging-HEAD scope denies them.
    code, out = _run(tmp_path, scope="none", scope_aware="no", ledger_ids=PRODUCTION_LEDGER,
                     expected="309,310,312,311")
    assert code == 1
    for staging_only in ("309_report_export_jobs", "310_preserved_rtdata_backfill",
                         "312_report_export_asset_selection_1m"):
        assert f"REFUSED: {staging_only} is scoped away from production" in out


def test_rollback_to_an_older_production_commit_with_nothing_pending_is_allowed(tmp_path):
    manifest = tmp_path / "manifest_308.csv"
    lines = MANIFEST.read_text(encoding="utf-8").splitlines()
    keep = [lines[0]] + [l for l in lines[1:] if l.split(",")[1] != "migration" or l.split(",")[0][:-4] in PRODUCTION_LEDGER]
    manifest.write_text("\n".join(keep) + "\n", encoding="utf-8")
    code, out = _run(tmp_path, manifest=manifest, scope="none", scope_aware="no",
                     ledger_ids=PRODUCTION_LEDGER, expected="none")
    assert code == 0, out


def test_a_staging_only_migration_already_in_the_production_ledger_is_refused_up_front(tmp_path):
    # The scope-aware runner would stop at 309 in manifest order, after
    # applying anything pending before it; the precheck refuses first.
    code, out = _run(tmp_path, ledger_ids=PRODUCTION_LEDGER + ["309_report_export_jobs"])
    assert code == 1
    assert "REFUSED: 309_report_export_jobs is scoped away from production but is already recorded in its ledger." in out


def test_staging_applies_staging_only_migrations(tmp_path):
    code, out = _run(tmp_path, environment="staging", ledger_ids=_ids_through("308_"),
                     expected="309,310,312,311")
    assert code == 0, out


@pytest.mark.parametrize("args", [
    ["--environment", "test"],
    ["--scope-aware", "maybe"],
])
def test_usage_errors_exit_2(tmp_path, args):
    ledger = tmp_path / "ledger.txt"
    ledger.write_text("", encoding="utf-8")
    base = {"--environment": "production", "--manifest": str(MANIFEST), "--scope": str(SCOPE),
            "--scope-aware": "yes", "--deny-scope": str(SCOPE), "--ledger": str(ledger), "--expected": "none"}
    base[args[0]] = args[1]
    argv = [x for kv in base.items() for x in kv]
    assert subprocess.run(["bash", str(SCRIPT), *argv], capture_output=True, timeout=60).returncode == 2


def test_scope_file_contract():
    rows = [l.split(",", 2) for l in SCOPE.read_text(encoding="utf-8").splitlines()[1:] if l]
    scoped = {r[0]: r[1] for r in rows}
    assert scoped == {
        "309_report_export_jobs": "staging|test",
        "310_preserved_rtdata_backfill": "staging|test",
        "312_report_export_asset_selection_1m": "staging|test",
    }
    manifest_ids = set(_ids_through("~never~"))
    assert set(scoped) <= manifest_ids
    assert b"\r" not in SCOPE.read_bytes()


def test_scope_objects_are_created_by_their_migrations():
    objects = REPO / "postgres" / "migration_environment_scope_objects.csv"
    scoped = {l.split(",")[0] for l in SCOPE.read_text(encoding="utf-8").splitlines()[1:] if l}
    listed = set()
    for line in objects.read_text(encoding="utf-8").splitlines()[1:]:
        migration_id, object_type, name = line.split(",")
        assert migration_id in scoped
        listed.add(migration_id)
        sql = (REPO / "postgres" / "migrations" / f"{migration_id}.sql").read_text(encoding="utf-8").lower()
        keyword = "table" if object_type == "table" else "function"
        assert f"{keyword} {name}" in sql.replace("if not exists ", "").replace("or replace ", ""), name
    assert listed == scoped
