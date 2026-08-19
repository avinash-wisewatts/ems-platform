from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/013_demand_calculation_processor.sql"
MIRROR = ROOT / "postgres/ddl/132_demand_calculation_processor.sql"


def test_demand_processor_migration_and_mirror_match():
    assert MIGRATION.read_text() == MIRROR.read_text()


def test_demand_processor_supports_all_resolved_methods():
    sql = MIGRATION.read_text()
    assert "METER_NATIVE" in sql
    assert "ENERGY_COUNTER_DELTA" in sql
    assert "TIME_WEIGHTED_POWER" in sql
    assert "INSUFFICIENT_SOURCE_RESOLUTION" in sql


def test_demand_processor_has_wall_clock_alignment_and_bounded_job():
    sql = MIGRATION.read_text()
    assert "analytics.resolve_demand_interval" in sql
    assert "analytics.refresh_demand_analytics" in sql
    assert "analytics.run_demand_calculation_job" in sql
    assert "INTERVAL '1 minute'" in sql
    assert "INTERVAL '3 hours'" in sql
    assert "INTERVAL '10 minutes'" in sql


def test_demand_processor_keeps_late_arrival_and_processing_grace_separate():
    sql = MIGRATION.read_text()
    assert "late_arrival_tolerance_seconds" in sql
    assert "v_receipt_deadline" in sql
    assert "processing grace" in sql
