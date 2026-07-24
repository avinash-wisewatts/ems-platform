from enum import Enum

from src.auth.models import AuthenticatedPortalUser


class PortalRole(str, Enum):
    """Canonical controlled portal authorization roles."""

    PLATFORM_ADMIN = "PLATFORM_ADMIN"
    ORG_ADMIN = "ORG_ADMIN"
    OPERATOR = "OPERATOR"
    VIEWER = "VIEWER"


class PortalPermission(str, Enum):
    """Stable application permissions independent of route implementation."""

    MANAGE_ORGANIZATIONS = "MANAGE_ORGANIZATIONS"
    RETRY_GRAFANA_PROVISIONING = "RETRY_GRAFANA_PROVISIONING"
    VIEW_ADMIN_PORTAL = "VIEW_ADMIN_PORTAL"
    EDIT_ONBOARDING_DRAFT = "EDIT_ONBOARDING_DRAFT"
    SUBMIT_ONBOARDING_DRAFT = "SUBMIT_ONBOARDING_DRAFT"
    MANAGE_PORTAL_USERS = "MANAGE_PORTAL_USERS"


ROLE_PERMISSIONS: dict[PortalRole, frozenset[PortalPermission]] = {
    PortalRole.PLATFORM_ADMIN: frozenset(
        {
            PortalPermission.RETRY_GRAFANA_PROVISIONING,
            PortalPermission.MANAGE_ORGANIZATIONS,
            PortalPermission.VIEW_ADMIN_PORTAL,
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
            PortalPermission.MANAGE_PORTAL_USERS,
        }
    ),
    PortalRole.ORG_ADMIN: frozenset(
        {
            PortalPermission.VIEW_ADMIN_PORTAL,
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
        }
    ),
    PortalRole.OPERATOR: frozenset(
        {
            PortalPermission.VIEW_ADMIN_PORTAL,
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
        }
    ),
    PortalRole.VIEWER: frozenset(
        {
            PortalPermission.VIEW_ADMIN_PORTAL,
        }
    ),
}


def portal_role(
    user: AuthenticatedPortalUser,
) -> PortalRole | None:
    """Return the controlled role represented by a session identity."""

    try:
        return PortalRole(user.role_code)
    except ValueError:
        return None


def has_permission(
    user: AuthenticatedPortalUser,
    permission: PortalPermission,
) -> bool:
    """
    Return whether a portal identity has one explicit permission.

    Unknown roles fail closed.
    """

    role = portal_role(user)

    if role is None:
        return False

    return permission in ROLE_PERMISSIONS[role]


def required_permission_for_request(
    method: str,
    path: str,
) -> PortalPermission:
    """
    Resolve the permission required for a protected HTTP request.

    Onboarding writes are divided so final submission can remain a distinct
    authorization capability as the portal grows.
    """

    normalized_method = method.upper()

    # Logging out is an authenticated self-service action, not an
    # administrative user-management operation.
    if method.upper() == "POST" and path.rstrip("/") == "/logout":
        return PortalPermission.VIEW_ADMIN_PORTAL

    if normalized_method in {"GET", "HEAD", "OPTIONS"}:
        return PortalPermission.VIEW_ADMIN_PORTAL

    if (
        normalized_method == "POST"
        and path == "/onboarding/review"
    ):
        return PortalPermission.SUBMIT_ONBOARDING_DRAFT

    if (
        normalized_method == "POST"
        and (
            path == "/onboarding"
            or path.startswith("/onboarding/")
        )
    ):
        return PortalPermission.EDIT_ONBOARDING_DRAFT

    if (
        normalized_method == "POST"
        and path.startswith("/administration/organizations/")
        and path.endswith("/grafana/retry")
    ):
        return PortalPermission.RETRY_GRAFANA_PROVISIONING

    if (
        normalized_method in {"POST", "PUT", "PATCH", "DELETE"}
        and path.rstrip("/") == "/administration/organizations"
    ):
        return PortalPermission.MANAGE_ORGANIZATIONS

    # Any future protected write route must be explicitly granted rather than
    # inheriting view permission.
    return PortalPermission.MANAGE_PORTAL_USERS
