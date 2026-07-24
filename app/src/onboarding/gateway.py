import re
from typing import Any
from uuid import UUID


GATEWAY_EXTERNAL_ID_PATTERN = re.compile(
    r"^[A-Z0-9_]+$"
)

ALLOWED_UPLINK_PROTOCOLS = {
    "MQTT",
    "HTTP API",
    "OPC-UA",
}


class GatewayStepValidationError(ValueError):
    """Validation failure for the Gateway onboarding step."""


def validate_gateway_step(
    *,
    gateway_mode: str,
    existing_gateway_id: str,
    gateway_name: str,
    gateway_external_id: str,
    gateway_vendor: str,
    gateway_model: str,
    gateway_protocol: str,
    organization_mode: str,
    site_mode: str,
) -> dict[str, Any]:
    """
    Validate and normalize the Gateway wizard step.

    Existing gateways are available only when both the selected organization
    and site already exist in production metadata.
    """

    mode = gateway_mode.strip().upper()
    parent_organization_mode = organization_mode.strip().upper()
    parent_site_mode = site_mode.strip().upper()

    if mode not in {"CREATE_NEW", "USE_EXISTING"}:
        raise GatewayStepValidationError(
            "Select whether to use an existing gateway or create one."
        )

    if mode == "USE_EXISTING":
        if (
            parent_organization_mode != "USE_EXISTING"
            or parent_site_mode != "USE_EXISTING"
        ):
            raise GatewayStepValidationError(
                "An existing gateway can only be selected when both the "
                "organization and site already exist."
            )

        try:
            gateway_id = str(
                UUID(existing_gateway_id.strip())
            )
        except ValueError as exc:
            raise GatewayStepValidationError(
                "Select an existing gateway."
            ) from exc

        return {
            "mode": "USE_EXISTING",
            "existing_gateway_id": gateway_id,
            "name": None,
            "external_id": None,
            "vendor": None,
            "model": None,
            "protocol": None,
        }

    name = gateway_name.strip()
    external_id = gateway_external_id.strip().upper()
    vendor = gateway_vendor.strip()
    model = gateway_model.strip()
    protocol = gateway_protocol.strip().upper()

    if not name:
        raise GatewayStepValidationError(
            "Gateway name is required."
        )

    if len(name) > 200:
        raise GatewayStepValidationError(
            "Gateway name must not exceed 200 characters."
        )

    if not external_id:
        raise GatewayStepValidationError(
            "Gateway external ID is required."
        )

    if len(external_id) > 100:
        raise GatewayStepValidationError(
            "Gateway external ID must not exceed 100 characters."
        )

    if not GATEWAY_EXTERNAL_ID_PATTERN.fullmatch(
        external_id
    ):
        raise GatewayStepValidationError(
            "Gateway external ID may contain only A-Z, 0-9, "
            "and underscore."
        )

    if not vendor:
        raise GatewayStepValidationError(
            "Gateway manufacturer is required."
        )

    if len(vendor) > 200:
        raise GatewayStepValidationError(
            "Gateway manufacturer must not exceed 200 characters."
        )

    if not model:
        raise GatewayStepValidationError(
            "Gateway model is required."
        )

    if len(model) > 200:
        raise GatewayStepValidationError(
            "Gateway model must not exceed 200 characters."
        )

    if protocol not in ALLOWED_UPLINK_PROTOCOLS:
        raise GatewayStepValidationError(
            "Select a supported cloud uplink protocol."
        )

    return {
        "mode": "CREATE_NEW",
        "existing_gateway_id": None,
        "name": name,
        "external_id": external_id,
        "vendor": vendor,
        "model": model,
        "protocol": protocol,
    }
