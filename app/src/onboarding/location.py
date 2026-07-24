import re
from typing import Any
from uuid import UUID


LOCATION_CODE_PATTERN = re.compile(
    r"^[A-Z][A-Z0-9_]*$"
)


class LocationStepValidationError(ValueError):
    """Validation failure for the Physical Location step."""


def _required_name(
    value: str,
    label: str,
) -> str:
    normalized = value.strip()

    if not normalized:
        raise LocationStepValidationError(
            f"{label} is required."
        )

    if len(normalized) > 200:
        raise LocationStepValidationError(
            f"{label} must not exceed 200 characters."
        )

    return normalized


def _location_code(
    value: str,
    label: str,
) -> str:
    normalized = value.strip().upper()

    if not normalized:
        raise LocationStepValidationError(
            f"{label} is required."
        )

    if len(normalized) > 100:
        raise LocationStepValidationError(
            f"{label} must not exceed 100 characters."
        )

    if not LOCATION_CODE_PATTERN.fullmatch(normalized):
        raise LocationStepValidationError(
            f"{label} must start with A-Z and contain only "
            "A-Z, 0-9, and underscore."
        )

    return normalized


def validate_location_step(
    *,
    location_mode: str,
    existing_space_id: str,
    building_name: str,
    building_code: str,
    floor_name: str,
    floor_code: str,
    space_name: str,
    space_code: str,
) -> dict[str, Any]:
    """Validate and normalize the Physical Location step."""

    mode = location_mode.strip().upper()

    if mode not in {
        "SITE_ONLY",
        "CREATE_LOCATION",
        "USE_EXISTING_SPACE",
    }:
        raise LocationStepValidationError(
            "Select a valid physical-location option."
        )

    if mode == "SITE_ONLY":
        return {
            "mode": "SITE_ONLY",
            "existing_space_id": None,
            "building_name": None,
            "building_code": None,
            "floor_name": None,
            "floor_code": None,
            "space_name": None,
            "space_code": None,
        }

    if mode == "USE_EXISTING_SPACE":
        try:
            space_id = str(
                UUID(existing_space_id.strip())
            )
        except ValueError as exc:
            raise LocationStepValidationError(
                "Select an existing space."
            ) from exc

        return {
            "mode": "USE_EXISTING_SPACE",
            "existing_space_id": space_id,
            "building_name": None,
            "building_code": None,
            "floor_name": None,
            "floor_code": None,
            "space_name": None,
            "space_code": None,
        }

    return {
        "mode": "CREATE_LOCATION",
        "existing_space_id": None,
        "building_name": _required_name(
            building_name,
            "Building name",
        ),
        "building_code": _location_code(
            building_code,
            "Building code",
        ),
        "floor_name": _required_name(
            floor_name,
            "Floor name",
        ),
        "floor_code": _location_code(
            floor_code,
            "Floor code",
        ),
        "space_name": _required_name(
            space_name,
            "Space name",
        ),
        "space_code": _location_code(
            space_code,
            "Space code",
        ),
    }
