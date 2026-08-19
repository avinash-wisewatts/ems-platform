import re
from typing import Any
from uuid import UUID

from src.code_generation import generate_entity_code


GATEWAY_EXTERNAL_ID_PATTERN = re.compile(
    r"^[A-Z0-9_]+$"
)


class GatewayStepValidationError(ValueError):
    """Validation failure for the Gateway onboarding step."""


def validate_gateway_step(
    *,
    gateway_mode: str,
    existing_gateway_id: str,
    gateway_name: str,
    gateway_external_id: str,
    gateway_model_id: str,
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
            "gateway_model_id": None,
        }

    name = gateway_name.strip()

    if not name:
        raise GatewayStepValidationError(
            "Gateway name is required."
        )

    if len(name) > 200:
        raise GatewayStepValidationError(
            "Gateway name must not exceed 200 characters."
        )

    external_id = generate_entity_code(name)

    if not external_id:
        raise GatewayStepValidationError(
            "Gateway name must contain at least one letter or number."
        )

    try:
        normalized_gateway_model_id = str(
            UUID(gateway_model_id.strip())
        )
    except ValueError as exc:
        raise GatewayStepValidationError(
            "Select a gateway model from the catalog."
        ) from exc

    return {
        "mode": "CREATE_NEW",
        "existing_gateway_id": None,
        "name": name,
        "external_id": external_id,
        "gateway_model_id": normalized_gateway_model_id,
    }
