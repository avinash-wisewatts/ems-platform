from typing import Any

from src.auth.models import AuthenticatedPortalUser


SESSION_IDENTITY_KEY = "portal_identity"


def serialize_authenticated_user(
    user: AuthenticatedPortalUser,
) -> dict[str, Any]:
    """
    Convert a safe authenticated identity into session-compatible primitives.

    Password hashes, lockout state, and other authentication internals are
    intentionally excluded.
    """

    return {
        "portal_user_id": user.portal_user_id,
        "username": user.username,
        "display_name": user.display_name,
        "role_code": user.role_code,
    }


def deserialize_authenticated_user(
    payload: object,
) -> AuthenticatedPortalUser | None:
    """
    Rebuild an authenticated identity from signed session data.

    Invalid or incomplete session payloads fail closed and return None.
    """

    if not isinstance(payload, dict):
        return None

    portal_user_id = payload.get("portal_user_id")
    username = payload.get("username")
    display_name = payload.get("display_name")
    role_code = payload.get("role_code")

    if (
        type(portal_user_id) is not int
        or portal_user_id <= 0
        or not isinstance(username, str)
        or not username.strip()
        or not isinstance(display_name, str)
        or not display_name.strip()
        or role_code not in {
            "SUPER_ADMIN",
            "OPERATOR",
            "VIEWER",
        }
    ):
        return None

    return AuthenticatedPortalUser(
        portal_user_id=portal_user_id,
        username=username,
        display_name=display_name,
        role_code=role_code,
    )
