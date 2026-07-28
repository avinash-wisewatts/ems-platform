"""Tenant-safe repository lookups used by administration context."""

from typing import Any

from src.location_management_service import (
    list_accessible_physical_locations,
)
from src.onboarding.repository import (
    list_accessible_sites,
    list_organizations,
)


async def list_accessible_organizations_for_user(
    *,
    portal_user_id: int,
    role_code: str,
    assigned_organization_id: str | None,
) -> list[dict[str, Any]]:
    """Return organizations available to one authenticated identity."""

    organizations = await list_organizations()

    if role_code == "PLATFORM_ADMIN":
        return organizations

    if assigned_organization_id is None:
        return []

    return [
        organization
        for organization in organizations
        if str(organization.get("id")) == assigned_organization_id
    ]


async def list_accessible_sites_for_user(
    *,
    portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return sites already filtered by the database access contract."""

    return await list_accessible_sites(portal_user_id=portal_user_id)


async def list_accessible_locations_for_user(
    *,
    portal_user_id: int,
) -> list[dict[str, Any]]:
    """Return physical locations filtered by the database access contract."""

    return await list_accessible_physical_locations(
        portal_user_id=portal_user_id
    )
