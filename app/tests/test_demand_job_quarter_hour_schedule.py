"""Migration 298: demand forward job every 15 minutes at quarter-hour + 7 min
(plan T1.3c-1).

Schedule only. These tests pin the migration file contract (only alter_job on
the demand job's schedule; no procedure, config, schema or other-job change),
the manifest registration, and the installed job. Behaviour under the new
schedule (grid alignment, catch-up after missed slots, duplicate runs, retry
after a failure, preserved settings) is covered against a database by
scripts/test/assert_demand_job_quarter_hour_schedule.sh; finalization itself
is unchanged and stays covered by assert_demand_watermark_refinalization.sh.
"""

from __future__ import annotations

import csv
import re
from datetime import timedelta
from pathlib import Path

import psycopg

from tests.test_asset_energy_tier_read import CONNINFO

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres" / "migrations" / "298_demand_job_quarter_hour_schedule.sql"


def _code(text: str) -> str:
    """The migration without its comments."""
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))


def test_migration_file_is_lf_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    text = raw.decode("utf-8")
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", text, re.MULTILINE)


def test_migration_changes_only_the_demand_job_schedule():
    code = _code(MIGRATION.read_text(encoding="utf-8"))
    # No DDL, no data change, no procedure or function body.
    assert not re.search(
        r"\b(CREATE|DROP|TRUNCATE|GRANT|REVOKE)\b|\bALTER\s+(TABLE|PROCEDURE|FUNCTION|VIEW)\b"
        r"|\b(INSERT\s+INTO|DELETE\s+FROM)\b|\bUPDATE\s+\w",
        code,
        re.IGNORECASE,
    )
    assert "add_job" not in code and "delete_job" not in code
    # Exactly one alter_job, on the job looked up by its procedure, and it
    # passes only schedule arguments.
    assert code.count("alter_job(") == 1
    call = code[code.index("alter_job(") : code.index(");", code.index("alter_job("))]
    args = re.findall(r"(\w+)\s*=>", call)
    assert args == ["schedule_interval", "fixed_schedule", "initial_start", "next_start"]
    assert code.count("proc_name = 'run_demand_calculation_job'") >= 2
    assert "INTERVAL '15 minutes'" in code
    assert "INTERVAL '7 minutes'" in code


def test_migration_postcondition_requires_every_other_job_setting_unchanged():
    code = _code(MIGRATION.read_text(encoding="utf-8"))
    assert "IS DISTINCT FROM" in code
    for field in ("scheduled", "max_runtime", "max_retries", "retry_period", "config", "check_schema", "check_name"):
        assert f"r.{field}" in code and f"b.{field}" in code, field
    assert "% 900) <> 420" in code


def test_manifest_registers_migration_298():
    manifest = ROOT / "postgres" / "restructure_manifest.csv"
    rows = [r for r in csv.DictReader(manifest.read_text(encoding="utf-8").splitlines()) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    row = rows[files.index("298_demand_job_quarter_hour_schedule.sql")]
    assert row["target_path"] == "postgres/migrations/298_demand_job_quarter_hour_schedule.sql"
    assert files.index("298_demand_job_quarter_hour_schedule.sql") > files.index("297_reconcile_window_grain_alignment.sql")


def test_installed_demand_job_runs_every_15_minutes_at_quarter_hour_plus_7():
    with psycopg.connect(CONNINFO) as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT j.schedule_interval, j.fixed_schedule,
                   extract(epoch FROM j.initial_start)::bigint % 900,
                   j.max_runtime, j.max_retries, j.retry_period,
                   j.config ->> 'max_catchup_window', j.config ->> 'overlap', j.config ->> 'lookback',
                   j.check_schema || '.' || j.check_name
            FROM timescaledb_information.jobs AS j
            WHERE j.proc_schema = 'analytics' AND j.proc_name = 'run_demand_calculation_job'
            """
        )
        rows = cur.fetchall()
    assert len(rows) == 1
    (every, fixed, phase_s, max_runtime, max_retries, retry_period, catchup, overlap, lookback, check) = rows[0]
    assert every == timedelta(minutes=15)
    assert fixed is True
    assert phase_s == 420
    # Unchanged by 298.
    assert max_runtime == timedelta(minutes=10)
    assert max_retries == 3
    assert retry_period == timedelta(minutes=5)
    assert (catchup, overlap, lookback) == ("6 hours", "30 minutes", "3 hours")
    assert check == "config.assert_analytical_lookback_job_config"
