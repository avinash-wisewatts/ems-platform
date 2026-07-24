import re
from typing import Any
from uuid import UUID


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


class DeviceStepValidationError(ValueError):
    """Validation failure for the Device onboarding step."""


def validate_device_step(
    *,
    device_mode: str,
    existing_device_id: str,
    device_name: str,
    device_external_id: str,
    device_category_id: str,
    device_vendor: str,
    device_model: str,
    device_protocol: str,
    profile_code: str,
    firmware_version: str,
    identifier_type: str,
    identifier_value: str,
    gateway_mode: str,
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

        normalized_identifier_type = (
            identifier_type.strip().upper()
        )
        normalized_identifier_value = (
            identifier_value.strip()
        )

        if bool(normalized_identifier_type) != bool(
            normalized_identifier_value
        ):
            raise DeviceStepValidationError(
                "Identifier type and value must be supplied together."
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
            "mode": "USE_EXISTING",
            "existing_device_id": selected_device_id,
            "name": None,
            "external_id": None,
            "device_category_id": None,
            "model_vendor": None,
            "model": None,
            "protocol": None,
            "profile_code": None,
            "firmware_version": None,
            "identifier": {
                "type": (
                    normalized_identifier_type or None
                ),
                "value": (
                    normalized_identifier_value or None
                ),
            },
        }

    name = device_name.strip()
    external_id = device_external_id.strip().upper()
    vendor = device_vendor.strip()
    model = device_model.strip()
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

    if not external_id:
        raise DeviceStepValidationError(
            "Device external ID is required."
        )

    if len(external_id) > 100:
        raise DeviceStepValidationError(
            "Device external ID must not exceed 100 characters."
        )

    if not DEVICE_EXTERNAL_ID_PATTERN.fullmatch(external_id):
        raise DeviceStepValidationError(
            "Device external ID may contain only A-Z, 0-9, "
            "and underscore."
        )

    try:
        normalized_category_id = str(
            UUID(device_category_id.strip())
        )
    except ValueError as exc:
        raise DeviceStepValidationError(
            "Select a controlled device category."
        ) from exc

    if not vendor:
        raise DeviceStepValidationError(
            "Device manufacturer is required."
        )

    if not model:
        raise DeviceStepValidationError(
            "Device model is required."
        )

    if protocol not in ALLOWED_DEVICE_PROTOCOLS:
        raise DeviceStepValidationError(
            "Select a supported device communication protocol."
        )

    if not normalized_profile_code:
        raise DeviceStepValidationError(
            "Select a compatible telemetry profile."
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
        "model_vendor": vendor,
        "model": model,
        "protocol": protocol,
        "profile_code": normalized_profile_code,
        "firmware_version": firmware or None,
        "identifier": {
            "type": normalized_identifier_type,
            "value": normalized_identifier_value,
        },
    }
