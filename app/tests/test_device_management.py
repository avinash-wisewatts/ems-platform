from uuid import uuid4
import pytest
from src.device_management import DeviceManagementValidationError, validate_device_submission

def values():
    return dict(gateway_id=str(uuid4()),device_name="Main Meter",external_id="meter_01",
        device_category_id=str(uuid4()),device_model_id=str(uuid4()),profile_id=str(uuid4()),
        protocol="mqtt",lifecycle_status="registered",firmware_version="1.0",
        use_gateway_location="",building_id="",floor_id="",space_id="")

def test_device_only_registration_is_valid_without_asset():
    payload=validate_device_submission(**values())
    assert payload["external_id"]=="METER_01"
    assert payload["lifecycle_status"]=="REGISTERED"
    assert "asset_id" not in payload

def test_site_level_device_location_is_valid():
    payload=validate_device_submission(**values())
    assert payload["building_id"] is None and payload["space_id"] is None

def test_gateway_location_reuse_requires_explicit_choice():
    v=values(); v["use_gateway_location"]="on"
    assert validate_device_submission(**v)["use_gateway_location"] is True

def test_gateway_location_reuse_rejects_manual_location():
    v=values(); v["use_gateway_location"]="on"; v["building_id"]=str(uuid4())
    with pytest.raises(DeviceManagementValidationError,match="Clear the device location"):
        validate_device_submission(**v)

def test_external_id_is_controlled():
    v=values(); v["external_id"]="METER-01"
    with pytest.raises(DeviceManagementValidationError,match="letters, numbers"):
        validate_device_submission(**v)

def test_connectivity_state_is_not_a_lifecycle():
    v=values(); v["lifecycle_status"]="ONLINE"
    with pytest.raises(DeviceManagementValidationError,match="valid device lifecycle"):
        validate_device_submission(**v)

from src.device_management import validate_device_lifecycle_update


def test_device_creation_cannot_start_active():
    v = values(); v["lifecycle_status"] = "ACTIVE"
    with pytest.raises(DeviceManagementValidationError, match="commissioning action"):
        validate_device_submission(**v)


def test_unassigned_is_a_valid_lifecycle_update():
    payload = validate_device_lifecycle_update(
        lifecycle_status=" unassigned ", change_reason="Awaiting asset assignment"
    )
    assert payload == {
        "lifecycle_status": "UNASSIGNED",
        "change_reason": "Awaiting asset assignment",
    }


def test_lifecycle_update_rejects_active():
    with pytest.raises(DeviceManagementValidationError, match="commissioning action"):
        validate_device_lifecycle_update(lifecycle_status="ACTIVE")


def test_lifecycle_update_rejects_connectivity_state():
    with pytest.raises(DeviceManagementValidationError, match="valid device lifecycle"):
        validate_device_lifecycle_update(lifecycle_status="ONLINE")


def test_lifecycle_update_rejects_long_reason():
    with pytest.raises(DeviceManagementValidationError, match="must not exceed 500"):
        validate_device_lifecycle_update(
            lifecycle_status="INACTIVE", change_reason="x" * 501
        )
