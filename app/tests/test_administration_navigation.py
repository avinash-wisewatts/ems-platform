import pytest

from src.admin_navigation import administration_navigation
from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


def item_labels(role_code: str) -> set[str]:
    return {
        item.label
        for section in administration_navigation(role_code)
        for item in section.items
    }


def test_super_admin_sees_platform_navigation() -> None:
    labels = item_labels("PLATFORM_ADMIN")

    assert "Organizations" in labels
    assert "Users" in labels
    assert "Onboarding" in labels


def test_org_admin_sees_user_management_but_not_platform_management() -> None:
    labels = item_labels("ORG_ADMIN")

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
                organization_id=(
                    None
                    if role_code == "PLATFORM_ADMIN"
                    else "11111111-1111-1111-1111-111111111111"
                ),
                access_scope_mode=(
                    None
                    if role_code == "PLATFORM_ADMIN"
                    else "ORGANIZATION"
                ),
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
    assert response.headers["location"] == "/administration"


def test_operator_workspace_hides_platform_items(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(portal_client, monkeypatch, "OPERATOR")

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
    login_as(portal_client, monkeypatch, "PLATFORM_ADMIN")

    response = portal_client.get("/administration")

    assert response.status_code == 200
    assert "Organizations" in response.text
    assert "Users" in response.text
    assert 'href="/onboarding"' in response.text



def test_org_admin_workspace_hides_platform_items(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(portal_client, monkeypatch, "ORG_ADMIN")

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
        for section in administration_navigation("ORG_ADMIN")
        for item in section.items
    }

    assert items[item_key].href == expected_href
