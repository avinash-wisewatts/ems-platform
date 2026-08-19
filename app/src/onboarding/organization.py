import re
from typing import Any
from uuid import UUID


ORGANIZATION_CODE_PATTERN = re.compile(
    r"^[A-Z0-9_]+$"
)

ORGANIZATION_LIFECYCLE_STATUSES = (
    "DRAFT",
    "ACTIVE",
    "SUSPENDED",
    "DECOMMISSIONED",
)


class OrganizationStepValidationError(ValueError):
    """Validation failure for the Organization wizard step."""


def validate_organization_step(
    *,
    organization_mode: str,
    existing_organization_id: str,
    organization_name: str,
    organization_code: str,
    organization_description: str,
    organization_timezone: str = "Asia/Kolkata",
    organization_lifecycle_status: str = "ACTIVE",
    legal_name: str = "",
    locale: str = "en-US",
    contact_name: str = "",
    contact_email: str = "",
    contact_phone: str = "",
    address_line1: str = "",
    address_line2: str = "",
    city: str = "",
    region: str = "",
    postal_code: str = "",
    country: str = "",
    notes: str = "",
) -> dict[str, Any]:
    """Validate and normalize the Organization wizard step."""

    mode = organization_mode.strip().upper()

    if mode not in {"CREATE_NEW", "USE_EXISTING"}:
        raise OrganizationStepValidationError(
            "Select whether to use an existing organization or create one."
        )

    if mode == "USE_EXISTING":
        try:
            organization_id = str(
                UUID(existing_organization_id.strip())
            )
        except ValueError as exc:
            raise OrganizationStepValidationError(
                "Select an existing organization."
            ) from exc

        return {
            "mode": "USE_EXISTING",
            "existing_organization_id": organization_id,
            "name": None,
            "code": None,
            "description": None,
            "timezone": None,
            "lifecycle_status": None,
            "legal_name": None,
            "locale": None,
            "primary_contact": None,
            "address": None,
            "notes": None,
        }

    name = organization_name.strip()
    code = organization_code.strip().upper()
    description = organization_description.strip()
    timezone = organization_timezone.strip() or "Asia/Kolkata"
    lifecycle_status = (
        organization_lifecycle_status.strip().upper() or "ACTIVE"
    )

    if not name:
        raise OrganizationStepValidationError(
            "Organization name is required."
        )

    if len(name) > 200:
        raise OrganizationStepValidationError(
            "Organization name must not exceed 200 characters."
        )

    if not code:
        raise OrganizationStepValidationError(
            "Organization code is required."
        )

    if not ORGANIZATION_CODE_PATTERN.fullmatch(code):
        raise OrganizationStepValidationError(
            "Organization code may contain only A-Z, 0-9, and underscore."
        )

    if len(code) > 100:
        raise OrganizationStepValidationError(
            "Organization code must not exceed 100 characters."
        )

    if len(description) > 1000:
        raise OrganizationStepValidationError(
            "Organization description must not exceed 1000 characters."
        )

    if lifecycle_status not in ORGANIZATION_LIFECYCLE_STATUSES:
        raise OrganizationStepValidationError(
            "Organization lifecycle status must be one of "
            "DRAFT, ACTIVE, SUSPENDED, or DECOMMISSIONED."
        )

    return {
        "mode": "CREATE_NEW",
        "existing_organization_id": None,
        "name": name,
        "code": code,
        "description": description or None,
        "timezone": timezone,
        "lifecycle_status": lifecycle_status,
        "legal_name": legal_name.strip(),
        "locale": locale.strip() or "en-US",
        "primary_contact": {
            "name": contact_name.strip(),
            "email": contact_email.strip(),
            "phone": contact_phone.strip(),
        },
        "address": {
            "line1": address_line1.strip(),
            "line2": address_line2.strip(),
            "city": city.strip(),
            "region": region.strip(),
            "postal_code": postal_code.strip(),
            "country": country.strip(),
        },
        "notes": notes.strip(),
    }
