from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "postgres/migrations/118_device_lifecycle_management.sql").read_text()
TEMPLATE = (ROOT / "app/src/templates/devices.html").read_text()
MAIN = (ROOT / "app/src/main.py").read_text()


def test_device_lifecycle_update_is_controlled_and_audited():
    assert "admin.update_device_lifecycle" in SQL
    assert "UPDATE_DEVICE_LIFECYCLE" in SQL
    assert "onboarding_audit" in SQL


def test_unassigned_is_valid_and_active_requires_commissioning():
    assert "'UNASSIGNED'" in SQL
    assert "controlled commissioning action" in SQL
    assert "reject_uncommissioned_active_device" in SQL


def test_decommissioning_checks_relationship_dependencies():
    assert "metadata.asset_devices" in SQL
    assert "config.site_energy_meter_roles" in SQL
    assert "is_active=TRUE" in SQL


def test_decommissioning_preserves_history():
    assert "DELETE FROM metadata.devices" not in SQL
    assert "DELETE FROM telemetry" not in SQL


def test_portal_exposes_lifecycle_action():
    assert "/administration/devices/{device_id}/lifecycle" in MAIN
    assert "Lifecycle action" in TEMPLATE
    assert "Routine reactivation is blocked" in TEMPLATE
