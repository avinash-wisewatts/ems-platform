from tests.sql_contract_sources import baseline_migration_sql
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATION = baseline_migration_sql("179_simplify_device_lifecycle_statuses.sql")


def test_legacy_device_states_are_migrated_to_registered():
    assert "WHERE lifecycle_status IN ('DISCOVERED', 'UNASSIGNED', 'COMMISSIONING')" in MIGRATION
    assert "SET lifecycle_status = 'REGISTERED'" in MIGRATION


def test_database_constraint_contains_only_four_device_lifecycle_states():
    assert "'REGISTERED', 'ACTIVE', 'INACTIVE', 'DECOMMISSIONED'" in MIGRATION


def test_obsolete_states_fail_at_database_boundary():
    assert "reject_obsolete_device_lifecycle_status" in MIGRATION
    assert "Use Commission device to activate a device" in MIGRATION


def test_active_is_not_a_routine_lifecycle_transition():
    device_transition_section = MIGRATION.split("WHEN 'DEVICE' THEN", 1)[1].split("ELSE FALSE", 1)[0]
    assert "('REGISTERED','ACTIVE')" not in device_transition_section
    assert "('INACTIVE','ACTIVE')" not in device_transition_section
