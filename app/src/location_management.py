"""Validation for independent site and physical-location administration."""

import re
from typing import Any
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9_]*$")
TELEMETRY_CAPTURE_INTERVALS = (10, 30, 60, 300, 900)

DEMAND_INTERVALS = (900, 1800)
DEMAND_BASES = ("ACTIVE_POWER_KW", "APPARENT_POWER_KVA")
DEMAND_SOURCE_ROLES = ("GRID_IMPORT", "SITE_CONSUMPTION")

# Platform-managed demand quality defaults.
DEMAND_MINIMUM_COVERAGE_PERCENT = 90.0
DEMAND_LATE_ARRIVAL_TOLERANCE_SECONDS = 30

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
    telemetry_capture_interval_seconds: str = "60",
    sub_sector_id: str = "",
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

    try:
        capture_interval = int(telemetry_capture_interval_seconds.strip())
    except (TypeError, ValueError) as exc:
        raise LocationManagementValidationError(
            "Select a valid telemetry storage interval."
        ) from exc

    if capture_interval not in TELEMETRY_CAPTURE_INTERVALS:
        raise LocationManagementValidationError(
            "Telemetry storage interval must be 10, 30, 60, 300, or 900 seconds."
        )

    normalized_status = lifecycle_status.strip().upper()

    if normalized_status not in LIFECYCLE_STATUSES:
        raise LocationManagementValidationError(
            "Select a valid lifecycle status."
        )

    normalized_sub_sector_id = _required_uuid(sub_sector_id, "Sub-sector")

    return {
        "organization_id": _required_uuid(
            organization_id,
            "Organization",
        ),
        "name": _required_name(site_name, "Site name"),
        "code": _required_code(site_code, "Site code"),
        "timezone": timezone,
        "lifecycle_status": normalized_status,
        "telemetry_capture_interval_seconds": capture_interval,
        "sub_sector_id": normalized_sub_sector_id,
    }


def validate_site_demand_submission(
    *,
    demand_monitoring_enabled: str | None,
    demand_interval_seconds: str = "900",
    demand_basis: str = "ACTIVE_POWER_KW",
    site_demand_source_role: str = "GRID_IMPORT",
) -> dict[str, Any]:
    """Validate the user-facing site demand monitoring configuration."""

    normalized_enabled = str(
        demand_monitoring_enabled or "DISABLED"
    ).strip().upper()

    enabled_values = {"1", "TRUE", "YES", "ON", "ENABLED"}
    disabled_values = {"0", "FALSE", "NO", "OFF", "DISABLED", ""}

    if normalized_enabled in enabled_values:
        enabled = True
    elif normalized_enabled in disabled_values:
        enabled = False
    else:
        raise LocationManagementValidationError(
            "Select Enabled or Disabled for demand monitoring."
        )

    try:
        interval_seconds = int(demand_interval_seconds.strip())
    except (TypeError, ValueError) as exc:
        raise LocationManagementValidationError(
            "Select a valid demand interval."
        ) from exc

    if interval_seconds not in DEMAND_INTERVALS:
        raise LocationManagementValidationError(
            "Demand interval must be 15 or 30 minutes."
        )

    normalized_basis = demand_basis.strip().upper()
    if normalized_basis not in DEMAND_BASES:
        raise LocationManagementValidationError(
            "Select a valid demand basis."
        )

    normalized_source_role = site_demand_source_role.strip().upper()
    if normalized_source_role not in DEMAND_SOURCE_ROLES:
        raise LocationManagementValidationError(
            "Select a valid site demand source."
        )

    return {
        "is_enabled": enabled,
        "demand_interval_seconds": interval_seconds,
        "demand_basis": normalized_basis,
        "site_demand_source_role": normalized_source_role,
        "minimum_coverage_percent": DEMAND_MINIMUM_COVERAGE_PERCENT,
        "late_arrival_tolerance_seconds":
            DEMAND_LATE_ARRIVAL_TOLERANCE_SECONDS,
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
