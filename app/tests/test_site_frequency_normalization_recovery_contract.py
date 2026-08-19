from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/007_site_frequency_normalization_recovery.sql"
CANONICAL = ROOT / "postgres/ddl/126_site_frequency_normalization_recovery.sql"
MANIFEST = ROOT / "postgres/restructure_manifest.csv"


def sql(path: Path) -> str:
    return path.read_text()


def test_capture_bucket_ledger_and_clock_policy_are_used():
    text = sql(MIGRATION)
    assert "CREATE TABLE IF NOT EXISTS telemetry.capture_bucket_samples" in text
    assert "PRIMARY KEY (site_id, bucket_start, device_id)" in text
    assert "telemetry.resolve_site_capture_bucket" in text
    assert "ORDER BY site_id,bucket_start,device_id" in text
    assert "event_time DESC,received_at DESC,raw_message_id DESC" in text
    assert "finalization_deadline <= clock_timestamp()" in text
    assert "received_at <= finalization_deadline" in text


def test_normalizer_expands_only_selected_samples():
    text = sql(MIGRATION)
    assert "CREATE TEMP TABLE tmp_capture_candidates" in text
    assert "CREATE TEMP TABLE tmp_selected_samples" in text
    assert "CREATE TEMP TABLE tmp_normalized_batch" in text
    assert "source_np.raw_message_id=s.raw_message_id" in text
    assert "source_np.device_id=s.device_id" in text
    assert "source_np.event_time=s.event_time" in text
    assert "LEAST(p_overlap, INTERVAL '1 minute')" not in text


def test_raw_retention_is_48_hours_and_failure_retention_stays_30_days():
    text = sql(MIGRATION)
    assert "add_retention_policy('telemetry.raw_messages',INTERVAL '48 hours')" in text
    assert "add_retention_policy('telemetry.raw_message_failures',INTERVAL '30 days')" in text


def test_normalization_schedule_is_five_minutes_and_recovery_hourly():
    text = sql(MIGRATION)
    assert "proc_name='run_normalization_job'" in text
    assert "schedule_interval=>INTERVAL '5 minutes'" in text
    assert "run_failed_message_recovery_job" in text
    assert "schedule_interval=>INTERVAL '1 hour'" in text


def test_connectivity_is_based_on_raw_receipt_state():
    text = sql(MIGRATION)
    assert "telemetry.device_raw_receipt_state" in text
    assert "run_raw_receipt_state_job" in text
    assert "CREATE OR REPLACE VIEW analytics.v_gateway_connectivity" in text
    assert "'RAW_TELEMETRY'" in text
    assert "INSERT INTO telemetry.device_telemetry_state" in text
    assert "latest_received_timestamp=GREATEST" in text


def test_unselected_raw_messages_are_not_persistence_failures():
    text = sql(MIGRATION)
    assert "selected_messages AS MATERIALIZED" in text
    assert "m.selected_device_count>0 AND m.enabled_point_count>0 AND m.produced_point_count=0" in text
    assert "'normalization_expectation','SELECTED_CAPTURE_SAMPLE_ONLY'" in text


def test_recovery_state_and_audit_are_preserved():
    text = sql(MIGRATION)
    for column in (
        "resolution_status",
        "resolved_at",
        "resolution_method",
        "replay_attempt_count",
        "last_replay_at",
        "next_replay_at",
        "last_replay_error",
    ):
        assert column in text
    for status in ("OPEN", "RETRY_PENDING", "RECOVERED", "PERMANENT_FAILURE"):
        assert status in text
    assert "DELETE FROM telemetry.raw_message_failures" not in text
    assert "AUTO_REPLAY_OR_CANONICAL_SUPERSESSION" in text
    assert "NOT EXISTS" in text
    assert "ROW(ce.event_time,ce.received_at,ce.raw_message_id)" in text


def test_domain_routing_is_not_replaced_or_given_second_sampling_contract():
    text = sql(MIGRATION)
    assert "CREATE OR REPLACE PROCEDURE telemetry.load_energy_measurements_incremental" not in text
    assert "CREATE OR REPLACE PROCEDURE telemetry.load_environment_measurements_incremental" not in text


def test_canonical_mirror_matches_migration_body():
    migration = sql(MIGRATION).replace(
        "-- 007_site_frequency_normalization_recovery.sql",
        "-- 126_site_frequency_normalization_recovery.sql",
        1,
    )
    assert migration == sql(CANONICAL)


def test_manifest_registers_007_and_126():
    text = sql(MANIFEST)
    assert "126_site_frequency_normalization_recovery.sql,canonical_mirror" in text
    assert "007_site_frequency_normalization_recovery.sql,migration" in text
