import pytest

from src.admin_navigation import administration_navigation
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


def item_labels(
    role_code: str,
    access_scope_mode: str | None = None,
) -> set[str]:
    return {
        item.label
        for section in administration_navigation(
            role_code,
            access_scope_mode,
        )
        for item in section.items
    }


def test_super_admin_sees_platform_navigation() -> None:
    labels = item_labels("ADMIN", "GLOBAL")

    assert "Organizations" in labels
    assert "Users" in labels
    assert "Onboarding" in labels


def test_org_admin_sees_user_management_but_not_platform_management() -> None:
    labels = item_labels("ADMIN", "ORGANIZATION")

    assert "Users" in labels
    assert "Organizations" not in labels


@pytest.mark.parametrize(
    "role_code",
    ["OPERATOR", "VIEWER", "UNKNOWN"],
)
def test_non_platform_roles_do_not_see_platform_navigation(
    role_code: str,
) -> None:
    labels = item_labels(role_code)

    assert "Organizations" not in labels
    assert "Users" not in labels
    assert "Sites" in labels
    assert "Onboarding" in labels


def login_as(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    role_code: str,
    *,
    access_scope_mode: str,
    organization_id: str | None,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return AuthenticationResult(
            authenticated=True,
            user=AuthenticatedPortalUser(
                portal_user_id=400,
                username=f"{role_code.lower()}@example.com",
                display_name=f"Test {role_code}",
                role_code=role_code,

                organization_id=organization_id,
                access_scope_mode=access_scope_mode,
                site_ids=(),
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
            "username": f"{role_code.lower()}@example.com",
            "password": "valid-password",
            "next_path": "/administration",
        },
    )

    assert response.status_code == 303
    expected_location = (
        "/administration/organizations"
        if access_scope_mode == "GLOBAL"
        else "/administration"
    )
    assert response.headers["location"] == expected_location


def test_operator_workspace_hides_platform_items(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "OPERATOR",
        access_scope_mode="ORGANIZATION",
        organization_id="11111111-1111-1111-1111-111111111111",
    )

    response = portal_client.get("/administration")

    assert response.status_code == 200
    assert "Administration workspace" in response.text
    assert "Organizations" not in response.text
    assert "Users" not in response.text
    assert "Open onboarding" in response.text


def test_super_admin_workspace_shows_platform_items(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "ADMIN",
        access_scope_mode="GLOBAL",
        organization_id=None,
    )

    response = portal_client.get("/administration")

    assert response.status_code == 200
    assert "Organizations" in response.text
    assert "Users" in response.text
    assert 'href="/onboarding"' in response.text



def test_org_admin_workspace_hides_platform_items(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "ADMIN",
        access_scope_mode="ORGANIZATION",
        organization_id="11111111-1111-1111-1111-111111111111",
    )

    response = portal_client.get("/administration")

    assert response.status_code == 200
    assert "Organizations" not in response.text
    assert "Users" in response.text
    assert "Open onboarding" in response.text


@pytest.mark.parametrize(
    ("item_key", "expected_href"),
    [
        ("sites", "/administration/sites"),
        ("locations", "/administration/locations"),
    ],
)
def test_epic_four_navigation_items_are_enabled(
    item_key: str,
    expected_href: str,
) -> None:
    items = {
        item.key: item
        for section in administration_navigation("ADMIN")
        for item in section.items
    }

    assert items[item_key].href == expected_href


def test_assets_navigation_item_is_enabled() -> None:
    items = {
        item.key: item
        for section in administration_navigation("ADMIN")
        for item in section.items
    }

    assert items["assets"].href == "/administration/assets"
