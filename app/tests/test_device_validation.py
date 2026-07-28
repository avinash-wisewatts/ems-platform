from uuid import uuid4

import pytest

from src.onboarding.device import (
    DeviceStepValidationError,
    validate_device_step,
)


def valid_create_device_input() -> dict[str, str]:
    return {
        "device_mode": "CREATE_NEW",
        "existing_device_id": "",
        "device_name": "Chiller Meter 1",
        "device_external_id": "eni demo 001",
        "device_category_id": str(uuid4()),
        "device_vendor": "Best Energy",
        "device_model": "Eniscope 8",
        "device_protocol": "mqtt",
        "profile_code": "eniscope_v4",
        "firmware_version": "4.2.1",
        "identifier_type": "mqtt_uid",
        "identifier_value": "80:34:28:16:09:EB:00:01",
        "gateway_mode": "CREATE_NEW",
    }



def test_create_device_normalizes_controlled_values() -> None:
    values = valid_create_device_input()
    values["device_external_id"] = "FORGED_CLIENT_VALUE"

    payload = validate_device_step(**values)

    assert payload["mode"] == "CREATE_NEW"
    assert payload["name"] == "Chiller Meter 1"
    assert payload["external_id"] == "CHILLER_METER_1"
    assert payload["protocol"] == "MQTT"
    assert payload["profile_code"] == "ENISCOPE_V4"
    assert payload["firmware_version"] == "4.2.1"
    assert payload["identifier"] == {
        "type": "MQTT_UID",
        "value": "80:34:28:16:09:eb:00:01",
    }

def test_blank_firmware_becomes_none() -> None:
    values = valid_create_device_input()
    values["device_external_id"] = "ENI_DEMO_001"
    values["firmware_version"] = "   "

    payload = validate_device_step(**values)

    assert payload["firmware_version"] is None



def test_client_device_external_id_is_ignored() -> None:
    values = valid_create_device_input()
    values["device_external_id"] = "FORGED-CLIENT VALUE"

    payload = validate_device_step(**values)

    assert payload["external_id"] == "CHILLER_METER_1"

@pytest.mark.parametrize(
    "protocol",
    [
        "",
        "COAP",
        "BACNET",
        "MODBUS",
    ],
)
def test_unsupported_device_protocol_is_rejected(
    protocol: str,
) -> None:
    values = valid_create_device_input()
    values["device_external_id"] = "ENI_DEMO_001"
    values["device_protocol"] = protocol

    with pytest.raises(
        DeviceStepValidationError,
        match="supported device communication protocol",
    ):
        validate_device_step(**values)


@pytest.mark.parametrize(
    "mqtt_uid",
    [
        "",
        "80:34:28",
        "80-34-28-16-09-eb-00-01",
        "GG:34:28:16:09:eb:00:01",
        "80:34:28:16:09:eb:00:01:02",
    ],
)
def test_invalid_mqtt_uid_is_rejected(
    mqtt_uid: str,
) -> None:
    values = valid_create_device_input()
    values["device_external_id"] = "ENI_DEMO_001"
    values["identifier_value"] = mqtt_uid

    expected_message = (
        "Identifier value is required"
        if not mqtt_uid
        else "MQTT UID must contain"
    )

    with pytest.raises(
        DeviceStepValidationError,
        match=expected_message,
    ):
        validate_device_step(**values)


def test_existing_device_requires_existing_gateway() -> None:
    values = valid_create_device_input()
    values.update(
        {
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(uuid4()),
            "gateway_mode": "CREATE_NEW",
        }
    )

    with pytest.raises(
        DeviceStepValidationError,
        match="gateway already exists",
    ):
        validate_device_step(**values)


def test_existing_device_ignores_client_identifier_fields() -> None:
    existing_device_id = str(uuid4())

    values = valid_create_device_input()
    values.update(
        {
            "device_mode": "USE_EXISTING",
            "existing_device_id": existing_device_id,
            "gateway_mode": "USE_EXISTING",
            "identifier_type": "FORGED_TYPE",
            "identifier_value": "forged-value",
        }
    )

    payload = validate_device_step(**values)

    assert payload == {
        "mode": "USE_EXISTING",
        "existing_device_id": existing_device_id,
        "name": None,
        "external_id": None,
        "device_category_id": None,
        "model_vendor": None,
        "model": None,
        "protocol": None,
        "profile_code": None,
        "firmware_version": None,
        "identifier": {
            "type": None,
            "value": None,
        },
    }


def test_existing_device_accepts_missing_client_identifier_fields() -> None:
    values = valid_create_device_input()
    values.update(
        {
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(uuid4()),
            "gateway_mode": "USE_EXISTING",
            "identifier_type": "",
            "identifier_value": "",
        }
    )

    payload = validate_device_step(**values)

    assert payload["identifier"] == {
        "type": None,
        "value": None,
    }
