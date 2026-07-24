import re
from typing import Any
from uuid import UUID


ORGANIZATION_CODE_PATTERN = re.compile(
    r"^[A-Z0-9_]+$"
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
        }

    name = organization_name.strip()
    code = organization_code.strip().upper()
    description = organization_description.strip()

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

    return {
        "mode": "CREATE_NEW",
        "existing_organization_id": None,
        "name": name,
        "code": code,
        "description": description or None,
    }
