from typing import Any
from uuid import UUID

from src.auth.models import AuthenticatedPortalUser


SESSION_IDENTITY_KEY = "portal_identity"


def serialize_authenticated_user(
    user: AuthenticatedPortalUser,
) -> dict[str, Any]:
    """Convert a safe authenticated identity into session primitives."""

    return {
        "portal_user_id": user.portal_user_id,
        "username": user.username,
        "display_name": user.display_name,
        "role_code": user.role_code,
        "organization_id": user.organization_id,
        "access_scope_mode": user.access_scope_mode,
        "site_ids": list(user.site_ids),
    }


def deserialize_authenticated_user(
    payload: object,
) -> AuthenticatedPortalUser | None:
    """Rebuild an authenticated identity and fail closed on invalid data."""

    if not isinstance(payload, dict):
        return None

    portal_user_id = payload.get("portal_user_id")
    username = payload.get("username")
    display_name = payload.get("display_name")
    role_code = payload.get("role_code")
    organization_id = payload.get("organization_id")
    access_scope_mode = payload.get("access_scope_mode")
    site_ids = payload.get("site_ids", [])

    if (
        type(portal_user_id) is not int
        or portal_user_id <= 0
        or not isinstance(username, str)
        or not username.strip()
        or not isinstance(display_name, str)
        or not display_name.strip()
        or role_code not in {
            "ADMIN",
            "OPERATOR",
            "VIEWER",
        }
        or access_scope_mode not in {
            "GLOBAL",
            "ORGANIZATION",
            "SELECTED_SITES",
        }
    ):
        return None

    if organization_id is not None:
        if not isinstance(organization_id, str):
            return None

        try:
            organization_id = str(UUID(organization_id))
        except ValueError:
            return None

    if not isinstance(site_ids, (list, tuple)):
        return None

    normalized_site_ids: list[str] = []

    for site_id in site_ids:
        if not isinstance(site_id, str):
            return None

        try:
            normalized_site_id = str(UUID(site_id))
        except ValueError:
            return None

        if normalized_site_id not in normalized_site_ids:
            normalized_site_ids.append(normalized_site_id)

    if access_scope_mode == "GLOBAL":
        if organization_id is not None or normalized_site_ids:
            return None
    elif organization_id is None:
        return None
    elif access_scope_mode == "ORGANIZATION":
        if normalized_site_ids:
            return None
    elif access_scope_mode == "SELECTED_SITES":
        if not normalized_site_ids:
            return None

    return AuthenticatedPortalUser(
        portal_user_id=portal_user_id,
        username=username,
        display_name=display_name,
        role_code=role_code,
        organization_id=organization_id,
        access_scope_mode=access_scope_mode,
        site_ids=tuple(normalized_site_ids),
    )
