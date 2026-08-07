from pathlib import Path

SQL = Path("postgres/archive/prebaseline_20260807/migrations/126_audit_lifecycle_safety.sql").read_text()


def test_shared_transition_contract_exists():
    assert "CREATE OR REPLACE FUNCTION admin.lifecycle_dependencies" in SQL
    assert "CREATE OR REPLACE FUNCTION admin.validate_lifecycle_transition" in SQL
    assert "CREATE OR REPLACE FUNCTION admin.transition_entity_lifecycle" in SQL
    for entity in ("ORGANIZATION", "SITE", "ASSET", "GATEWAY", "DEVICE"):
        assert f"'{entity}'" in SQL


def test_decommissioning_checks_dependencies_and_preserves_history():
    assert "ACTIVE_DEPENDENCIES" in SQL
    assert "jsonb_array_length(v_dependencies)>0" in SQL
    assert "DELETE FROM metadata.organizations" not in SQL
    assert "DELETE FROM metadata.sites" not in SQL
    assert "DELETE FROM metadata.assets" not in SQL
    assert "DELETE FROM metadata.gateways" not in SQL
    assert "DELETE FROM metadata.devices" not in SQL


def test_reactivation_is_explicit_and_audited():
    assert "REACTIVATION_REQUIRES_EXPLICIT_OVERRIDE" in SQL
    assert "Only a platform administrator may explicitly reactivate" in SQL
    assert "admin.write_audit_event" in SQL
    assert "\'success\', false" in SQL
    assert "\'failure_reason\', v_validation->>\'reason\'" in SQL
    assert "Do not raise here: an exception would roll back the audit event." in SQL
    assert "RAISE EXCEPTION \'Lifecycle transition rejected" not in SQL


def test_new_assignments_to_decommissioned_entities_are_rejected():
    assert "trg_reject_decommissioned_asset_device_assignment" in SQL
    assert "trg_reject_decommissioned_site_energy_role" in SQL
    assert "New assignments to a decommissioned asset" in SQL
    assert "New assignments to a decommissioned device" in SQL
