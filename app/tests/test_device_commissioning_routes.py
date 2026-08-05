from pathlib import Path

MAIN = Path("app/src/main.py").read_text()
DETAIL = Path("app/src/templates/device_detail.html").read_text()
SERVICE = Path("app/src/device_management_service.py").read_text()


def test_device_commissioning_route_and_service():
    assert "/administration/devices/{device_id}/commission" in MAIN
    assert "commission_device(" in SERVICE
    assert "/administration/devices/{{ device.device_id }}/commission" in DETAIL


def test_device_operational_policy_route():
    assert "/administration/devices/{device_id}/operational-policy" in MAIN
    assert "set_device_operational_policy(" in SERVICE
    assert "ASSET_ASSIGNED" in DETAIL
