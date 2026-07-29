from collections.abc import Callable

import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.service import (
    AuthenticationResult,
    AuthenticationStatus,
)
from src.auth.authorization import (
    PortalPermission,
    required_permission_for_request,
)


ORG_ID = "11111111-1111-4111-8111-111111111111"
OTHER_ORG_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
SITE_ID = "22222222-2222-4222-8222-222222222222"


def authentication_result(
    *,
    role_code: str,
) -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=1,
            username="admin@example.com",
            display_name="Administrator",
            role_code=role_code,
            organization_id=(
                None if role_code == "PLATFORM_ADMIN" else ORG_ID
            ),
            access_scope_mode=(
                None if role_code == "PLATFORM_ADMIN" else "ORGANIZATION"
            ),
            site_ids=(),
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def install_authenticator(
    monkeypatch: pytest.MonkeyPatch,
    role_code: str,
) -> None:
    async def fake_authenticate(username: str, password: str):
        return authentication_result(role_code=role_code)

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )


def login(portal_client, role_code: str, monkeypatch) -> None:
    install_authenticator(monkeypatch, role_code)
    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/administration",
        },
    )
    assert response.status_code == 303


@pytest.mark.parametrize(
    "path",
    [
        "/context/organization",
        "/context/organization/clear",
        "/context/site",
        "/context/site/clear",
        "/context/location",
        "/context/location/clear",
    ],
)
def test_context_writes_are_explicitly_permission_mapped(path: str) -> None:
    assert (
        required_permission_for_request("POST", path)
        is PortalPermission.DASHBOARD_VIEW
    )


def test_context_route_requires_authentication(portal_client) -> None:
    response = portal_client.post(
        "/context/organization",
        data={"organization_id": ORG_ID},
    )

    assert response.status_code == 303
    assert response.headers["location"].startswith(
        "/login?next_path="
    )


def test_platform_login_starts_without_tenant_context(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    install_authenticator(monkeypatch, "PLATFORM_ADMIN")

    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/administration",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/administration/organizations"


def test_tenant_login_bootstraps_assigned_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "ORG_ADMIN", monkeypatch)

    response = portal_client.post("/context/site/clear")

    assert response.status_code == 303
    assert response.headers["location"] == "/administration/sites"
    assert "no-store" in response.headers["cache-control"]


def test_platform_can_select_accessible_organization(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "PLATFORM_ADMIN", monkeypatch)

    async def fake_organizations(**kwargs):
        return [{"id": ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )

    response = portal_client.post(
        "/context/organization",
        data={
            "organization_id": ORG_ID,
            "return_to": "/administration",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/administration"
    assert "no-store" in response.headers["cache-control"]


def test_platform_can_clear_organization_and_return_safely(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "PLATFORM_ADMIN", monkeypatch)

    response = portal_client.post(
        "/context/organization/clear",
        data={"return_to": "/administration/users"},
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/administration/users"
    assert "no-store" in response.headers["cache-control"]


def test_clear_organization_rejects_external_return_path(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "PLATFORM_ADMIN", monkeypatch)

    response = portal_client.post(
        "/context/organization/clear",
        data={"return_to": "https://evil.example"},
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        "/administration/organizations"
    )


def test_inaccessible_organization_fails_safely(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "PLATFORM_ADMIN", monkeypatch)

    async def fake_organizations(**kwargs):
        return [{"id": ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )

    response = portal_client.post(
        "/context/organization",
        data={"organization_id": OTHER_ORG_ID},
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        "/administration/organizations?context_error=1"
    )


def test_external_return_path_is_rejected(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login(portal_client, "PLATFORM_ADMIN", monkeypatch)

    async def fake_organizations(**kwargs):
        return [{"id": ORG_ID}]

    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )

    response = portal_client.post(
        "/context/organization",
        data={
            "organization_id": ORG_ID,
            "return_to": "https://evil.example",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/administration"
