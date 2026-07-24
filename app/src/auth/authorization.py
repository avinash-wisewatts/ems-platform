from enum import Enum

from src.auth.models import AuthenticatedPortalUser


class PortalRole(str, Enum):
    """Canonical controlled portal authorization roles."""

    PLATFORM_ADMIN = "PLATFORM_ADMIN"
    ORG_ADMIN = "ORG_ADMIN"
    OPERATOR = "OPERATOR"
    VIEWER = "VIEWER"


class PortalPermission(str, Enum):
    """Canonical application permissions independent of route implementation."""

    ORGANIZATION_MANAGE = "organization.manage"
    USER_MANAGE = "user.manage"
    SITE_MANAGE = "site.manage"
    LOCATION_MANAGE = "location.manage"
    ASSET_MANAGE = "asset.manage"
    GATEWAY_MANAGE = "gateway.manage"
    DEVICE_MANAGE = "device.manage"
    RELATIONSHIP_MANAGE = "relationship.manage"
    METERING_POLICY_MANAGE = "metering_policy.manage"
    COMMISSIONING_EXECUTE = "commissioning.execute"
    ALERT_ACKNOWLEDGE = "alert.acknowledge"
    DASHBOARD_VIEW = "dashboard.view"
    REPORT_EXPORT = "report.export"
    AUDIT_VIEW = "audit.view"


ROLE_PERMISSIONS: dict[PortalRole, frozenset[PortalPermission]] = {
    PortalRole.PLATFORM_ADMIN: frozenset(PortalPermission),
    PortalRole.ORG_ADMIN: frozenset(
        permission
        for permission in PortalPermission
        if permission is not PortalPermission.ORGANIZATION_MANAGE
    ),
    PortalRole.OPERATOR: frozenset(
        {
            PortalPermission.SITE_MANAGE,
            PortalPermission.LOCATION_MANAGE,
            PortalPermission.ASSET_MANAGE,
            PortalPermission.GATEWAY_MANAGE,
            PortalPermission.DEVICE_MANAGE,
            PortalPermission.RELATIONSHIP_MANAGE,
            PortalPermission.METERING_POLICY_MANAGE,
            PortalPermission.COMMISSIONING_EXECUTE,
            PortalPermission.ALERT_ACKNOWLEDGE,
            PortalPermission.DASHBOARD_VIEW,
            PortalPermission.REPORT_EXPORT,
        }
    ),
    PortalRole.VIEWER: frozenset(
        {
            PortalPermission.DASHBOARD_VIEW,
            PortalPermission.REPORT_EXPORT,
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
) -> PortalPermission | None:
    """
    Resolve the permission required for a protected HTTP request.

    Onboarding writes are divided so final submission can remain a distinct
    authorization capability as the portal grows.
    """

    normalized_method = method.upper()

    # Logging out is an authenticated self-service action, not an
    # administrative user-management operation.
    if method.upper() == "POST" and path.rstrip("/") == "/logout":
        return PortalPermission.DASHBOARD_VIEW

    if normalized_method in {"GET", "HEAD", "OPTIONS"}:
        return PortalPermission.DASHBOARD_VIEW

    if (
        normalized_method == "POST"
        and path == "/onboarding/review"
    ):
        return PortalPermission.COMMISSIONING_EXECUTE

    if (
        normalized_method == "POST"
        and (
            path == "/onboarding"
            or path.startswith("/onboarding/")
        )
    ):
        return PortalPermission.COMMISSIONING_EXECUTE

    if (
        normalized_method == "POST"
        and path.startswith("/administration/organizations/")
        and path.endswith("/grafana/retry")
    ):
        return PortalPermission.ORGANIZATION_MANAGE

    if (
        normalized_method in {"POST", "PUT", "PATCH", "DELETE"}
        and path.rstrip("/") == "/administration/organizations"
    ):
        return PortalPermission.ORGANIZATION_MANAGE

    if (
        normalized_method in {"POST", "PUT", "PATCH", "DELETE"}
        and (
            path.rstrip("/") == "/administration/users"
            or path.startswith("/administration/users/")
        )
    ):
        return PortalPermission.USER_MANAGE

    # Any future protected write route must be explicitly mapped.
    # Returning no permission causes middleware to reject it fail-closed.
    return None


ROLE_ASSIGNMENT_POLICY: dict[PortalRole, frozenset[PortalRole]] = {
    PortalRole.PLATFORM_ADMIN: frozenset(PortalRole),
    PortalRole.ORG_ADMIN: frozenset(
        {
            PortalRole.ORG_ADMIN,
            PortalRole.OPERATOR,
            PortalRole.VIEWER,
        }
    ),
    PortalRole.OPERATOR: frozenset(),
    PortalRole.VIEWER: frozenset(),
}


def assignable_portal_roles(
    actor_role: PortalRole,
) -> set[PortalRole]:
    """Return the canonical roles one actor role may assign."""

    return set(ROLE_ASSIGNMENT_POLICY[actor_role])


def can_assign_portal_role(
    actor_role: PortalRole,
    target_role: PortalRole,
) -> bool:
    """Return whether one role may assign the requested target role."""

    return target_role in ROLE_ASSIGNMENT_POLICY[actor_role]


def can_manage_user_in_organization(
    *,
    actor_role: PortalRole,
    actor_organization_id: str | None,
    target_organization_id: str | None,
) -> bool:
    """
    Return whether an actor may manage a user in the target organization.

    Platform administrators are global. Organization administrators are
    restricted to their own non-null organization. Other roles cannot manage
    users.
    """

    if actor_role is PortalRole.PLATFORM_ADMIN:
        return True

    if actor_role is not PortalRole.ORG_ADMIN:
        return False

    return (
        actor_organization_id is not None
        and target_organization_id is not None
        and actor_organization_id == target_organization_id
    )
