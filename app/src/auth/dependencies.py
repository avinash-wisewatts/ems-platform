from fastapi import Request

from src.auth.models import AuthenticatedPortalUser
from src.auth.session import (
    SESSION_IDENTITY_KEY,
    deserialize_authenticated_user,
    serialize_authenticated_user,
)


def get_authenticated_portal_user(
    request: Request,
) -> AuthenticatedPortalUser | None:
    """
    Return the authenticated portal identity from the signed session.

    Missing, corrupted, or incomplete session data is treated as unauthenticated.
    """

    session = getattr(request, "session", None)

    if not isinstance(session, dict):
        return None

    return deserialize_authenticated_user(
        session.get(SESSION_IDENTITY_KEY)
    )


def set_authenticated_portal_user(
    request: Request,
    user: AuthenticatedPortalUser,
) -> None:
    """Store a safe authenticated identity in the signed session."""

    request.session[SESSION_IDENTITY_KEY] = (
        serialize_authenticated_user(user)
    )


def clear_authenticated_portal_user(
    request: Request,
) -> None:
    """Remove all authentication session state."""

    request.session.clear()


def authenticated_actor(
    request: Request,
) -> str:
    """
    Return the stable audit actor for the current request.

    Until route protection is enabled, unauthenticated requests receive the
    explicit fallback actor rather than the previous fixed portal version.
    """

    user = get_authenticated_portal_user(request)

    if user is None:
        return "unauthenticated"

    return user.username


def require_authenticated_portal_user(
    request: Request,
) -> AuthenticatedPortalUser:
    """
    Return the authenticated portal identity.

    Protected routes should never reach this function without a valid session
    because PortalAuthenticationMiddleware runs first. Raising here provides a
    fail-closed safeguard against future routing or middleware mistakes.
    """

    user = get_authenticated_portal_user(request)

    if user is None:
        raise RuntimeError(
            "Protected portal route reached without an authenticated identity."
        )

    return user
