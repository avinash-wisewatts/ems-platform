from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "028_persisted_validated_energy_consumption_1min.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "140_persisted_validated_energy_consumption_1min.sql"
)


def test_persisted_energy_consumption_uses_one_minute_aggregate():
    sql = MIGRATION.read_text()

    assert "analytics.energy_consumption_1min" in sql
    assert "telemetry.ca_energy_1min" in sql
    assert "telemetry.energy_measurements" not in sql


def test_persisted_energy_consumption_uses_total_register_semantics():
    sql = MIGRATION.read_text()

    assert "ENERGY_IMPORT_TOTAL" in sql
    assert "ENERGY_EXPORT_TOTAL" in sql
    assert "GRID_IMPORT" in sql
    assert "GRID_EXPORT" in sql


def test_persisted_energy_consumption_reuses_canonical_classifier():
    sql = MIGRATION.read_text()

    assert "analytics.classify_energy_register_delta" in sql
    assert "config.resolve_interval_quality_rule" in sql
    assert "telemetry.resolve_site_capture_bucket" in sql


def test_persisted_energy_consumption_preserves_gap_predecessor():
    sql = MIGRATION.read_text()

    assert "previous_ca.bucket_start <" in sql
    assert "ORDER BY" in sql
    assert "previous_ca.bucket_start DESC" in sql
    assert "LIMIT 1" in sql


def test_persisted_energy_consumption_is_idempotent():
    sql = MIGRATION.read_text()

    assert "PRIMARY KEY" in sql
    assert "device_id" in sql
    assert "bucket_start" in sql
    assert "ON CONFLICT" in sql
    assert "DO UPDATE" in sql


def test_persisted_energy_consumption_has_incremental_job():
    sql = MIGRATION.read_text()

    assert "analytics.refresh_energy_consumption_1min" in sql
    assert "analytics.run_energy_consumption_1min_job" in sql
    assert "INTERVAL '30 minutes'" in sql
    assert "INTERVAL '1 minute'" in sql
    assert "add_job" in sql


def test_028_does_not_cut_over_existing_dashboard_reads():
    sql = MIGRATION.read_text()

    assert "CREATE OR REPLACE VIEW analytics.v_energy_consumption_1min" not in sql
    assert "v_energy_consumption_5min" not in sql
    assert "v_energy_consumption_15min" not in sql
    assert "grafana/dashboards" not in sql


def test_canonical_mirror_matches_migration():
    assert MIRROR.read_text() == MIGRATION.read_text()
