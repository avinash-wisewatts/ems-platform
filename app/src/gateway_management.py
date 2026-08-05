"""Validation for independent gateway administration."""

import re
from typing import Any
from uuid import UUID

from src.onboarding.statuses import status_codes

GATEWAY_LIFECYCLE_STATUSES = status_codes("GATEWAY_LIFECYCLE")
_EXTERNAL_ID = re.compile(r"^[A-Z0-9_]+$")


class GatewayManagementValidationError(ValueError):
    """Validation failure for independent gateway administration."""


def _required_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except ValueError as exc:
        raise GatewayManagementValidationError(f"{label} is required.") from exc


def _optional_uuid(value: str, label: str) -> str | None:
    normalized = value.strip()
    if not normalized:
        return None
    try:
        return str(UUID(normalized))
    except ValueError as exc:
        raise GatewayManagementValidationError(
            f"Select a valid {label.lower()}."
        ) from exc


def validate_gateway_submission(
    *,
    organization_id: str,
    site_id: str,
    gateway_name: str,
    external_id: str,
    gateway_model_id: str,
    lifecycle_status: str,
    building_id: str,
    floor_id: str,
    space_id: str,
) -> dict[str, Any]:
    """Validate and normalize a gateway-only registration request."""

    name = gateway_name.strip()
    if not name:
        raise GatewayManagementValidationError("Gateway name is required.")
    if len(name) > 200:
        raise GatewayManagementValidationError(
            "Gateway name must not exceed 200 characters."
        )

    normalized_external_id = external_id.strip().upper()
    if not normalized_external_id:
        raise GatewayManagementValidationError(
            "Gateway external ID is required."
        )
    if len(normalized_external_id) > 200:
        raise GatewayManagementValidationError(
            "Gateway external ID must not exceed 200 characters."
        )
    if not _EXTERNAL_ID.fullmatch(normalized_external_id):
        raise GatewayManagementValidationError(
            "Gateway external ID may contain only letters, numbers, and underscores."
        )

    lifecycle = lifecycle_status.strip().upper()
    if lifecycle not in GATEWAY_LIFECYCLE_STATUSES:
        raise GatewayManagementValidationError(
            "Select a valid gateway lifecycle status."
        )

    building = _optional_uuid(building_id, "building")
    floor = _optional_uuid(floor_id, "floor")
    space = _optional_uuid(space_id, "space")
    if space and not floor:
        raise GatewayManagementValidationError(
            "A selected space requires its floor."
        )
    if floor and not building:
        raise GatewayManagementValidationError(
            "A selected floor requires its building."
        )

    return {
        "organization_id": _required_uuid(organization_id, "Organization"),
        "site_id": _required_uuid(site_id, "Site"),
        "gateway_name": name,
        "external_id": normalized_external_id,
        "gateway_model_id": _required_uuid(
            gateway_model_id, "Gateway model"
        ),
        "lifecycle_status": lifecycle,
        "building_id": building,
        "floor_id": floor,
        "space_id": space,
    }


def validate_gateway_lifecycle_update(
    *, lifecycle_status: str, change_reason: str = ""
) -> dict[str, str | None]:
    """Validate an explicit gateway lifecycle change."""
    lifecycle = lifecycle_status.strip().upper()
    if lifecycle not in GATEWAY_LIFECYCLE_STATUSES:
        raise GatewayManagementValidationError(
            "Select a valid gateway lifecycle status."
        )
    reason = change_reason.strip()
    if len(reason) > 500:
        raise GatewayManagementValidationError(
            "Change reason must not exceed 500 characters."
        )
    return {
        "lifecycle_status": lifecycle,
        "change_reason": reason or None,
    }


def validate_gateway_workspace_update(
    *,
    gateway_name: str,
    gateway_model_id: str,
    lifecycle_status: str,
    building_id: str,
    floor_id: str,
    space_id: str,
    change_reason: str,
) -> dict[str, Any]:
    """Validate a controlled gateway workspace update."""
    name = gateway_name.strip()
    if not name:
        raise GatewayManagementValidationError("Gateway name is required.")
    if len(name) > 200:
        raise GatewayManagementValidationError(
            "Gateway name must not exceed 200 characters."
        )

    lifecycle = lifecycle_status.strip().upper()
    if lifecycle not in GATEWAY_LIFECYCLE_STATUSES:
        raise GatewayManagementValidationError(
            "Select a valid gateway lifecycle status."
        )

    building = _optional_uuid(building_id, "building")
    floor = _optional_uuid(floor_id, "floor")
    space = _optional_uuid(space_id, "space")
    if space and not floor:
        raise GatewayManagementValidationError(
            "A selected space requires its floor."
        )
    if floor and not building:
        raise GatewayManagementValidationError(
            "A selected floor requires its building."
        )

    reason = change_reason.strip()
    if not reason:
        raise GatewayManagementValidationError("Change reason is required.")
    if len(reason) > 1000:
        raise GatewayManagementValidationError(
            "Change reason must not exceed 1000 characters."
        )

    return {
        "gateway_name": name,
        "gateway_model_id": _required_uuid(
            gateway_model_id, "Gateway model"
        ),
        "lifecycle_status": lifecycle,
        "building_id": building,
        "floor_id": floor,
        "space_id": space,
        "change_reason": reason,
    }
