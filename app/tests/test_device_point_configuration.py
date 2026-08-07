from pathlib import Path
from uuid import uuid4

import pytest

from src.device_management import (
    DeviceManagementValidationError,
    validate_device_point_configuration_update,
)

ROOT = Path(__file__).resolve().parents[2]
SQL = (ROOT / "postgres/archive/prebaseline_20260807/migrations/176_device_telemetry_point_administration.sql").read_text()
MAIN = (ROOT / "app/src/main.py").read_text()
TEMPLATE = (ROOT / "app/src/templates/device_telemetry_points.html").read_text()
SERVICE = (ROOT / "app/src/device_management_service.py").read_text()


def test_point_update_accepts_an_empty_enabled_set():
    payload = validate_device_point_configuration_update(
        enabled_logical_point_ids=[],
        change_reason="No telemetry points are required for this device",
    )
    assert payload["enabled_logical_point_ids"] == []


def test_point_update_normalizes_and_deduplicates_uuids():
    point_id = str(uuid4())
    payload = validate_device_point_configuration_update(
        enabled_logical_point_ids=[point_id, point_id],
        change_reason="Commissioning selection",
    )
    assert payload["enabled_logical_point_ids"] == [point_id]


def test_point_update_requires_change_reason():
    with pytest.raises(DeviceManagementValidationError, match="Change reason"):
        validate_device_point_configuration_update(
            enabled_logical_point_ids=[],
            change_reason=" ",
        )


def test_database_contract_is_scope_safe_and_audited():
    assert "admin.portal_user_has_permission" in SQL
    assert "device.manage" in SQL
    assert "admin.device_point_actor_can_access_site" in SQL
    assert "admin.portal_user_can_access_site(bigint,uuid)" in SQL
    assert "SELECT admin.portal_user_can_access_site($1, $2)" in SQL
    assert "UPDATE_DEVICE_POINT_CONFIGURATION" in SQL
    assert "admin.onboarding_audit" in SQL


def test_database_contract_allows_disable_all_and_reset():
    assert "COALESCE(p_enabled_logical_point_ids, ARRAY[]::UUID[])" in SQL
    assert "admin.reset_device_point_configuration" in SQL
    assert "admin.reset_device_point_configuration" in SQL


def test_portal_exposes_point_management_routes_and_controls():
    assert "/administration/devices/{device_id}/telemetry-points" in MAIN
    assert "list_device_point_configuration" in SERVICE
    assert "Enable all" in TEMPLATE
    assert "Disable all" in TEMPLATE
    assert "Reset from profile" in TEMPLATE
    assert "Change reason" in TEMPLATE
