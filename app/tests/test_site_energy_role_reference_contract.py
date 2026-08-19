from tests.sql_contract_sources import canonical_sql
from pathlib import Path
SQL=canonical_sql("100_site_energy_role_administration.sql")
def test_reference_roles():
    assert "CREATE TABLE IF NOT EXISTS config.site_energy_roles" in SQL
    for role in ("GRID_IMPORT","GRID_EXPORT","SITE_CONSUMPTION","SOLAR_GENERATION","GENERATOR_OUTPUT","BATTERY_CHARGE","BATTERY_DISCHARGE"):
        assert f"('{role}'" in SQL
    assert "is_exclusive_per_site" in SQL
    assert "site_energy_meter_roles_meter_role_fkey" in SQL
def test_legacy_generation_normalized():
    assert "SET meter_role = 'SOLAR_GENERATION'" in SQL
    assert "WHERE meter_role = 'ONSITE_GENERATION'" in SQL

    drop_position = SQL.index(
        "DROP CONSTRAINT IF EXISTS ck_site_energy_meter_role"
    )
    update_position = SQL.index(
        "SET meter_role = 'SOLAR_GENERATION'"
    )
    foreign_key_position = SQL.index(
        "ADD CONSTRAINT site_energy_meter_roles_meter_role_fkey"
    )

    assert drop_position < update_position < foreign_key_position
