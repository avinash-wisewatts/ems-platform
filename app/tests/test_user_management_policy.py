import pytest

from src.auth.authorization import (
    PortalRole,
    assignable_portal_roles,
    can_assign_portal_role,
    can_manage_user_in_scope,
)


@pytest.mark.parametrize(
    ("actor_role", "expected_roles"),
    [
        (
            PortalRole.ADMIN,
            {
                PortalRole.ADMIN,
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
            PortalRole.ADMIN,
            PortalRole.ADMIN,
            True,
        ),
        (
            PortalRole.ADMIN,
            PortalRole.OPERATOR,
            True,
        ),
        (
            PortalRole.ADMIN,
            PortalRole.VIEWER,
            True,
        ),
        (
            PortalRole.OPERATOR,
            PortalRole.ADMIN,
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
        "actor_access_scope_mode",
        "actor_organization_id",
        "target_organization_id",
        "expected",
    ),
    [
        (
            PortalRole.ADMIN,
            "GLOBAL",
            None,
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.ADMIN,
            "GLOBAL",
            None,
            None,
            True,
        ),
        (
            PortalRole.ADMIN,
            "ORGANIZATION",
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.ADMIN,
            "SELECTED_SITES",
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.ADMIN,
            "ORGANIZATION",
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            False,
        ),
        (
            PortalRole.ADMIN,
            "ORGANIZATION",
            "11111111-1111-1111-1111-111111111111",
            None,
            False,
        ),
        (
            PortalRole.ADMIN,
            "GLOBAL",
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            True,
        ),
        (
            PortalRole.OPERATOR,
            "GLOBAL",
            None,
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
        (
            PortalRole.VIEWER,
            "ORGANIZATION",
            "11111111-1111-1111-1111-111111111111",
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
        (
            PortalRole.ADMIN,
            None,
            None,
            "11111111-1111-1111-1111-111111111111",
            False,
        ),
    ],
)
def test_user_management_scope_policy(
    actor_role: PortalRole,
    actor_access_scope_mode: str | None,
    actor_organization_id: str | None,
    target_organization_id: str | None,
    expected: bool,
) -> None:
    assert can_manage_user_in_scope(
        actor_role=actor_role,
        actor_access_scope_mode=actor_access_scope_mode,
        actor_organization_id=actor_organization_id,
        target_organization_id=target_organization_id,
    ) is expected
