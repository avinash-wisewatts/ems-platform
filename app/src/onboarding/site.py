import re
from typing import Any
from uuid import UUID

from src.location_management import SITE_SECTORS


SITE_CODE_PATTERN = re.compile(r"^[A-Z0-9_]+$")
TELEMETRY_CAPTURE_INTERVALS = (10, 30, 60, 300, 900)


class SiteStepValidationError(ValueError):
    """Validation failure for the Site onboarding step."""


def validate_site_step(
    *,
    site_mode: str,
    existing_site_id: str,
    site_name: str,
    site_code: str,
    site_timezone: str,
    site_sector: str = "OTHER",
    site_address: str = "",
    organization_mode: str,
    telemetry_capture_interval_seconds: str = "60",
) -> dict[str, Any]:
    """
    Validate and normalize the Site wizard step.

    A newly created organization cannot use an existing site because no
    production organization record exists until final submission.
    """

    mode = site_mode.strip().upper()
    parent_mode = organization_mode.strip().upper()

    if mode not in {"CREATE_NEW", "USE_EXISTING"}:
        raise SiteStepValidationError(
            "Select whether to use an existing site or create one."
        )

    if parent_mode == "CREATE_NEW" and mode == "USE_EXISTING":
        raise SiteStepValidationError(
            "A new organization cannot use an existing site."
        )

    try:
        capture_interval = int(telemetry_capture_interval_seconds.strip())
    except (TypeError, ValueError) as exc:
        raise SiteStepValidationError(
            "Select a valid telemetry storage interval."
        ) from exc

    if capture_interval not in TELEMETRY_CAPTURE_INTERVALS:
        raise SiteStepValidationError(
            "Telemetry storage interval must be 10, 30, 60, 300, or 900 seconds."
        )

    if mode == "USE_EXISTING":
        try:
            site_id = str(UUID(existing_site_id.strip()))
        except ValueError as exc:
            raise SiteStepValidationError(
                "Select an existing site."
            ) from exc

        return {
            "mode": "USE_EXISTING",
            "existing_site_id": site_id,
            "name": None,
            "code": None,
            "timezone": None,
            "sector_code": None,
            "address": None,
            "telemetry_capture_interval_seconds": capture_interval,
        }

    name = site_name.strip()
    code = site_code.strip().upper()
    timezone = site_timezone.strip()
    sector_code = site_sector.strip().upper()
    address = site_address.strip()

    if not name:
        raise SiteStepValidationError(
            "Site name is required."
        )

    if len(name) > 200:
        raise SiteStepValidationError(
            "Site name must not exceed 200 characters."
        )

    if not code:
        raise SiteStepValidationError(
            "Site code is required."
        )

    if not SITE_CODE_PATTERN.fullmatch(code):
        raise SiteStepValidationError(
            "Site code may contain only A-Z, 0-9, and underscore."
        )

    if len(code) > 100:
        raise SiteStepValidationError(
            "Site code must not exceed 100 characters."
        )

    if not timezone:
        raise SiteStepValidationError(
            "Site timezone is required."
        )

    if len(timezone) > 100:
        raise SiteStepValidationError(
            "Site timezone must not exceed 100 characters."
        )

    if sector_code not in SITE_SECTORS:
        raise SiteStepValidationError(
            "Select a valid site sector."
        )

    if len(address) > 1000:
        raise SiteStepValidationError(
            "Site address must not exceed 1000 characters."
        )

    return {
        "mode": "CREATE_NEW",
        "existing_site_id": None,
        "name": name,
        "code": code,
        "timezone": timezone,
        "sector_code": sector_code,
        "telemetry_capture_interval_seconds": capture_interval,
        "address": (
            {"full_address": address}
            if address
            else {}
        ),
    }
