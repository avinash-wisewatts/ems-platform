import re

from src.admin_navigation import administration_navigation
from src.auth.authorization import (
    PortalPermission,
    required_permission_for_request,
)


def navigation_item(
    role_code: str,
    key: str,
):
    return next(
        (
            item
            for section in administration_navigation(role_code)
            for item in section.items
            if item.key == key
        ),
        None,
    )


def test_platform_admin_navigation_links_to_user_management() -> None:
    item = navigation_item("PLATFORM_ADMIN", "users")

    assert item is not None
    assert item.href == "/administration/users"


def test_org_admin_navigation_links_to_user_management() -> None:
    item = navigation_item("ORG_ADMIN", "users")

    assert item is not None
    assert item.href == "/administration/users"


def test_operator_navigation_hides_user_management() -> None:
    assert navigation_item("OPERATOR", "users") is None


def test_viewer_navigation_hides_user_management() -> None:
    assert navigation_item("VIEWER", "users") is None


def test_create_user_route_requires_user_manage() -> None:
    assert required_permission_for_request(
        "POST",
        "/administration/users",
    ) is PortalPermission.USER_MANAGE


def test_role_change_route_requires_user_manage() -> None:
    assert required_permission_for_request(
        "POST",
        "/administration/users/42/role",
    ) is PortalPermission.USER_MANAGE


def test_status_change_route_requires_user_manage() -> None:
    assert required_permission_for_request(
        "POST",
        "/administration/users/42/status",
    ) is PortalPermission.USER_MANAGE


def login_as_user_manager(
    portal_client,
    monkeypatch,
    *,
    role_code: str,
    organization_id: str | None,
) -> None:
    from src.auth.models import AuthenticatedPortalUser
    from src.auth.security import AuthenticationStatus
    from src.auth.service import AuthenticationResult

    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=700,
                username=username,
                display_name="User Manager",
                role_code=role_code,
                organization_id=organization_id,
            ),
            status=AuthenticationStatus.AUTHENTICATED,
        )

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "manager@example.com",
            "password": "valid-password",
            "next_path": "/administration/users",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/administration/users"


def test_platform_admin_can_open_user_management_page(
    portal_client,
    monkeypatch,
) -> None:
    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="PLATFORM_ADMIN",
        organization_id=None,
    )

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        assert actor_portal_user_id == 700
        return []

    async def fake_list_organizations():
        return []

    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )
    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get("/administration/users")

    assert response.status_code == 200
    assert "User management" in response.text
    assert "Create user" in response.text
    assert re.search(
        r'class="sidebar-link\s+is-active"\s+href="/administration/users"',
        response.text,
    )


def test_org_admin_page_excludes_platform_admin_role(
    portal_client,
    monkeypatch,
) -> None:
    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        assert actor_portal_user_id == 700
        return []

    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )

    response = portal_client.get("/administration/users")

    assert response.status_code == 200
    assert 'value="ORG_ADMIN"' in response.text
    assert 'value="OPERATOR"' in response.text
    assert 'value="VIEWER"' in response.text
    assert 'value="PLATFORM_ADMIN"' not in response.text


def test_org_admin_can_create_user_in_own_organization(
    portal_client,
    monkeypatch,
) -> None:
    organization_id = "11111111-1111-1111-1111-111111111111"

    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=organization_id,
    )

    created: dict = {}

    async def fake_create_managed_user(**kwargs):
        created.update(kwargs)
        return 801

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return []

    monkeypatch.setattr(
        "src.main.create_managed_user",
        fake_create_managed_user,
    )
    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )
    monkeypatch.setattr(
        "src.main.hash_portal_password",
        lambda password: f"hashed:{password}",
    )

    response = portal_client.post(
        "/administration/users",
        data={
            "display_name": "New Viewer",
            "username": "viewer@example.com",
            "email": "viewer@example.com",
            "password": "ValidPassword123!",
            "role_code": "VIEWER",
        },
    )

    assert response.status_code == 201
    assert created == {
        "actor_portal_user_id": 700,
        "username": "viewer@example.com",
        "display_name": "New Viewer",
        "email": "viewer@example.com",
        "password_hash": "hashed:ValidPassword123!",
        "role_code": "VIEWER",
        "organization_id": organization_id,
    }


