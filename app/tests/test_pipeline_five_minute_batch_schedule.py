"""Migration 300: coordinated 5-minute batch schedule (contract).

Pins the migration file (schedule-only: alter_job on six jobs, no DDL/DML,
no procedure change), its manifest registration, and the installed schedule:
every target every 5 minutes on a fixed UTC grid at its phase, the stage
ordering the dependencies need, and every job that must stay as it is
(demand 1078, raw receipt state 1076, alerts 1127, the 5-minute tier 1080
and its 15-minute consumer 1099).

Batch equivalence is proven in test_pipeline_five_minute_batch_equivalence.py;
the migration's own postconditions prove no other job setting changed.
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

import psycopg
import pytest

from tests.test_asset_energy_tier_read import CONNINFO

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres" / "migrations" / "300_pipeline_five_minute_batch_schedule.sql"
MANIFEST = ROOT / "postgres" / "restructure_manifest.csv"

# label -> (job predicate, phase seconds after each UTC 5-minute boundary)
TARGETS = {
    "normalization": ("j.proc_schema = 'telemetry' AND j.proc_name = 'run_normalization_job'", 160),
    "energy_routing": ("j.proc_schema = 'telemetry' AND j.proc_name = 'run_energy_routing_job'", 250),
    "environment_routing": ("j.proc_schema = 'telemetry' AND j.proc_name = 'run_environment_routing_job'", 255),
    "ca_energy_1min": ("j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = 'ca_energy_1min'", 280),
    "ca_energy_phase_1min": (
        "j.proc_name = 'policy_refresh_continuous_aggregate' AND j.hypertable_name = 'ca_energy_phase_power_1min'", 285),
    "consumption_1min": ("j.proc_schema = 'analytics' AND j.proc_name = 'run_energy_consumption_1min_job'", 0),
}

# Capture finalization deadline on every active staging site (60 s + 60 s).
CAPTURE_DEADLINE_S = 120
DEMAND_PHASE_S = 420  # migration 298: quarter-hour + 7 min


def _code(text: str) -> str:
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("--"))


@pytest.fixture(scope="module")
def conn():
    with psycopg.connect(CONNINFO, autocommit=True) as c:
        yield c


def _job(conn, predicate):
    rows = conn.execute(
        "SELECT j.job_id, j.schedule_interval, j.fixed_schedule, extract(epoch FROM j.initial_start)::bigint, "
        "j.max_runtime, j.max_retries, j.retry_period "
        f"FROM timescaledb_information.jobs AS j WHERE {predicate}"
    ).fetchall()
    assert len(rows) == 1, f"expected exactly one job for {predicate}, found {len(rows)}"
    return rows[0]


# ---------------------------------------------------------------------------
# Migration file
# ---------------------------------------------------------------------------


def test_migration_file_is_lf_and_has_no_transaction_control():
    raw = MIGRATION.read_bytes()
    assert b"\r" not in raw
    assert not re.search(r"^\s*(BEGIN|COMMIT|ROLLBACK)\s*;", raw.decode("utf-8"), re.MULTILINE)


def test_migration_changes_only_schedules():
    code = _code(MIGRATION.read_text(encoding="utf-8"))
    # Only temp working tables (ON COMMIT DROP); no DDL on real objects, no
    # data change.
    assert not re.search(r"\bDROP\b", code.replace("ON COMMIT DROP", ""), re.IGNORECASE)
    assert not re.search(
        r"\b(TRUNCATE|GRANT|REVOKE)\b|\bALTER\s+(TABLE|PROCEDURE|FUNCTION|VIEW)\b"
        r"|\bDELETE\s+FROM\b|\bCREATE\s+(OR\s+REPLACE\s+)?(FUNCTION|PROCEDURE|VIEW|INDEX)\b",
        code,
        re.IGNORECASE,
    )
    assert re.findall(r"\bCREATE\s+(TEMP\s+)?TABLE\s+(\w+)", code, re.IGNORECASE) == [
        ("TEMP ", "m300_targets"), ("TEMP ", "m300_before")]
    assert re.findall(r"\bINSERT\s+INTO\s+(\w+)", code, re.IGNORECASE) == ["m300_targets"]
    assert re.findall(r"\bUPDATE\s+(\w+)", code, re.IGNORECASE) == ["m300_targets"]
    assert "add_job" not in code and "delete_job" not in code
    assert code.count("alter_job(") == 1
    call = code[code.index("alter_job("): code.index(");", code.index("alter_job("))]
    assert re.findall(r"(\w+)\s*=>", call) == ["schedule_interval", "fixed_schedule", "initial_start", "next_start"]
    for label, (_, phase) in TARGETS.items():
        assert re.search(rf"\('{label}',\s*{phase}\)", code), label


def test_manifest_registers_migration_300_after_299():
    with MANIFEST.open(newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r["target_category"] == "migration"]
    files = [r["source_file"] for r in rows]
    assert files.count(MIGRATION.name) == 1
    assert rows[files.index(MIGRATION.name)]["target_path"] == f"postgres/migrations/{MIGRATION.name}"
    # 300's precondition requires 299's column: 299 must be applied first.
    assert files.index("299_normalized_data_freshness_threshold.sql") < files.index(MIGRATION.name)
    assert files.index("298_demand_job_quarter_hour_schedule.sql") < files.index("299_normalized_data_freshness_threshold.sql")


# ---------------------------------------------------------------------------
# Installed schedule
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("label", list(TARGETS))
def test_target_runs_every_five_minutes_on_its_phase(conn, label):
    predicate, phase = TARGETS[label]
    _, interval, fixed, initial_epoch, *_ = _job(conn, predicate)
    assert str(interval) == "0:05:00"
    assert fixed is True
    assert initial_epoch % 300 == phase


def _phase(conn, label):
    return _job(conn, TARGETS[label][0])[3] % 300


def test_stage_order_follows_the_data_dependencies(conn):
    norm = _phase(conn, "normalization")
    route = _phase(conn, "energy_routing")
    env = _phase(conn, "environment_routing")
    cagg = _phase(conn, "ca_energy_1min")
    phase_cagg = _phase(conn, "ca_energy_phase_1min")
    tier = _phase(conn, "consumption_1min") or 300  # +0:00 is the next boundary

    # Normalization runs after the boundary bucket's capture deadline, with margin.
    assert norm >= CAPTURE_DEADLINE_S + 30
    # Routing runs after normalization, leaving room for one 1-minute retry.
    norm_retry = _job(conn, TARGETS["normalization"][0])[6].total_seconds()
    assert route - norm >= norm_retry + 20
    assert env > norm
    # Aggregates refresh after routing; the 1-minute tier after the aggregate.
    assert cagg > route and phase_cagg > route
    assert tier > cagg


def test_demand_slot_follows_routing_and_is_unchanged(conn):
    job = _job(conn, "j.proc_schema = 'analytics' AND j.proc_name = 'run_demand_calculation_job'")
    _, interval, fixed, initial_epoch, *_ = job
    assert str(interval) == "0:15:00" and fixed and initial_epoch % 900 == DEMAND_PHASE_S
    # A quarter-hour is a 5-minute boundary: the boundary bucket is normalized
    # and routed before the demand slot, with a minute to spare.
    assert _phase(conn, "energy_routing") + 60 <= DEMAND_PHASE_S


def test_fifteen_minute_tier_runs_after_the_one_minute_tier(conn):
    job = _job(conn, "j.proc_schema = 'analytics' AND j.proc_name = 'run_energy_consumption_15min_job'")
    _, interval, fixed, initial_epoch, *_ = job
    assert str(interval) == "0:05:00" and fixed
    tier_slot = (_phase(conn, "consumption_1min") or 300)
    # 1099 runs at +2:28 / +7:28; the 1-minute tier reaches a 15-minute
    # boundary E at E+5:00, before the E+7:28 run.
    assert tier_slot < initial_epoch % 300 + 300


@pytest.mark.parametrize(
    "predicate",
    [
        "j.proc_schema = 'telemetry' AND j.proc_name = 'run_raw_receipt_state_job'",
        "j.proc_schema = 'analytics' AND j.proc_name = 'run_energy_consumption_5min_job'",
    ],
)
def test_jobs_that_must_stay_every_minute(conn, predicate):
    _, interval, *_ = _job(conn, predicate)
    assert str(interval) == "0:01:00"


def test_alert_evaluation_stays_every_minute_when_registered(conn):
    rows = conn.execute(
        "SELECT schedule_interval FROM timescaledb_information.jobs "
        "WHERE proc_schema = 'analytics' AND proc_name = 'run_alert_evaluation_job'"
    ).fetchall()
    if not rows:
        pytest.skip("alert evaluation job is registered by a separate manual step")
    # Its 3-minute gap tolerance (evaluate_alerts) assumes a 1-minute cadence.
    assert [str(r[0]) for r in rows] == ["0:01:00"]
