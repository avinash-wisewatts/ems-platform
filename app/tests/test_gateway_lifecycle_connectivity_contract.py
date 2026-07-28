from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MIGRATION = ROOT / "postgres/migrations/116_gateway_lifecycle_connectivity.sql"


def migration_sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def test_connectivity_is_derived_separately_from_lifecycle() -> None:
    sql = migration_sql()
    assert "'NEVER_SEEN'" in sql
    assert "'ONLINE'" in sql
    assert "'OFFLINE'" in sql
    assert "last_successful_communication" in sql
    assert "gateway_connectivity_policy" in sql


def test_lifecycle_change_is_audited_and_decommissioning_is_soft() -> None:
    sql = migration_sql()
    assert "UPDATE_GATEWAY_LIFECYCLE" in sql
    assert "onboarding_audit" in sql
    assert "DELETE FROM metadata.gateways" not in sql
    assert "active devices before decommissioning" in sql


def test_decommissioned_gateway_cannot_routinely_reactivate() -> None:
    assert "cannot be reactivated through routine administration" in migration_sql()
