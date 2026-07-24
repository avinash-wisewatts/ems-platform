import pytest

from src.auth.authorization import (
    PortalPermission,
    PortalRole,
    has_permission,
    portal_role,
    required_permission_for_request,
)
from src.auth.models import AuthenticatedPortalUser


@pytest.mark.parametrize(
    ("role_code", "expected_role"),
    [
        ("SUPER_ADMIN", PortalRole.SUPER_ADMIN),
        ("OPERATOR", PortalRole.OPERATOR),
        ("VIEWER", PortalRole.VIEWER),
    ],
)
def test_portal_role_resolves_controlled_roles(
    role_code: str,
    expected_role: PortalRole,
) -> None:
    user = AuthenticatedPortalUser(
        portal_user_id=1,
        username="user@example.com",
        display_name="Test User",
        role_code=role_code,
    )

    assert portal_role(user) is expected_role


def test_unknown_portal_role_fails_closed() -> None:
    user = AuthenticatedPortalUser(
        portal_user_id=1,
        username="user@example.com",
        display_name="Test User",
        role_code="UNRECOGNIZED_ROLE",
    )

    assert portal_role(user) is None

    for permission in PortalPermission:
        assert has_permission(user, permission) is False


@pytest.mark.parametrize(
    ("role_code", "permission", "expected"),
    [
        (
            "SUPER_ADMIN",
            PortalPermission.VIEW_ADMIN_PORTAL,
            True,
        ),
        (
            "SUPER_ADMIN",
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            True,
        ),
        (
            "SUPER_ADMIN",
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
            True,
        ),
        (
            "SUPER_ADMIN",
            PortalPermission.MANAGE_PORTAL_USERS,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.VIEW_ADMIN_PORTAL,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.MANAGE_PORTAL_USERS,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.VIEW_ADMIN_PORTAL,
            True,
        ),
        (
            "VIEWER",
            PortalPermission.EDIT_ONBOARDING_DRAFT,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.SUBMIT_ONBOARDING_DRAFT,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.MANAGE_PORTAL_USERS,
            False,
        ),
        (
            "SUPER_ADMIN",
            PortalPermission.RETRY_GRAFANA_PROVISIONING,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.RETRY_GRAFANA_PROVISIONING,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.RETRY_GRAFANA_PROVISIONING,
            False,
        ),
    ],
)
def test_role_permission_matrix(
    role_code: str,
    permission: PortalPermission,
    expected: bool,
) -> None:
    user = AuthenticatedPortalUser(
        portal_user_id=1,
        username="user@example.com",
        display_name="Test User",
        role_code=role_code,
    )

    assert has_permission(user, permission) is expected


@pytest.mark.parametrize(
    "method",
    ["GET", "HEAD", "OPTIONS", "get", "head", "options"],
)
def test_safe_request_methods_require_view_permission(
    method: str,
) -> None:
    assert (
        required_permission_for_request(
            method,
            "/onboarding/device",
        )
        is PortalPermission.VIEW_ADMIN_PORTAL
    )


def test_review_submission_requires_submit_permission() -> None:
    assert (
        required_permission_for_request(
            "POST",
            "/onboarding/review",
        )
        is PortalPermission.SUBMIT_ONBOARDING_DRAFT
    )


@pytest.mark.parametrize(
    "path",
    [
        "/onboarding",
        "/onboarding/organization",
        "/onboarding/site",
        "/onboarding/device",
        "/onboarding/asset",
    ],
)
def test_onboarding_writes_require_edit_permission(
    path: str,
) -> None:
    assert (
        required_permission_for_request("POST", path)
        is PortalPermission.EDIT_ONBOARDING_DRAFT
    )

def test_grafana_retry_requires_dedicated_permission() -> None:
    assert (
        required_permission_for_request(
            "POST",
            (
                "/administration/organizations/"
                "33333333-3333-4333-8333-333333333333/"
                "grafana/retry"
            ),
        )
        is PortalPermission.RETRY_GRAFANA_PROVISIONING
    )

@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("POST", "/admin/users"),
        ("PUT", "/onboarding/device"),
        ("DELETE", "/onboarding/device"),
        ("PATCH", "/anything"),
    ],
)
def test_unknown_write_routes_fail_closed_to_manage_users(
    method: str,
    path: str,
) -> None:
    assert (
        required_permission_for_request(method, path)
        is PortalPermission.MANAGE_PORTAL_USERS
    )
