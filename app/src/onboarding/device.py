import re
from typing import Any
from uuid import UUID

from src.code_generation import generate_entity_code


DEVICE_EXTERNAL_ID_PATTERN = re.compile(r"^[A-Z0-9_]+$")

MQTT_UID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){7}$"
)

ALLOWED_DEVICE_PROTOCOLS = {
    "MQTT",
    "MODBUS TCP",
    "MODBUS RTU",
    "BACNET IP",
    "BACNET MS/TP",
    "OPC-UA",
    "HTTP API",
}

ALLOWED_OPERATIONAL_POLICIES = {
    "ASSET_ASSIGNED",
    "STANDALONE",
}


class DeviceStepValidationError(ValueError):
    """Validation failure for the Device onboarding step."""


def validate_device_step(
    *,
    device_mode: str,
    existing_device_id: str,
    device_name: str,
    device_external_id: str,
    device_category_id: str,
    device_model_id: str,
    device_protocol: str,
    profile_code: str,
    firmware_version: str,
    identifier_type: str,
    identifier_value: str,
    gateway_mode: str,
    serial_number: str = "",
    operational_policy: str = "ASSET_ASSIGNED",
) -> dict[str, Any]:
    """Validate and normalize the Device wizard step."""

    mode = device_mode.strip().upper()
    parent_gateway_mode = gateway_mode.strip().upper()

    if mode not in {"CREATE_NEW", "USE_EXISTING"}:
        raise DeviceStepValidationError(
            "Select whether to use an existing device or create one."
        )

    if mode == "USE_EXISTING":
        if parent_gateway_mode != "USE_EXISTING":
            raise DeviceStepValidationError(
                "An existing device can only be selected when the "
                "gateway already exists."
            )

        try:
            selected_device_id = str(
                UUID(existing_device_id.strip())
            )
        except ValueError as exc:
            raise DeviceStepValidationError(
                "Select an existing device."
            ) from exc

        # Existing device identity is loaded from the database by the
        # route after access and gateway ownership are verified. Any
        # client-submitted identifier fields are intentionally ignored.

        return {
            "mode": "USE_EXISTING",
            "existing_device_id": selected_device_id,
            "name": None,
            "external_id": None,
            "device_category_id": None,
            "device_model_id": None,
            "protocol": None,
            "profile_code": None,
            "firmware_version": None,
            "serial_number": None,
            "operational_policy": None,
            "identifier": {
                "type": None,
                "value": None,
            },
        }

    name = device_name.strip()
    protocol = device_protocol.strip().upper()
    normalized_profile_code = profile_code.strip().upper()
    firmware = firmware_version.strip()
    normalized_identifier_type = (
        identifier_type.strip().upper()
    )
    normalized_identifier_value = identifier_value.strip()

    if not name:
        raise DeviceStepValidationError(
            "Device name is required."
        )

    if len(name) > 200:
        raise DeviceStepValidationError(
            "Device name must not exceed 200 characters."
        )

    external_id = generate_entity_code(name)

    if not external_id:
        raise DeviceStepValidationError(
            "Device name must contain at least one letter or number."
        )

    try:
        normalized_category_id = str(
            UUID(device_category_id.strip())
        )
    except ValueError as exc:
        raise DeviceStepValidationError(
            "Select a controlled device category."
        ) from exc

    try:
        normalized_device_model_id = str(
            UUID(device_model_id.strip())
        )
    except ValueError as exc:
        raise DeviceStepValidationError(
            "Select a device model from the catalog."
        ) from exc

    if protocol not in ALLOWED_DEVICE_PROTOCOLS:
        raise DeviceStepValidationError(
            "Select a supported device communication protocol."
        )

    if not normalized_profile_code:
        raise DeviceStepValidationError(
            "Select a compatible telemetry profile."
        )

    normalized_serial_number = serial_number.strip()
    normalized_operational_policy = (
        operational_policy.strip().upper() or "ASSET_ASSIGNED"
    )

    if normalized_operational_policy not in ALLOWED_OPERATIONAL_POLICIES:
        raise DeviceStepValidationError(
            "Select a valid asset-assignment requirement."
        )

    if not normalized_identifier_type:
        raise DeviceStepValidationError(
            "Identifier type is required for a new device."
        )

    if not normalized_identifier_value:
        raise DeviceStepValidationError(
            "Identifier value is required for a new device."
        )

    if normalized_identifier_type == "MQTT_UID":
        if not MQTT_UID_PATTERN.fullmatch(
            normalized_identifier_value
        ):
            raise DeviceStepValidationError(
                "MQTT UID must contain eight hexadecimal byte pairs "
                "separated by colons."
            )

        normalized_identifier_value = (
            normalized_identifier_value.lower()
        )

    return {
        "mode": "CREATE_NEW",
        "existing_device_id": None,
        "name": name,
        "external_id": external_id,
        "device_category_id": normalized_category_id,
        "device_model_id": normalized_device_model_id,
        "protocol": protocol,
        "profile_code": normalized_profile_code,
        "firmware_version": firmware or None,
        "serial_number": normalized_serial_number or None,
        "operational_policy": normalized_operational_policy,
        "identifier": {
            "type": normalized_identifier_type,
            "value": normalized_identifier_value,
        },
    }
