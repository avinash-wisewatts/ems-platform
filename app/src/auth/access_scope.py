from dataclasses import dataclass
from enum import Enum


class PortalAccessScopeMode(str, Enum):
    """Canonical portal access-scope modes."""

    GLOBAL = "GLOBAL"
    ORGANIZATION = "ORGANIZATION"
    SELECTED_SITES = "SELECTED_SITES"


@dataclass(frozen=True, slots=True)
class PortalAccessScope:
    """Platform, organization, or selected-site access for one identity."""

    mode: PortalAccessScopeMode
    organization_id: str | None
    site_ids: frozenset[str]


def validate_portal_access_scope(
    scope: PortalAccessScope,
) -> None:
    """Validate one controlled portal access scope."""

    if scope.mode is PortalAccessScopeMode.GLOBAL:
        if scope.organization_id is not None:
            raise ValueError(
                "Global access scope must not include an organization."
            )
        if scope.site_ids:
            raise ValueError(
                "Global access scope must not include site assignments."
            )
        return

    if scope.organization_id is None:
        raise ValueError(
            "Organization and selected-sites scope require an organization."
        )

    if scope.mode is PortalAccessScopeMode.ORGANIZATION:
        if scope.site_ids:
            raise ValueError(
                "Organization scope must not include site assignments."
            )
        return

    if scope.mode is PortalAccessScopeMode.SELECTED_SITES:
        if not scope.site_ids:
            raise ValueError(
                "Selected-sites scope requires at least one site."
            )
        return

    raise ValueError("Unsupported portal access-scope mode.")


def can_access_site(
    *,
    scope: PortalAccessScope,
    site_id: str,
    site_organization_id: str,
) -> bool:
    """Return whether the scope permits access to one site."""

    try:
        validate_portal_access_scope(scope)
    except ValueError:
        return False

    if scope.mode is PortalAccessScopeMode.GLOBAL:
        return True

    if site_organization_id != scope.organization_id:
        return False

    if scope.mode is PortalAccessScopeMode.ORGANIZATION:
        return True

    return site_id in scope.site_ids


def normalize_portal_access_scope_submission(
    *,
    access_scope_mode: str,
    site_ids: list[str] | tuple[str, ...],
) -> tuple[PortalAccessScopeMode, tuple[str, ...]]:
    """Normalize and validate one submitted portal access scope."""

    from uuid import UUID

    try:
        mode = PortalAccessScopeMode(
            access_scope_mode.strip().upper()
        )
    except (AttributeError, ValueError) as exc:
        raise ValueError(
            "Unsupported portal access-scope mode."
        ) from exc

    normalized_site_ids: list[str] = []

    for site_id in site_ids:
        if not isinstance(site_id, str):
            raise ValueError(
                "Site identifiers must be strings."
            )

        try:
            normalized_site_id = str(UUID(site_id))
        except ValueError as exc:
            raise ValueError(
                "Site identifiers must be valid UUIDs."
            ) from exc

        if normalized_site_id not in normalized_site_ids:
            normalized_site_ids.append(normalized_site_id)

    placeholder_organization_id = (
        None if mode is PortalAccessScopeMode.GLOBAL
        else "submission-placeholder"
    )

    scope = PortalAccessScope(
        mode=mode,
        organization_id=placeholder_organization_id,
        site_ids=frozenset(normalized_site_ids),
    )

    validate_portal_access_scope(scope)

    return mode, tuple(normalized_site_ids)
