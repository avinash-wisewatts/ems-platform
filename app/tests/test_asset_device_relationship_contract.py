from pathlib import Path
SQL=(Path(__file__).parents[2]/"postgres/migrations/119_asset_device_relationship_management.sql").read_text()

def test_database_controls_relationship_types_and_compatibility():
    assert "asset_device_relationship_types" in SQL
    assert "asset_device_relationship_category_compatibility" in SQL
    assert "trg_validate_asset_device_relationship" in SQL

def test_primary_meter_is_qualified_and_exclusive():
    assert "lower(dc.name)='energy meter'" in SQL
    assert "asset_devices_primary_meter_asset_uq" in SQL
    assert "asset_devices_primary_meter_device_uq" in SQL

def test_assignment_is_scoped_and_audited():
    assert "portal_user_can_access_site" in SQL
    assert "ASSIGN_DEVICE_TO_ASSET" in SQL
    assert "onboarding_audit" in SQL

def test_coverage_uses_qualifying_primary_meter():
    assert "CREATE OR REPLACE VIEW analytics.v_asset_meter_coverage_configuration" in SQL
    assert "asset_device_relationship_category_compatibility c" in SQL
