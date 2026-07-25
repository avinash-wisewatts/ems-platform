"""Validation for independent site and physical-location administration."""

import re
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]*$")
LIFECYCLE_STATUSES = (
    "DRAFT",
    "ACTIVE",
    "INACTIVE",
    "DECOMMISSIONED",
)


class LocationManagementValidationError(ValueError):
    """Validation failure for an Epic 4 administration form."""


def _required_uuid(value: str, label: str) -> str:
    try:
        return str(UUID(value.strip()))
    except ValueError as exc:
        raise LocationManagementValidationError(
            f"{label} is required."
        ) from exc


def _required_name(value: str, label: str) -> str:
    normalized = value.strip()

    if not normalized:
        raise LocationManagementValidationError(
            f"{label} is required."
        )

    if len(normalized) > 200:
        raise LocationManagementValidationError(
            f"{label} must not exceed 200 characters."
        )

    return normalized


def _required_code(value: str, label: str) -> str:
    normalized = value.strip().upper()

    if not normalized:
        raise LocationManagementValidationError(
            f"{label} is required."
        )

    if len(normalized) > 100:
        raise LocationManagementValidationError(
            f"{label} must not exceed 100 characters."
        )

    if not CODE_PATTERN.fullmatch(normalized):
        raise LocationManagementValidationError(
            f"{label} must start with A-Z and contain only "
            "A-Z, 0-9, and underscore."
        )

    return normalized


def validate_site_submission(
    *,
    organization_id: str,
    site_name: str,
    site_code: str,
    site_timezone: str,
    lifecycle_status: str,
) -> dict[str, Any]:
    """Validate and normalize an independent site request."""

    timezone = site_timezone.strip()

    if not timezone:
        raise LocationManagementValidationError(
            "Site timezone is required."
        )

    if len(timezone) > 100:
        raise LocationManagementValidationError(
            "Site timezone must not exceed 100 characters."
        )

    try:
        ZoneInfo(timezone)
    except ZoneInfoNotFoundError as exc:
        raise LocationManagementValidationError(
            "Site timezone must be a valid IANA timezone."
        ) from exc

    normalized_status = lifecycle_status.strip().upper()

    if normalized_status not in LIFECYCLE_STATUSES:
        raise LocationManagementValidationError(
            "Select a valid lifecycle status."
        )

    return {
        "organization_id": _required_uuid(
            organization_id,
            "Organization",
        ),
        "name": _required_name(site_name, "Site name"),
        "code": _required_code(site_code, "Site code"),
        "timezone": timezone,
        "lifecycle_status": normalized_status,
    }


def validate_building_submission(
    *,
    site_id: str,
    building_name: str,
    building_code: str,
) -> dict[str, str]:
    """Validate and normalize an independent building request."""

    return {
        "site_id": _required_uuid(site_id, "Site"),
        "name": _required_name(building_name, "Building name"),
        "code": _required_code(building_code, "Building code"),
    }


def validate_floor_submission(
    *,
    building_id: str,
    floor_name: str,
    floor_code: str,
) -> dict[str, str]:
    """Validate and normalize an independent floor request."""

    return {
        "building_id": _required_uuid(building_id, "Building"),
        "name": _required_name(floor_name, "Floor name"),
        "code": _required_code(floor_code, "Floor code"),
    }


def validate_space_submission(
    *,
    floor_id: str,
    space_name: str,
    space_code: str,
) -> dict[str, str]:
    """Validate and normalize an independent space request."""

    return {
        "floor_id": _required_uuid(floor_id, "Floor"),
        "name": _required_name(space_name, "Space name"),
        "code": _required_code(space_code, "Space code"),
    }
