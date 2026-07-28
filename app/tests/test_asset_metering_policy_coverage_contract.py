from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/121_asset_metering_policy_coverage.sql"
MAIN = ROOT / "app/src/main.py"
NAV = ROOT / "app/src/admin_navigation.py"


def sql_text() -> str:
    return MIGRATION.read_text()


def test_policy_is_explicit_and_has_no_default():
    sql = sql_text()
    assert "ALTER COLUMN metering_requirement DROP DEFAULT" in sql
    assert "ALTER COLUMN metering_requirement SET NOT NULL" in sql
    assert "DIRECT_METER_REQUIRED" in sql
    assert "DESCENDANT_COVERAGE_ALLOWED" in sql
    assert "NOT_REQUIRED" in sql


def test_direct_coverage_requires_qualifying_primary_meter():
    sql = sql_text()
    assert "ad.relationship_type = 'PRIMARY_METER'" in sql
    assert "lower(dc.name) = 'energy meter'" in sql
    assert "asset_device_relationship_category_compatibility" in sql


def test_descendant_denominator_is_policy_and_lifecycle_driven():
    sql = sql_text()
    assert "descendant.status = 'active'" in sql
    assert "descendant.metering_requirement = 'DIRECT_METER_REQUIRED'" in sql
    assert "hc.depth > 0" in sql


def test_not_required_is_visible_but_excluded():
    sql = sql_text()
    assert "asset.metering_requirement <> 'NOT_REQUIRED'" in sql
    assert "THEN 'EXCLUDED'" in sql
    assert "THEN NULL" in sql


def test_tenant_scoped_administration_contract_exists():
    sql = sql_text()
    assert "admin.list_accessible_asset_meter_coverage" in sql
    assert "admin.portal_user_can_access_site" in sql
    assert '"/administration/metering-coverage"' in MAIN.read_text()
    assert '"metering-coverage"' in NAV.read_text()
