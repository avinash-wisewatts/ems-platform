from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/006_canonical_failure_classification.sql"
CANONICAL = ROOT / "postgres/ddl/125_canonical_failure_classification.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def _sql(path: Path) -> str:
    return path.read_text()


def test_migration_redefines_failure_capture_only():
    sql = _sql(MIGRATION)
    assert "CREATE OR REPLACE PROCEDURE telemetry.capture_raw_message_failures_incremental" in sql
    assert "CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental" not in sql
    assert "CREATE OR REPLACE PROCEDURE telemetry.run_raw_message_failure_capture_job" not in sql


def test_classifier_uses_canonical_normalized_identity():
    sql = _sql(MIGRATION)
    assert "np.device_id = d.id" in sql
    assert "np.event_time = element.event_time" in sql
    assert "np.logical_point_id =" in sql
    assert "dpc.logical_point_id" in sql
    assert "'normalization_match_basis', 'CANONICAL_IDENTITY'" in sql


def test_classifier_does_not_match_persisted_rows_by_mutable_lineage():
    sql = _sql(MIGRATION)
    assert "np.raw_message_id = r.id" not in sql
    assert "np.platform_received_at = r.received_at" not in sql


def test_classifier_event_time_matches_normalization_contract():
    sql = _sql(MIGRATION)
    assert "e.value ->> 'ts' IS NULL" in sql
    assert "pg_input_is_valid" in sql
    assert "to_timestamp" in sql
    assert "ELSE r.received_at" in sql


def test_failure_taxonomy_and_grace_are_preserved():
    sql = _sql(MIGRATION)
    for code in (
        "INVALID_JSON",
        "MISSING_RTDATA_ARRAY",
        "EMPTY_RTDATA_ARRAY",
        "UNRESOLVED_DEVICE_ELEMENTS",
        "DEVICE_WITHOUT_PROFILE",
        "NO_ENABLED_POINTS",
        "NO_PERSISTED_NORMALIZED_ROWS",
        "PARTIAL_NORMALIZATION",
    ):
        assert code in sql
    assert "clock_timestamp() - p_grace" in sql
    assert "v_normalized_checkpoint" in sql


def test_failure_quarantine_payload_and_retention_contract_are_not_redefined():
    sql = _sql(MIGRATION)
    assert "CREATE TABLE" not in sql
    assert "remove_retention_policy" not in sql
    assert "add_retention_policy" not in sql
    assert "c.payload" in sql


def test_canonical_mirror_matches_migration_body():
    migration = _sql(MIGRATION).replace(
        "-- 006_canonical_failure_classification.sql",
        "-- 125_canonical_failure_classification.sql",
        1,
    )
    assert migration == _sql(CANONICAL)


def test_manifest_registers_006_and_125():
    text = _sql(MANIFEST)
    assert "125_canonical_failure_classification.sql,canonical_mirror" in text
    assert "006_canonical_failure_classification.sql,migration" in text
