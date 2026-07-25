from uuid import UUID

import pytest
from psycopg.errors import UniqueViolation

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


ORGANIZATION_ID = UUID(
    "11111111-1111-4111-8111-111111111111"
)
SITE_ID = UUID(
    "22222222-2222-4222-8222-222222222222"
)


def successful_platform_admin_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=500,
            username="admin@example.com",
            display_name="Platform Admin",
            role_code="PLATFORM_ADMIN",
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_platform_admin(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return successful_platform_admin_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/administration/sites",
        },
    )

    assert response.status_code == 303


@pytest.fixture(autouse=True)
def mock_site_page_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list_organizations() -> list[dict]:
        return [
            {
                "id": ORGANIZATION_ID,
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "description": None,
                "is_active": True,
            }
        ]

    async def fake_list_locations(
        *,
        portal_user_id: int,
    ) -> list[dict]:
        assert portal_user_id == 500
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        "src.main.list_accessible_physical_locations",
        fake_list_locations,
    )


def test_site_administration_get_renders_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.get("/administration/sites")

    assert response.status_code == 200
    assert "Create site" in response.text
    assert "Organization One" in response.text
    assert "ORG_1" in response.text
    assert "Asia/Kolkata" in response.text
    assert "Lifecycle status" in response.text


def test_site_administration_post_creates_site(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_create_site(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": "SITE",
            "entity_id": str(SITE_ID),
            "site_id": str(SITE_ID),
            "lifecycle_status": "ACTIVE",
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "33333333-3333-4333-8333-333333333333"
            ),
        }

    monkeypatch.setattr(
        "src.main.create_site",
        fake_create_site,
    )

    response = portal_client.post(
        "/administration/sites",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "site_name": "Main Site",
            "site_code": "main_site",
            "site_timezone": "Europe/London",
            "lifecycle_status": "ACTIVE",
        },
    )

    assert response.status_code == 201
    assert "Site created" in response.text
    assert str(SITE_ID) in response.text

    assert captured == {
        "portal_user_id": 500,
        "organization_id": str(ORGANIZATION_ID),
        "name": "Main Site",
        "code": "MAIN_SITE",
        "timezone": "Europe/London",
        "lifecycle_status": "ACTIVE",
    }


def test_site_administration_rejects_invalid_timezone(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        "/administration/sites",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "site_name": "Main Site",
            "site_code": "MAIN_SITE",
            "site_timezone": "Invalid/Timezone",
            "lifecycle_status": "ACTIVE",
        },
    )

    assert response.status_code == 400
    assert "valid IANA timezone" in response.text
    assert "Main Site" in response.text


def test_site_administration_preserves_form_on_database_error(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    async def fake_create_site(**kwargs):
        raise UniqueViolation(
            "Site code MAIN_SITE already exists."
        )

    monkeypatch.setattr(
        "src.main.create_site",
        fake_create_site,
    )

    response = portal_client.post(
        "/administration/sites",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "site_name": "Main Site",
            "site_code": "MAIN_SITE",
            "site_timezone": "Europe/London",
            "lifecycle_status": "ACTIVE",
        },
    )

    assert response.status_code == 409
    assert "Main Site" in response.text
    assert "MAIN_SITE" in response.text
    assert "Europe/London" in response.text


def test_site_administration_lists_accessible_sites(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    async def fake_list_locations(
        *,
        portal_user_id: int,
    ) -> list[dict]:
        return [
            {
                "organization_id": ORGANIZATION_ID,
                "organization_code": "ORG_1",
                "organization_name": "Organization One",
                "site_id": SITE_ID,
                "site_code": "SITE_1",
                "site_name": "Site One",
                "building_id": None,
                "building_code": None,
                "building_name": None,
                "floor_id": None,
                "floor_code": None,
                "floor_name": None,
                "space_id": None,
                "space_code": None,
                "space_name": None,
            }
        ]

    monkeypatch.setattr(
        "src.main.list_accessible_physical_locations",
        fake_list_locations,
    )

    response = portal_client.get("/administration/sites")

    assert response.status_code == 200
    assert "Site One" in response.text
    assert "SITE_1" in response.text
    assert str(SITE_ID) in response.text
