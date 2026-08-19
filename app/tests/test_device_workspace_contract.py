from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / "app/src/main.py").read_text()
SERVICE = (ROOT / "app/src/device_management_service.py").read_text()
CREATE = (ROOT / "app/src/templates/device_create.html").read_text()
DETAIL = (ROOT / "app/src/templates/device_detail.html").read_text()
EDIT = (ROOT / "app/src/templates/device_edit.html").read_text()
MIGRATION = (
    ROOT / "postgres/ddl/108_device_administration_workspace.sql"
).read_text()


def test_device_workspace_has_dedicated_pages():
    assert '"/administration/devices/new"' in MAIN
    assert '"/administration/devices/{device_id}"' in MAIN
    assert '"/administration/devices/{device_id}/edit"' in MAIN
    assert "device_create.html" in MAIN
    assert "device_detail.html" in MAIN
    assert "device_edit.html" in MAIN


def test_create_device_captures_telemetry_identity_contract():
    for field in (
        'name="profile_id"',
        'name="identifier_type"',
        'name="identifier_value"',
        'name="device_category_id"',
        'name="device_model_id"',
        'name="protocol"',
        'name="firmware_version"',
        'name="operational_policy"',
    ):
        assert field in CREATE
    assert "MQTT UID" in CREATE
    assert "Compatible telemetry profile" in CREATE


def test_detail_and_edit_expose_profile_and_identifier():
    assert "Identifier value" in DETAIL
    assert "Telemetry state" in DETAIL
    assert "Profile validation" in DETAIL
    assert 'name="identifier_value"' in EDIT
    assert 'name="profile_id"' in EDIT
    assert "Reason for change" in EDIT
    assert "Asset assignment requirement" in DETAIL
    assert "location_mode" in DETAIL


def test_database_contract_creates_identifier_atomically():
    assert "INSERT INTO metadata.device_identifiers" in MIGRATION
    assert "config.device_profile_categories" in MIGRATION
    assert "admin.portal_user_can_access_site" in MIGRATION
    assert "admin.get_device_workspace" in MIGRATION
    assert "admin.update_device_workspace" in MIGRATION


def test_service_uses_new_controlled_functions():
    assert "admin.create_device" in SERVICE
    assert "admin.get_device_workspace" in SERVICE
    assert "admin.update_device_workspace" in SERVICE


def test_context_independent_inventory_and_inheritance_contract():
    migration = (ROOT / "postgres/ddl/109_context_independent_inventory_and_device_location.sql").read_text()
    assert "location_mode" in migration
    assert "GATEWAY" in migration
    assert "operational_policy" in migration
    assert "location_path" in migration
    assert "portal_user_can_access_site" in migration
    assert "active_context" not in MAIN[MAIN.index("async def render_device_administration"):MAIN.index("async def _device_form_catalog")]
