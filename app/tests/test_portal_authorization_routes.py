import pytest

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


async def authenticate_as(
    role_code: str,
) -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=200,
            username=f"{role_code.lower()}@example.com",
            display_name=f"Test {role_code}",
            role_code=role_code,
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_as(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    role_code: str,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return await authenticate_as(role_code)

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": f"{role_code.lower()}@example.com",
            "password": "valid-password",
            "next_path": "/",
        },
    )

    assert response.status_code == 303


@pytest.mark.parametrize(
    "write_path",
    [
        "/onboarding/organization",
        "/onboarding/site",
        "/onboarding/location",
        "/onboarding/gateway",
        "/onboarding/device",
        "/onboarding/asset",
    ],
)
def test_viewer_is_blocked_from_onboarding_writes(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    write_path: str,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "VIEWER",
    )

    response = portal_client.post(
        write_path,
        data={},
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"


def test_viewer_can_reach_forbidden_page(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "VIEWER",
    )

    response = portal_client.get("/forbidden")

    assert response.status_code == 403
    assert "viewer@example.com" in response.text
    assert "VIEWER" in response.text


def test_operator_unknown_write_route_fails_closed(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "OPERATOR",
    )

    response = portal_client.patch(
        "/not-a-real-admin-route"
    )

    # Authorization fails before route resolution because unknown writes
    # require MANAGE_PORTAL_USERS.
    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"


def test_super_admin_unknown_route_reaches_router(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "SUPER_ADMIN",
    )

    response = portal_client.patch(
        "/not-a-real-admin-route"
    )

    # SUPER_ADMIN passes authorization; FastAPI then reports no such route.
    assert response.status_code == 404

@pytest.mark.parametrize(
    "role_code",
    [
        "OPERATOR",
        "VIEWER",
    ],
)
def test_non_super_admin_cannot_manage_organizations(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    role_code: str,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        role_code,
    )

    response = portal_client.post(
        "/administration/organizations",
        data={},
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/forbidden"


def test_super_admin_organization_write_reaches_router(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_as(
        portal_client,
        monkeypatch,
        "SUPER_ADMIN",
    )

    response = portal_client.post(
        "/administration/organizations",
        data={},
    )

    # SUPER_ADMIN passes authorization and reaches the real route.
    # FastAPI rejects the empty form because required fields are missing.
    assert response.status_code == 422
