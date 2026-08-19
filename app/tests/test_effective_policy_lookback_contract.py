from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/010_effective_policy_lookback.sql"
CANONICAL = ROOT / "postgres/ddl/129_effective_policy_lookback.sql"


def test_010_uses_effective_policy_horizon_for_dynamic_overlap():
    sql = MIGRATION.read_text()
    assert "p.effective_from <= v_window_end" in sql
    assert "p.effective_to IS NULL" in sql
    assert "p.effective_to" in sql
    assert "+ make_interval(" in sql
    assert "p.capture_interval_seconds" in sql
    assert "p.late_arrival_tolerance_seconds" in sql
    assert ">= v_previous_checkpoint" in sql
    assert "FROM config.telemetry_capture_policies p" in sql


def test_010_preserves_selected_sample_direct_normalization():
    sql = MIGRATION.read_text()
    assert "CREATE TEMP TABLE tmp_capture_candidates" in sql
    assert "CREATE TEMP TABLE tmp_selected_samples" in sql
    assert "CREATE TEMP TABLE tmp_normalized_batch" in sql
    assert "JOIN telemetry.raw_messages rm" in sql
    assert "JOIN config.profile_field_mapping pfm" in sql
    assert "INSERT INTO telemetry.normalized_points" in sql
    assert "telemetry.v_normalized_points" not in sql.split("COMMENT ON PROCEDURE", 1)[0]


def test_010_canonical_mirror_matches_migration_body():
    migration = MIGRATION.read_text().replace("-- 010_effective_policy_lookback.sql", "-- 129_effective_policy_lookback.sql", 1)
    assert CANONICAL.read_text() == migration
