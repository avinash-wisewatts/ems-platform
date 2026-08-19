from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/018_grafana_config_permission_boundary_fix.sql"
DDL = ROOT / "postgres/ddl/137_grafana_config_permission_boundary_fix.sql"


def test_018_migration_and_canonical_mirror_match():
    assert MIGRATION.exists()
    assert DDL.exists()
    assert MIGRATION.read_text() == DDL.read_text()


def test_demand_capability_boundary_is_restored_after_017_replacement():
    sql = MIGRATION.read_text()
    signature = (
        "ALTER FUNCTION analytics.resolve_demand_capability"
        "(UUID, TEXT, UUID, TIMESTAMPTZ)"
    )
    assert signature in sql
    assert "SECURITY DEFINER" in sql
    assert "SET search_path TO pg_catalog, analytics, config, metadata" in sql
    assert (
        "GRANT EXECUTE\n"
        "ON FUNCTION analytics.resolve_demand_capability"
        "(UUID, TEXT, UUID, TIMESTAMPTZ)\n"
        "TO ems_readonly, grafana_reader;"
    ) in sql


def test_energy_interval_quality_boundary_is_owner_rights_and_config_stays_private():
    sql = MIGRATION.read_text()
    signature = (
        "ALTER FUNCTION config.resolve_interval_quality_rule"
        "(UUID, TIMESTAMPTZ)"
    )
    assert signature in sql
    assert "SET search_path TO pg_catalog, config, metadata" in sql

    # Do not solve the dashboard error by opening the config schema/tables.
    lowered = sql.lower()
    assert "grant usage on schema config" not in lowered
    assert "grant select on config.interval_quality_rules" not in lowered
    assert "grant select on all tables in schema config" not in lowered
