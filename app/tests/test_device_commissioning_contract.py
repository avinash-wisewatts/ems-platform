from pathlib import Path

SQL = Path("postgres/migrations/124_device_commissioning_action.sql").read_text()

def test_device_commissioning_contract():
    assert "CREATE OR REPLACE FUNCTION admin.commission_device" in SQL
    assert "PROFILE_CATEGORY_INCOMPATIBLE" in SQL
    assert "REQUIRED_TELEMETRY_POINTS_NOT_VALIDATED" in SQL
    assert "ASSET_ASSIGNMENT_REQUIRED_BY_POLICY" in SQL
    assert "COMMISSION_DEVICE" in SQL
    assert "operational_policy" in SQL
    assert "pfm.is_required" in SQL
    assert "telemetry.normalized_points" in SQL
    assert "REQUIRED_TELEMETRY_PROFILE_POINTS_MISSING" not in SQL
    assert "drp.validated_required_point_count = drp.required_point_count" in SQL

def test_canonical_matches_migration():
    assert Path("postgres/ddl/97_device_commissioning_action.sql").read_bytes() == Path("postgres/migrations/124_device_commissioning_action.sql").read_bytes()
