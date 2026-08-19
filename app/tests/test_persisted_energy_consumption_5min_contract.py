from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

MIGRATION = (
    ROOT
    / "postgres/migrations"
    / "031_persisted_validated_energy_consumption_5min.sql"
)

MIRROR = (
    ROOT
    / "postgres/ddl"
    / "143_persisted_validated_energy_consumption_5min.sql"
)


def test_persisted_native_5min_table_exists():
    sql = MIGRATION.read_text()

    assert "CREATE TABLE IF NOT EXISTS analytics.energy_consumption_5min" in sql
    assert "create_hypertable" in sql
    assert "PRIMARY KEY" in sql
    assert "device_id" in sql
    assert "bucket_start" in sql


def test_refresh_reads_native_5min_source():
    sql = MIGRATION.read_text()

    assert "FROM telemetry.ca_energy_5min ca" in sql
    assert "analytics.refresh_energy_consumption_5min" in sql


def test_only_300_second_policy_is_native_5min():
    sql = MIGRATION.read_text()

    assert "capture_policy.capture_interval_seconds" in sql
    assert "= 300" in sql

    assert "previous_capture_policy.capture_interval_seconds" in sql


def test_total_register_semantics_are_explicit():
    sql = MIGRATION.read_text()

    assert "ENERGY_IMPORT_TOTAL" in sql
    assert "ENERGY_EXPORT_TOTAL" in sql
    assert "import_sem.logical_point_id" in sql
    assert "export_sem.logical_point_id" in sql


def test_refresh_uses_authoritative_classifier():
    sql = MIGRATION.read_text()

    assert "resolve_interval_quality_rule" in sql
    assert sql.count("analytics.classify_energy_register_delta") == 2


def test_refresh_is_idempotent():
    sql = MIGRATION.read_text()

    assert "ON CONFLICT" in sql
    assert "device_id" in sql
    assert "bucket_start" in sql
    assert "DO UPDATE" in sql


def test_job_processes_completed_5min_buckets():
    sql = MIGRATION.read_text()

    assert "analytics.run_energy_consumption_5min_job" in sql
    assert "date_bin" in sql
    assert "INTERVAL '5 minutes'" in sql
    assert '{"lookback":"30 minutes"}' in sql


def test_internal_security_boundary():
    sql = MIGRATION.read_text()

    assert "REVOKE ALL" in sql
    assert "FROM PUBLIC" in sql

    assert (
        "GRANT SELECT\nON analytics.energy_consumption_5min"
        not in sql
    )

    assert "TO ems_admin" in sql


def test_canonical_mirror_matches_migration():
    assert MIRROR.read_text() == MIGRATION.read_text()
