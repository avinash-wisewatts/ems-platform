"""Validation for independent asset administration."""

from typing import Any
from uuid import UUID

from src.onboarding.statuses import status_codes


ASSET_LIFECYCLE_STATUSES = status_codes(
    "ASSET_LIFECYCLE"
)
METERING_REQUIREMENTS = status_codes(
    "METERING_REQUIREMENT"
)


class AssetManagementValidationError(ValueError):
    """Validation failure for independent asset administration."""


def _required_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except ValueError as exc:
        raise AssetManagementValidationError(
            f"{label} is required."
        ) from exc


def _required_selection_uuid(
    value: str,
    label: str,
) -> str:
    normalized = value.strip()

    if not normalized:
        raise AssetManagementValidationError(
            f"{label} is required."
        )

    try:
        return str(UUID(normalized))
    except ValueError as exc:
        raise AssetManagementValidationError(
            f"Select a valid {label.lower()}."
        ) from exc


def _optional_uuid(value: str, label: str) -> str | None:
    normalized = value.strip()

    if not normalized:
        return None

    try:
        return str(UUID(normalized))
    except ValueError as exc:
        raise AssetManagementValidationError(
            f"Select a valid {label.lower()}."
        ) from exc


def validate_asset_submission(
    *,
    organization_id: str,
    site_id: str,
    asset_name: str,
    asset_type_id: str,
    lifecycle_status: str,
    metering_requirement: str,
    parent_asset_id: str,
    building_id: str,
    floor_id: str,
    space_id: str,
) -> dict[str, Any]:
    """Validate and normalize an independent asset request."""

    name = asset_name.strip()

    if not name:
        raise AssetManagementValidationError(
            "Asset name is required."
        )

    if len(name) > 200:
        raise AssetManagementValidationError(
            "Asset name must not exceed 200 characters."
        )

    normalized_lifecycle = lifecycle_status.strip().upper()

    if normalized_lifecycle not in ASSET_LIFECYCLE_STATUSES:
        raise AssetManagementValidationError(
            "Select a valid asset lifecycle status."
        )

    normalized_metering = metering_requirement.strip().upper()

    if normalized_metering not in METERING_REQUIREMENTS:
        raise AssetManagementValidationError(
            "Select a valid metering requirement."
        )

    normalized_building = _optional_uuid(
        building_id,
        "building",
    )
    normalized_floor = _optional_uuid(
        floor_id,
        "floor",
    )
    normalized_space = _optional_uuid(
        space_id,
        "space",
    )

    if normalized_space and not normalized_floor:
        raise AssetManagementValidationError(
            "A selected space requires its floor."
        )

    if normalized_floor and not normalized_building:
        raise AssetManagementValidationError(
            "A selected floor requires its building."
        )

    return {
        "organization_id": _required_uuid(
            organization_id,
            "Organization",
        ),
        "site_id": _required_uuid(
            site_id,
            "Site",
        ),
        "asset_name": name,
        "asset_type_id": _required_selection_uuid(
            asset_type_id,
            "Asset type",
        ),
        "lifecycle_status": normalized_lifecycle,
        "metering_requirement": normalized_metering,
        "parent_asset_id": _optional_uuid(
            parent_asset_id,
            "parent asset",
        ),
        "building_id": normalized_building,
        "floor_id": normalized_floor,
        "space_id": normalized_space,
    }
