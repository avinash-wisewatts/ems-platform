from uuid import uuid4

import pytest

from src.gateway_management import (
    GatewayManagementValidationError,
    validate_gateway_submission,
)


def valid_values() -> dict[str, str]:
    return {
        "organization_id": str(uuid4()),
        "site_id": str(uuid4()),
        "gateway_name": "Roof Gateway",
        "external_id": "gw_001",
        "gateway_model_id": str(uuid4()),
        "lifecycle_status": "registered",
        "building_id": "",
        "floor_id": "",
        "space_id": "",
    }


def test_gateway_only_registration_accepts_site_level_location() -> None:
    payload = validate_gateway_submission(**valid_values())
    assert payload["external_id"] == "GW_001"
    assert payload["lifecycle_status"] == "REGISTERED"
    assert payload["building_id"] is None
    assert payload["floor_id"] is None
    assert payload["space_id"] is None


def test_gateway_location_accepts_complete_hierarchy() -> None:
    values = valid_values()
    values.update(
        building_id=str(uuid4()),
        floor_id=str(uuid4()),
        space_id=str(uuid4()),
    )
    payload = validate_gateway_submission(**values)
    assert payload["building_id"] == values["building_id"]
    assert payload["floor_id"] == values["floor_id"]
    assert payload["space_id"] == values["space_id"]


def test_gateway_location_rejects_space_without_floor() -> None:
    values = valid_values()
    values["space_id"] = str(uuid4())
    with pytest.raises(
        GatewayManagementValidationError,
        match="space requires its floor",
    ):
        validate_gateway_submission(**values)


def test_gateway_external_id_rejects_invalid_characters() -> None:
    values = valid_values()
    values["external_id"] = "GW-001"
    with pytest.raises(
        GatewayManagementValidationError,
        match="letters, numbers, and underscores",
    ):
        validate_gateway_submission(**values)


def test_gateway_lifecycle_is_explicit_and_controlled() -> None:
    values = valid_values()
    values["lifecycle_status"] = "ONLINE"
    with pytest.raises(
        GatewayManagementValidationError,
        match="valid gateway lifecycle",
    ):
        validate_gateway_submission(**values)

from src.gateway_management import validate_gateway_lifecycle_update


def test_gateway_lifecycle_update_normalizes_status_and_reason() -> None:
    payload = validate_gateway_lifecycle_update(
        lifecycle_status=" commissioning ", change_reason=" Network setup "
    )
    assert payload == {
        "lifecycle_status": "COMMISSIONING",
        "change_reason": "Network setup",
    }


def test_gateway_lifecycle_update_rejects_connectivity_state() -> None:
    with pytest.raises(
        GatewayManagementValidationError,
        match="valid gateway lifecycle",
    ):
        validate_gateway_lifecycle_update(lifecycle_status="OFFLINE")


def test_gateway_lifecycle_update_rejects_long_reason() -> None:
    with pytest.raises(
        GatewayManagementValidationError,
        match="must not exceed 500",
    ):
        validate_gateway_lifecycle_update(
            lifecycle_status="INACTIVE", change_reason="x" * 501
        )
