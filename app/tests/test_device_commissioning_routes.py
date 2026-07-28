from pathlib import Path

MAIN = Path("app/src/main.py").read_text()
TEMPLATE = Path("app/src/templates/devices.html").read_text()
SERVICE = Path("app/src/device_management_service.py").read_text()

def test_device_commissioning_route_and_service():
    assert "/administration/devices/{device_id}/commission" in MAIN
    assert "commission_device(" in SERVICE
    assert "/administration/devices/{{ d.device_id }}/commission" in TEMPLATE

def test_device_operational_policy_route():
    assert "/administration/devices/{device_id}/operational-policy" in MAIN
    assert "set_device_operational_policy(" in SERVICE
    assert "ASSET_ASSIGNED" in MAIN