def test_org_admin_cannot_assign_platform_admin(
    portal_client,
    monkeypatch,
) -> None:
    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    async def fail_if_called(**kwargs):
        raise AssertionError("Service must not be called.")

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return []

    monkeypatch.setattr(
        "src.main.create_managed_user",
        fail_if_called,
    )
    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )

    response = portal_client.post(
        "/administration/users",
        data={
            "display_name": "Invalid Admin",
            "username": "admin@example.com",
            "email": "admin@example.com",
            "password": "ValidPassword123!",
            "role_code": "PLATFORM_ADMIN",
        },
    )

    assert response.status_code == 400
    assert "cannot assign" in response.text.lower()


def test_org_admin_can_change_user_role_in_own_organization(
    portal_client,
    monkeypatch,
) -> None:
    organization_id = "11111111-1111-1111-1111-111111111111"

    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=organization_id,
    )

    changed: dict = {}

    async def fake_change_managed_user_role(**kwargs):
        changed.update(kwargs)

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return []

    monkeypatch.setattr(
        "src.main.change_managed_user_role",
        fake_change_managed_user_role,
    )
    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )

    response = portal_client.post(
        "/administration/users/801/role",
        data={
            "role_code": "OPERATOR",
        },
    )

    assert response.status_code == 200
    assert changed == {
        "actor_portal_user_id": 700,
        "target_portal_user_id": 801,
        "role_code": "OPERATOR",
        "organization_id": organization_id,
    }


def test_org_admin_can_deactivate_user_in_own_organization(
    portal_client,
    monkeypatch,
) -> None:
    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=(
            "11111111-1111-1111-1111-111111111111"
        ),
    )

    changed: dict = {}

    async def fake_set_managed_user_active(**kwargs):
        changed.update(kwargs)

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return []

    monkeypatch.setattr(
        "src.main.set_managed_user_active",
        fake_set_managed_user_active,
    )
    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )

    response = portal_client.post(
        "/administration/users/801/status",
        data={
            "is_active": "false",
        },
    )

    assert response.status_code == 200
    assert changed == {
        "actor_portal_user_id": 700,
        "target_portal_user_id": 801,
        "is_active": False,
    }


def test_platform_admin_page_shows_organization_selector(
    portal_client,
    monkeypatch,
) -> None:
    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="PLATFORM_ADMIN",
        organization_id=None,
    )

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return []

    async def fake_list_organizations():
        return [
            {
                "id": "11111111-1111-1111-1111-111111111111",
                "organization_name": "Test Organization",
                "organization_code": "TEST_ORG",
            }
        ]

    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )
    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get("/administration/users")

    assert response.status_code == 200
    assert 'name="organization_id"' in response.text
    assert "Test Organization" in response.text
    assert (
        'value="11111111-1111-1111-1111-111111111111"'
        in response.text
    )


def test_user_rows_include_role_and_status_controls(
    portal_client,
    monkeypatch,
) -> None:
    organization_id = "11111111-1111-1111-1111-111111111111"

    login_as_user_manager(
        portal_client,
        monkeypatch,
        role_code="ORG_ADMIN",
        organization_id=organization_id,
    )

    async def fake_list_manageable_users(
        *,
        actor_portal_user_id: int,
    ):
        return [
            {
                "portal_user_id": 801,
                "username": "viewer@example.com",
                "display_name": "Test Viewer",
                "email": "viewer@example.com",
                "role_code": "VIEWER",
                "organization_id": organization_id,
                "is_active": True,
            }
        ]

    monkeypatch.setattr(
        "src.main.list_manageable_users",
        fake_list_manageable_users,
    )

    response = portal_client.get("/administration/users")

    assert response.status_code == 200
    assert (
        'action="/administration/users/801/role"'
        in response.text
    )
    assert (
        'action="/administration/users/801/status"'
        in response.text
    )
    assert 'value="OPERATOR"' in response.text
    assert 'value="false"' in response.text
