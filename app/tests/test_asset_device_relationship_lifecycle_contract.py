from pathlib import Path
SQL=Path("postgres/archive/prebaseline_20260807/migrations/120_asset_device_relationship_lifecycle.sql").read_text()
def test_relationship_history_is_immutable_snapshot_contract():
    assert "asset_device_relationship_history" in SQL and "archive_action" in SQL and "audit_transaction_id" in SQL
def test_direct_meter_removal_guard_exists():
    assert "DIRECT_METER_REQUIRED" in SQL and "must retain a PRIMARY_METER" in SQL
def test_replacement_prevalidates_then_archives():
    assert "PERFORM metadata.assert_asset_device_relationship" in SQL and "'REPLACED'" in SQL and "replacement_relationship_id" in SQL
def test_metadata_fields_exist():
    for field in ("panel_name","feeder_name","breaker_identifier","channel_identifier","ct_ratio","phase_designation","mounting_point","engineering_notes"): assert field in SQL
