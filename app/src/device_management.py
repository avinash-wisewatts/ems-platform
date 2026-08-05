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
DEVICE_IDENTIFIER_TYPES = ("MQTT_UID",)
DEVICE_OPERATIONAL_POLICIES = ("STANDALONE", "ASSET_ASSIGNED")
_EXTERNAL_ID = re.compile(r"^[A-Z0-9_]+$")
_MQTT_UID = re.compile(r"^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){7}$")


class DeviceManagementValidationError(ValueError):
    """Validation failure for independent device administration."""


def _required_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except (AttributeError, ValueError) as exc:
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


def _normalize_identifier(identifier_type: str, identifier_value: str) -> tuple[str, str]:
    normalized_type = identifier_type.strip().upper()
    if normalized_type not in DEVICE_IDENTIFIER_TYPES:
        raise DeviceManagementValidationError("Select a supported device identifier type.")
    normalized_value = identifier_value.strip()
    if not normalized_value:
        raise DeviceManagementValidationError("Device identifier value is required.")
    if len(normalized_value) > 255:
        raise DeviceManagementValidationError(
            "Device identifier value must not exceed 255 characters."
        )
    if normalized_type == "MQTT_UID":
        if not _MQTT_UID.fullmatch(normalized_value):
            raise DeviceManagementValidationError(
                "MQTT UID must contain eight hexadecimal byte pairs separated by colons."
            )
        normalized_value = normalized_value.lower()
    return normalized_type, normalized_value


def _normalize_location(
    *, use_gateway_location: str, building_id: str, floor_id: str, space_id: str
) -> tuple[bool, str | None, str | None, str | None]:
    inherit = use_gateway_location.strip().lower() in {"1", "true", "on", "yes"}
    building = _optional_uuid(building_id, "building")
    floor = _optional_uuid(floor_id, "floor")
    space = _optional_uuid(space_id, "space")
    if inherit:
        # Inheritance is authoritative. Ignore any stale browser values so the
        # server cannot accidentally persist an explicit override.
        return True, None, None, None
    if space and not floor:
        raise DeviceManagementValidationError("A selected space requires its floor.")
    if floor and not building:
        raise DeviceManagementValidationError("A selected floor requires its building.")
    return inherit, building, floor, space


def validate_device_submission(
    *, gateway_id: str, device_name: str, external_id: str,
    device_category_id: str, device_model_id: str, profile_id: str,
    protocol: str, lifecycle_status: str, firmware_version: str,
    serial_number: str, identifier_type: str, identifier_value: str,
    use_gateway_location: str, building_id: str, floor_id: str, space_id: str,
    operational_policy: str,
) -> dict[str, Any]:
    """Validate a device registration request including telemetry identity."""
    name = device_name.strip()
    if not name:
        raise DeviceManagementValidationError("Device name is required.")
    if len(name) > 200:
        raise DeviceManagementValidationError(
            "Device name must not exceed 200 characters."
        )

    # External IDs are system-managed. Use a submitted base when present and
    # otherwise derive one from the device name. The database performs the
    # final organization-scoped conflict resolution atomically.
    normalized_external_id = external_id.strip().upper()
    if not normalized_external_id:
        normalized_external_id = re.sub(r"[^A-Z0-9]+", "_", name.upper()).strip("_") or "DEVICE"
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

    firmware = firmware_version.strip()
    serial = serial_number.strip()
    if len(firmware) > 100:
        raise DeviceManagementValidationError(
            "Firmware version must not exceed 100 characters."
        )
    if len(serial) > 200:
        raise DeviceManagementValidationError(
            "Serial number must not exceed 200 characters."
        )

    policy = operational_policy.strip().upper()
    if policy not in DEVICE_OPERATIONAL_POLICIES:
        raise DeviceManagementValidationError(
            "Select a valid operational policy."
        )
    normalized_identifier_type, normalized_identifier_value = _normalize_identifier(
        identifier_type, identifier_value
    )
    inherit, building, floor, space = _normalize_location(
        use_gateway_location=use_gateway_location,
        building_id=building_id,
        floor_id=floor_id,
        space_id=space_id,
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
        "serial_number": serial or None,
        "identifier_type": normalized_identifier_type,
        "identifier_value": normalized_identifier_value,
        "operational_policy": policy,
        "use_gateway_location": inherit,
        "building_id": building,
        "floor_id": floor,
        "space_id": space,
    }


def validate_device_workspace_update(
    *, device_name: str, device_category_id: str, device_model_id: str,
    profile_id: str, protocol: str, lifecycle_status: str,
    firmware_version: str, serial_number: str, identifier_type: str,
    identifier_value: str, use_gateway_location: str, building_id: str,
    floor_id: str, space_id: str, operational_policy: str, change_reason: str,
) -> dict[str, Any]:
    """Validate an audited device workspace update."""
    name = device_name.strip()
    if not name:
        raise DeviceManagementValidationError("Device name is required.")
    if len(name) > 200:
        raise DeviceManagementValidationError(
            "Device name must not exceed 200 characters."
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
    firmware = firmware_version.strip()
    serial = serial_number.strip()
    if len(firmware) > 100:
        raise DeviceManagementValidationError(
            "Firmware version must not exceed 100 characters."
        )
    if len(serial) > 200:
        raise DeviceManagementValidationError(
            "Serial number must not exceed 200 characters."
        )
    policy = operational_policy.strip().upper()
    if policy not in DEVICE_OPERATIONAL_POLICIES:
        raise DeviceManagementValidationError(
            "Select a valid operational policy."
        )
    normalized_identifier_type, normalized_identifier_value = _normalize_identifier(
        identifier_type, identifier_value
    )
    inherit, building, floor, space = _normalize_location(
        use_gateway_location=use_gateway_location,
        building_id=building_id,
        floor_id=floor_id,
        space_id=space_id,
    )
    reason = change_reason.strip()
    if not reason:
        raise DeviceManagementValidationError("Change reason is required.")
    if len(reason) > 1000:
        raise DeviceManagementValidationError(
            "Change reason must not exceed 1000 characters."
        )
    return {
        "device_name": name,
        "device_category_id": _required_uuid(device_category_id, "Device category"),
        "device_model_id": _required_uuid(device_model_id, "Device model"),
        "profile_id": _required_uuid(profile_id, "Device profile"),
        "protocol": normalized_protocol,
        "lifecycle_status": lifecycle,
        "firmware_version": firmware or None,
        "serial_number": serial or None,
        "identifier_type": normalized_identifier_type,
        "identifier_value": normalized_identifier_value,
        "operational_policy": policy,
        "use_gateway_location": inherit,
        "building_id": building,
        "floor_id": floor,
        "space_id": space,
        "change_reason": reason,
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
