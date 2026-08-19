from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/009_selected_sample_direct_normalization.sql"
DDL = ROOT / "postgres/ddl/128_selected_sample_direct_normalization.sql"


def _sql(path: Path) -> str:
    return path.read_text()


def test_009_and_canonical_mirror_exist_and_match_semantics():
    for sql in (_sql(MIGRATION), _sql(DDL)):
        assert "CREATE OR REPLACE PROCEDURE telemetry.load_normalized_points_incremental" in sql
        assert "JOIN telemetry.raw_messages rm" in sql
        assert "jsonb_array_elements(rm.payload -> 'rtdata')" in sql
        assert "config.profile_field_mapping" in sql
        assert "metadata.device_field_mapping" in sql
        assert "config.device_point_configuration" in sql
        assert "tmp_selected_samples" in sql
        assert "tmp_normalized_batch" in sql
        assert "FROM telemetry.v_normalized_points" not in sql
        assert "JOIN telemetry.v_normalized_points" not in sql


def test_009_preserves_set_based_capture_policy_selection():
    sql = _sql(MIGRATION)
    assert "policy_ranked AS MATERIALIZED" in sql
    assert "capture_interval_seconds" in sql
    assert "late_arrival_tolerance_seconds" in sql
    assert "DISTINCT ON (site_id,bucket_start,device_id)" in sql
    assert "finalization_deadline <= clock_timestamp()" in sql


def test_009_keeps_canonical_mapping_precedence_and_quality_rules():
    sql = _sql(MIGRATION)
    assert "'DEVICE_PROFILE'::TEXT AS mapping_source" in sql
    assert "'DEVICE_OVERRIDE'::TEXT AS mapping_source" in sql
    assert "mapping_priority" in sql
    assert "INVALID_NUMERIC" in sql
    assert "ON CONFLICT (event_time,device_id,logical_point_id) DO UPDATE" in sql
