from tests.sql_contract_sources import canonical_sql
from pathlib import Path
SQL=canonical_sql("100_site_energy_role_administration.sql")
def test_qualifying_meter_and_tenant_site_validation():
    assert "lower(v_category)<>'energy meter'" in SQL
    assert "Device and site must belong to the same tenant and site." in SQL
    assert "portal_user_can_access_site" in SQL
    assert "trg_validate_site_energy_meter_role" in SQL
def test_no_artificial_asset_required():
    block=SQL.split("CREATE OR REPLACE FUNCTION admin.assign_site_energy_meter_role",1)[1].split("CREATE OR REPLACE FUNCTION admin.list_accessible_site_energy_meter_roles",1)[0]
    assert "metadata.asset_devices" not in block
    assert "INSERT INTO config.site_energy_meter_roles" in block
def test_assignment_audited_and_scoped():
    assert "admin.write_audit_event" in SQL
    assert "ASSIGN_SITE_ENERGY_METER_ROLE" in SQL
    assert "REVOKE ALL ON config.site_energy_meter_roles FROM PUBLIC,ems_app" in SQL
    assert "GRANT EXECUTE ON FUNCTION admin.assign_site_energy_meter_role" in SQL
def test_exclusive_role_rule():
    assert "('SITE_CONSUMPTION'" in SQL
    assert "TRUE,TRUE,30" in SQL
    assert "Only one active % role may apply to a site" in SQL
