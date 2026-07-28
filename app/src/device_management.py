"""Validation for independent device administration."""

import re
from typing import Any
from uuid import UUID

from src.onboarding.statuses import status_codes

DEVICE_LIFECYCLE_STATUSES = status_codes("DEVICE_LIFECYCLE")
DEVICE_PROTOCOLS = (
    "MQTT", "MODBUS TCP", "MODBUS RTU", "BACNET IP", "BACNET MS/TP",
    "OPC-UA", "HTTP API",
)
_EXTERNAL_ID = re.compile(r"^[A-Z0-9_]+$")


class DeviceManagementValidationError(ValueError):
    """Validation failure for independent device administration."""


def _required_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except ValueError as exc:
        raise DeviceManagementValidationError(f"{label} is required.") from exc


def _optional_uuid(value: str, label: str) -> str | None:
    normalized = value.strip()
    if not normalized:
        return None
    try:
        return str(UUID(normalized))
    except ValueError as exc:
        raise DeviceManagementValidationError(
            f"Select a valid {label.lower()}."
        ) from exc


def validate_device_submission(
    *, gateway_id: str, device_name: str, external_id: str,
    device_category_id: str, device_model_id: str, profile_id: str,
    protocol: str, lifecycle_status: str, firmware_version: str,
    use_gateway_location: str, building_id: str, floor_id: str, space_id: str,
) -> dict[str, Any]:
    """Validate a device-only registration request."""
    name = device_name.strip()
    if not name:
        raise DeviceManagementValidationError("Device name is required.")
    if len(name) > 200:
        raise DeviceManagementValidationError(
            "Device name must not exceed 200 characters."
        )

    normalized_external_id = external_id.strip().upper()
    if not normalized_external_id:
        raise DeviceManagementValidationError("Device external ID is required.")
    if len(normalized_external_id) > 100:
        raise DeviceManagementValidationError(
            "Device external ID must not exceed 100 characters."
        )
    if not _EXTERNAL_ID.fullmatch(normalized_external_id):
        raise DeviceManagementValidationError(
            "Device external ID may contain only letters, numbers, and underscores."
        )

    normalized_protocol = protocol.strip().upper()
    if normalized_protocol not in DEVICE_PROTOCOLS:
        raise DeviceManagementValidationError(
            "Select a supported device communication protocol."
        )
    lifecycle = lifecycle_status.strip().upper()
    if lifecycle not in DEVICE_LIFECYCLE_STATUSES:
        raise DeviceManagementValidationError(
            "Select a valid device lifecycle status."
        )
    if lifecycle == "ACTIVE":
        raise DeviceManagementValidationError(
            "Use the controlled commissioning action to activate a device."
        )

    inherit = use_gateway_location.strip().lower() in {"1", "true", "on", "yes"}
    building = _optional_uuid(building_id, "building")
    floor = _optional_uuid(floor_id, "floor")
    space = _optional_uuid(space_id, "space")
    if inherit and any((building, floor, space)):
        raise DeviceManagementValidationError(
            "Clear the device location when using the gateway location."
        )
    if space and not floor:
        raise DeviceManagementValidationError("A selected space requires its floor.")
    if floor and not building:
        raise DeviceManagementValidationError("A selected floor requires its building.")

    firmware = firmware_version.strip()
    if len(firmware) > 100:
        raise DeviceManagementValidationError(
            "Firmware version must not exceed 100 characters."
        )

    return {
        "gateway_id": _required_uuid(gateway_id, "Gateway"),
        "device_name": name,
        "external_id": normalized_external_id,
        "device_category_id": _required_uuid(device_category_id, "Device category"),
        "device_model_id": _required_uuid(device_model_id, "Device model"),
        "profile_id": _required_uuid(profile_id, "Device profile"),
        "protocol": normalized_protocol,
        "lifecycle_status": lifecycle,
        "firmware_version": firmware or None,
        "use_gateway_location": inherit,
        "building_id": building,
        "floor_id": floor,
        "space_id": space,
    }


def validate_device_lifecycle_update(
    *, lifecycle_status: str, change_reason: str = ""
) -> dict[str, str | None]:
    """Validate an explicit device lifecycle change request."""
    lifecycle = lifecycle_status.strip().upper()
    if lifecycle not in DEVICE_LIFECYCLE_STATUSES:
        raise DeviceManagementValidationError(
            "Select a valid device lifecycle status."
        )
    if lifecycle == "ACTIVE":
        raise DeviceManagementValidationError(
            "Use the controlled commissioning action to activate a device."
        )
    reason = change_reason.strip()
    if len(reason) > 500:
        raise DeviceManagementValidationError(
            "Change reason must not exceed 500 characters."
        )
    return {
        "lifecycle_status": lifecycle,
        "change_reason": reason or None,
    }
