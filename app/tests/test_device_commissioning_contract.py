from tests.sql_contract_sources import canonical_sql
from pathlib import Path

SQL = canonical_sql("97_device_commissioning_action.sql")

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

def test_canonical_device_commissioning_contract_is_present():
    assert "CREATE OR REPLACE FUNCTION admin.commission_device" in SQL
