from tests.sql_contract_sources import canonical_sql
from pathlib import Path

SQL = canonical_sql("98_telemetry_availability_validation.sql")

def test_last_seen_and_states_contract():
    assert "analytics.v_device_telemetry_availability" in SQL
    assert "dp.profile_code AS profile_code" in SQL
    assert "dp.code AS profile_code" not in SQL
    assert "max(np.event_time)" in SQL
    assert "max(np.created_at)" in SQL
    assert "idx_normalized_points_device_source_time" not in SQL
    assert "idx_norm_device_time" in SQL
    assert "idx_normalized_points_device_received_time" in SQL
    for state in ("NEVER_SEEN","RECEIVING","STALE","SILENT","INVALID_PROFILE","UNMAPPED","VALIDATED"):
        assert state in SQL
    assert "telemetry_availability_policy" in SQL
    assert "portal_user_can_access_site" in SQL
    assert "REVOKE ALL ON analytics.v_device_telemetry_availability FROM ems_app" in SQL
    assert "tr.latest_received_timestamp IS NULL THEN 'NEVER_SEEN'" in SQL
    assert "d.operational_policy = 'ASSET_ASSIGNED'" in SQL
    assert "FROM metadata.asset_devices ad" in SQL
    assert "tr.latest_valid_received_timestamp" in SQL

def test_configuration_and_telemetry_are_separate():
    assert "configuration_state" in SQL
    assert "telemetry_state" in SQL
    assert "profile_validation_result" in SQL
