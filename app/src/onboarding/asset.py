import re
from typing import Any
from uuid import UUID

from src.code_generation import generate_entity_code

from src.onboarding.statuses import status_codes


METERING_REQUIREMENTS = status_codes("METERING_REQUIREMENT")

ASSET_LIFECYCLE_STATUSES = {
    "DRAFT",
    "COMMISSIONING",
    "ACTIVE",
    "INACTIVE",
    "DECOMMISSIONED",
}

ASSET_EXTERNAL_ID_PATTERN = re.compile(
    r"^[A-Z0-9][A-Z0-9_]*$"
)


RELATIONSHIPS_BY_CATEGORY = {
    "Energy Meter": {
        "PRIMARY_METER",
        "SECONDARY_METER",
    },
    "Environmental Sensor": {
        "TEMPERATURE_SENSOR",
        "HUMIDITY_SENSOR",
    },
    "Temperature Sensor": {
        "TEMPERATURE_SENSOR",
    },
    "Flow Meter": {
        "FLOW_SENSOR",
    },
    "Pressure Sensor": {
        "PRESSURE_SENSOR",
    },
    "Digital Input Module": {
        "STATUS_INPUT",
        "RUN_STATUS",
        "FAULT_STATUS",
    },
    "BMS Controller": {
        "CONTROLLER",
    },
    "PLC": {
        "CONTROLLER",
        "STATUS_INPUT",
        "RUN_STATUS",
        "FAULT_STATUS",
    },
}


class AssetStepValidationError(ValueError):
    """Validation failure for the Asset onboarding step."""


def allowed_relationships(
    device_category_name: str,
) -> list[str]:
    """Return ordered relationships allowed for a device category."""

    allowed = RELATIONSHIPS_BY_CATEGORY.get(
        device_category_name,
        set(),
    )

    preferred_order = [
        "PRIMARY_METER",
        "SECONDARY_METER",
        "TEMPERATURE_SENSOR",
        "HUMIDITY_SENSOR",
        "FLOW_SENSOR",
        "PRESSURE_SENSOR",
        "STATUS_INPUT",
        "RUN_STATUS",
        "FAULT_STATUS",
        "CONTROLLER",
    ]

    return [
        relationship
        for relationship in preferred_order
        if relationship in allowed
    ]


def validate_asset_step(
    *,
    asset_mode: str,
    existing_asset_id: str,
    asset_name: str,
    asset_external_id: str,
    asset_type_id: str,
    metering_requirement: str,
    relationship_type: str,
    operational_notes: str,
    device_category_name: str,
    organization_mode: str,
    site_mode: str,
    lifecycle_status: str = "ACTIVE",
    parent_asset_id: str = "",
) -> dict[str, Any]:
    """Validate and normalize the Asset wizard step."""

    mode = asset_mode.strip().upper()
    organization_parent_mode = (
        organization_mode.strip().upper()
    )
    site_parent_mode = site_mode.strip().upper()
    category_name = device_category_name.strip()

    if mode not in {"CREATE_NEW", "USE_EXISTING"}:
        raise AssetStepValidationError(
            "Select whether to use an existing asset or create one."
        )

    permitted_relationships = allowed_relationships(
        category_name
    )

    if not permitted_relationships:
        raise AssetStepValidationError(
            "No asset relationship rules are configured for device "
            f"category {category_name or 'Unknown'}."
        )

    normalized_relationship = (
        relationship_type.strip().upper()
    )

    if normalized_relationship not in permitted_relationships:
        raise AssetStepValidationError(
            "The selected relationship is not valid for device "
            f"category {category_name}."
        )

    notes = operational_notes.strip()

    if len(notes) > 2000:
        raise AssetStepValidationError(
            "Operational notes must not exceed 2,000 characters."
        )

    if mode == "USE_EXISTING":
        if (
            organization_parent_mode != "USE_EXISTING"
            or site_parent_mode != "USE_EXISTING"
        ):
            raise AssetStepValidationError(
                "An existing asset can only be selected when both the "
                "organization and site already exist."
            )

        try:
            selected_asset_id = str(
                UUID(existing_asset_id.strip())
            )
        except ValueError as exc:
            raise AssetStepValidationError(
                "Select an existing asset."
            ) from exc

        return {
            "mode": "USE_EXISTING",
            "existing_asset_id": selected_asset_id,
            "name": None,
            "external_id": None,
            "asset_type_id": None,
            "metering_requirement": None,
            "relationship_type": normalized_relationship,
            "metadata": {},
            "lifecycle_status": None,
            "parent_asset_id": None,
        }

    normalized_metering_requirement = (
        metering_requirement.strip().upper()
    )

    if normalized_metering_requirement not in METERING_REQUIREMENTS:
        raise AssetStepValidationError(
            "Select how this asset must obtain energy-meter coverage."
        )

    name = asset_name.strip()

    if not name:
        raise AssetStepValidationError(
            "Asset name is required."
        )

    if len(name) > 200:
        raise AssetStepValidationError(
            "Asset name must not exceed 200 characters."
        )

    external_id = generate_entity_code(name)

    if not external_id:
        raise AssetStepValidationError(
            "Asset name must contain at least one letter or number."
        )

    try:
        normalized_asset_type_id = str(
            UUID(asset_type_id.strip())
        )
    except ValueError as exc:
        raise AssetStepValidationError(
            "Select an asset type."
        ) from exc

    metadata: dict[str, Any] = {}

    if notes:
        metadata["operational_notes"] = notes

    normalized_lifecycle_status = (
        lifecycle_status.strip().upper() or "ACTIVE"
    )

    if normalized_lifecycle_status not in ASSET_LIFECYCLE_STATUSES:
        raise AssetStepValidationError(
            "Select a valid asset lifecycle status."
        )

    normalized_parent_asset_id: str | None = None

    if parent_asset_id.strip():
        try:
            normalized_parent_asset_id = str(
                UUID(parent_asset_id.strip())
            )
        except ValueError as exc:
            raise AssetStepValidationError(
                "Select a valid parent asset."
            ) from exc

    return {
        "mode": "CREATE_NEW",
        "existing_asset_id": None,
        "name": name,
        "external_id": external_id,
        "asset_type_id": normalized_asset_type_id,
        "metering_requirement": normalized_metering_requirement,
        "relationship_type": normalized_relationship,
        "metadata": metadata,
        "lifecycle_status": normalized_lifecycle_status,
        "parent_asset_id": normalized_parent_asset_id,
    }
