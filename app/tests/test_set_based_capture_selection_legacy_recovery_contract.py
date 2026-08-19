from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "postgres/migrations/008_set_based_capture_selection_legacy_recovery.sql").read_text()


def test_set_based_policy_resolution_replaces_correlated_bucket_function():
    assert "policy_ranked AS MATERIALIZED" in SQL
    assert "JOIN config.telemetry_capture_policies p" in SQL
    assert "PARTITION BY rr.raw_message_id,rr.device_id" in SQL
    assert "telemetry.resolve_site_capture_bucket" not in SQL


def test_site_wall_clock_bucket_semantics_are_preserved():
    assert "COALESCE(s.timezone,'UTC')" in SQL
    assert "date_trunc('day',pr.local_event_time)" in SQL
    assert "late_arrival_tolerance_seconds" in SQL
    assert "finalization_deadline <= clock_timestamp()" in SQL


def test_pre_007_failures_are_closed_out_of_recovery_queue():
    assert "LEGACY_CLOSED" in SQL
    assert "migration_id='007_site_frequency_normalization_recovery'" in SQL
    assert "f.detected_at < c.applied_at" in SQL
    assert "LEGACY_PRE_007_HISTORY" in SQL
