import pytest

from src.auth.authorization import (
    PortalPermission,
    PortalRole,
    ROLE_PERMISSIONS,
    has_permission,
    portal_role,
    required_permission_for_request,
)
from src.auth.models import AuthenticatedPortalUser


@pytest.mark.parametrize(
    ("role_code", "expected_role"),
    [
        ("PLATFORM_ADMIN", PortalRole.PLATFORM_ADMIN),
        ("ORG_ADMIN", PortalRole.ORG_ADMIN),
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
            "PLATFORM_ADMIN",
            PortalPermission.DASHBOARD_VIEW,
            True,
        ),
        (
            "PLATFORM_ADMIN",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "PLATFORM_ADMIN",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "PLATFORM_ADMIN",
            PortalPermission.USER_MANAGE,
            True,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.DASHBOARD_VIEW,
            True,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.ORGANIZATION_MANAGE,
            False,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.USER_MANAGE,
            True,
        ),
        (
            "ORG_ADMIN",
            PortalPermission.ORGANIZATION_MANAGE,
            False,
        ),
        (
            "OPERATOR",
            PortalPermission.DASHBOARD_VIEW,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.COMMISSIONING_EXECUTE,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.USER_MANAGE,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.DASHBOARD_VIEW,
            True,
        ),
        (
            "VIEWER",
            PortalPermission.COMMISSIONING_EXECUTE,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.COMMISSIONING_EXECUTE,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.USER_MANAGE,
            False,
        ),
        (
            "PLATFORM_ADMIN",
            PortalPermission.ORGANIZATION_MANAGE,
            True,
        ),
        (
            "OPERATOR",
            PortalPermission.ORGANIZATION_MANAGE,
            False,
        ),
        (
            "VIEWER",
            PortalPermission.ORGANIZATION_MANAGE,
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
        is PortalPermission.DASHBOARD_VIEW
    )


def test_review_submission_requires_submit_permission() -> None:
    assert (
        required_permission_for_request(
            "POST",
            "/onboarding/review",
        )
        is PortalPermission.COMMISSIONING_EXECUTE
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
        is PortalPermission.COMMISSIONING_EXECUTE
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
        is PortalPermission.ORGANIZATION_MANAGE
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
def test_unknown_write_routes_have_no_implicit_permission(
    method: str,
    path: str,
) -> None:
    assert required_permission_for_request(method, path) is None


CANONICAL_PERMISSION_CODES = {
    "organization.manage",
    "user.manage",
    "site.manage",
    "location.manage",
    "asset.manage",
    "gateway.manage",
    "device.manage",
    "relationship.manage",
    "metering_policy.manage",
    "commissioning.execute",
    "alert.acknowledge",
    "dashboard.view",
    "report.export",
    "audit.view",
}


def test_story_3_2_exposes_all_canonical_permissions() -> None:
    assert {
        permission.value
        for permission in PortalPermission
    } == CANONICAL_PERMISSION_CODES


@pytest.mark.parametrize(
    ("role", "expected_codes"),
    [
        (
            PortalRole.PLATFORM_ADMIN,
            CANONICAL_PERMISSION_CODES,
        ),
        (
            PortalRole.ORG_ADMIN,
            CANONICAL_PERMISSION_CODES
            - {"organization.manage"},
        ),
        (
            PortalRole.OPERATOR,
            {
                "site.manage",
                "location.manage",
                "asset.manage",
                "gateway.manage",
                "device.manage",
                "relationship.manage",
                "metering_policy.manage",
                "commissioning.execute",
                "alert.acknowledge",
                "dashboard.view",
                "report.export",
            },
        ),
        (
            PortalRole.VIEWER,
            {
                "dashboard.view",
                "report.export",
            },
        ),
    ],
)
def test_story_3_2_role_permission_mapping_is_declarative(
    role: PortalRole,
    expected_codes: set[str],
) -> None:
    assert {
        permission.value
        for permission in ROLE_PERMISSIONS[role]
    } == expected_codes


@pytest.mark.parametrize(
    ("path", "permission"),
    [
        (
            "/administration/sites",
            PortalPermission.SITE_MANAGE,
        ),
        (
            "/administration/locations",
            PortalPermission.LOCATION_MANAGE,
        ),
    ],
)
def test_epic_four_writes_require_explicit_permissions(
    path: str,
    permission: PortalPermission,
) -> None:
    assert (
        required_permission_for_request("POST", path)
        is permission
    )


@pytest.mark.parametrize(
    "path",
    [
        "/administration/sites",
        "/administration/locations",
    ],
)
def test_epic_four_reads_require_dashboard_access(
    path: str,
) -> None:
    assert (
        required_permission_for_request("GET", path)
        is PortalPermission.DASHBOARD_VIEW
    )


def test_asset_administration_write_requires_asset_manage() -> None:
    assert (
        required_permission_for_request(
            "POST",
            "/administration/assets",
        )
        is PortalPermission.ASSET_MANAGE
    )


def test_asset_administration_read_requires_dashboard_access() -> None:
    assert (
        required_permission_for_request(
            "GET",
            "/administration/assets",
        )
        is PortalPermission.DASHBOARD_VIEW
    )
