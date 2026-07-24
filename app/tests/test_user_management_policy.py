import pytest

from src.auth.authorization import (
    PortalRole,
    assignable_portal_roles,
    can_assign_portal_role,
)


@pytest.mark.parametrize(
    ("actor_role", "expected_roles"),
    [
        (
            PortalRole.PLATFORM_ADMIN,
            {
                PortalRole.PLATFORM_ADMIN,
                PortalRole.ORG_ADMIN,
                PortalRole.OPERATOR,
                PortalRole.VIEWER,
            },
        ),
        (
            PortalRole.ORG_ADMIN,
            {
                PortalRole.ORG_ADMIN,
                PortalRole.OPERATOR,
                PortalRole.VIEWER,
            },
        ),
        (
            PortalRole.OPERATOR,
            set(),
        ),
        (
            PortalRole.VIEWER,
            set(),
        ),
    ],
)
def test_assignable_portal_roles(
    actor_role: PortalRole,
    expected_roles: set[PortalRole],
) -> None:
    assert assignable_portal_roles(actor_role) == expected_roles


@pytest.mark.parametrize(
    ("actor_role", "target_role", "expected"),
    [
        (
            PortalRole.PLATFORM_ADMIN,
            PortalRole.PLATFORM_ADMIN,
            True,
        ),
        (
            PortalRole.PLATFORM_ADMIN,
            PortalRole.ORG_ADMIN,
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            PortalRole.ORG_ADMIN,
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            PortalRole.OPERATOR,
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            PortalRole.VIEWER,
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            PortalRole.PLATFORM_ADMIN,
            False,
        ),
        (
            PortalRole.OPERATOR,
            PortalRole.VIEWER,
            False,
        ),
        (
            PortalRole.VIEWER,
            PortalRole.VIEWER,
            False,
        ),
    ],
)
def test_role_assignment_policy(
    actor_role: PortalRole,
    target_role: PortalRole,
    expected: bool,
) -> None:
    assert can_assign_portal_role(
        actor_role,
        target_role,
    ) is expected


@pytest.mark.parametrize(
    (
        "actor_role",
        "actor_organization_id",
        "target_organization_id",
        "expected",
    ),
    [
        (
            PortalRole.PLATFORM_ADMIN,
            None,
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.PLATFORM_ADMIN,
            None,
            None,
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.ORG_ADMIN,
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            False,
        ),
        (
            PortalRole.ORG_ADMIN,
            "11111111-1111-1111-1111-111111111111",
            None,
            False,
        ),
        (
            PortalRole.ORG_ADMIN,
            None,
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
        (
            PortalRole.OPERATOR,
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
        (
            PortalRole.VIEWER,
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
    ],
)
def test_user_management_tenant_scope(
    actor_role: PortalRole,
    actor_organization_id: str | None,
    target_organization_id: str | None,
    expected: bool,
) -> None:
    from src.auth.authorization import can_manage_user_in_organization

    assert can_manage_user_in_organization(
        actor_role=actor_role,
        actor_organization_id=actor_organization_id,
        target_organization_id=target_organization_id,
    ) is expected
