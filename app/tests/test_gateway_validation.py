from uuid import uuid4

import pytest

from src.onboarding.gateway import (
    GatewayStepValidationError,
    validate_gateway_step,
)


def valid_gateway_values() -> dict[str, str]:
    return {
        "gateway_mode": "CREATE_NEW",
        "existing_gateway_id": "",
        "gateway_name": "Eniscope Gateway 1",
        "gateway_external_id": "gateway_001",
        "gateway_vendor": "Best Energy",
        "gateway_model": "Eniscope Hybrid",
        "gateway_protocol": "mqtt",
        "organization_mode": "CREATE_NEW",
        "site_mode": "CREATE_NEW",
    }



def test_create_gateway_normalizes_values() -> None:
    values = valid_gateway_values()
    values["gateway_external_id"] = "FORGED_CLIENT_VALUE"

    payload = validate_gateway_step(**values)

    assert payload == {
        "mode": "CREATE_NEW",
        "existing_gateway_id": None,
        "name": "Eniscope Gateway 1",
        "external_id": "ENISCOPE_GATEWAY_1",
        "vendor": "Best Energy",
        "model": "Eniscope Hybrid",
        "protocol": "MQTT",
    }

@pytest.mark.parametrize(
    "protocol",
    [
        "MQTT",
        "HTTP API",
        "OPC-UA",
    ],
)
def test_supported_gateway_protocols_are_accepted(
    protocol: str,
) -> None:
    values = valid_gateway_values()
    values["gateway_protocol"] = protocol

    assert validate_gateway_step(**values)["protocol"] == protocol


@pytest.mark.parametrize(
    "protocol",
    [
        "",
        "MODBUS TCP",
        "BACNET",
        "COAP",
    ],
)
def test_unsupported_gateway_protocol_is_rejected(
    protocol: str,
) -> None:
    values = valid_gateway_values()
    values["gateway_protocol"] = protocol

    with pytest.raises(
        GatewayStepValidationError,
        match="supported cloud uplink protocol",
    ):
        validate_gateway_step(**values)


def test_existing_gateway_requires_existing_parents() -> None:
    values = valid_gateway_values()
    values.update(
        {
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": str(uuid4()),
            "organization_mode": "CREATE_NEW",
            "site_mode": "CREATE_NEW",
        }
    )

    with pytest.raises(
        GatewayStepValidationError,
        match="both the organization and site already exist",
    ):
        validate_gateway_step(**values)


def test_existing_gateway_is_accepted_for_existing_parents() -> None:
    gateway_id = str(uuid4())
    values = valid_gateway_values()
    values.update(
        {
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": gateway_id,
            "organization_mode": "USE_EXISTING",
            "site_mode": "USE_EXISTING",
        }
    )

    payload = validate_gateway_step(**values)

    assert payload == {
        "mode": "USE_EXISTING",
        "existing_gateway_id": gateway_id,
        "name": None,
        "external_id": None,
        "vendor": None,
        "model": None,
        "protocol": None,
    }



def test_client_gateway_external_id_is_ignored() -> None:
    values = valid_gateway_values()
    values["gateway_external_id"] = "FORGED-CLIENT VALUE"

    payload = validate_gateway_step(**values)

    assert payload["external_id"] == "ENISCOPE_GATEWAY_1"

