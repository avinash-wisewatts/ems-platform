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
BUILDING_ID = UUID(
    "33333333-3333-4333-8333-333333333333"
)
FLOOR_ID = UUID(
    "44444444-4444-4444-8444-444444444444"
)
SPACE_ID = UUID(
    "55555555-5555-4555-8555-555555555555"
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

    async def fake_organizations(**kwargs) -> list[dict]:
        return [
            {
                "id": ORGANIZATION_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_name": "Organization One",
                "organization_code": "ORG_1",
            }
        ]

    async def fake_sites(**kwargs) -> list[dict]:
        return [
            {
                "id": SITE_ID,
                "site_id": SITE_ID,
                "organization_id": ORGANIZATION_ID,
                "site_name": "Main Site",
                "site_code": "SITE_1",
            }
        ]

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )
    monkeypatch.setattr(
        "src.context.service._accessible_organizations",
        fake_organizations,
    )
    monkeypatch.setattr(
        "src.context.service._accessible_sites",
        fake_sites,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "admin@example.com",
            "password": "valid-password",
            "next_path": "/administration/locations",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        "/administration/organizations"
    )

    organization_response = portal_client.post(
        "/context/organization",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "return_to": "/administration/sites",
        },
    )

    assert organization_response.status_code == 303
    assert organization_response.headers["location"] == (
        "/administration/sites"
    )

    site_response = portal_client.post(
        "/context/site",
        data={
            "site_id": str(SITE_ID),
            "return_to": "/administration/locations",
        },
    )

    assert site_response.status_code == 303
    assert site_response.headers["location"] == (
        "/administration/locations"
    )


def hierarchy_rows() -> list[dict]:
    return [
        {
            "organization_id": ORGANIZATION_ID,
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "site_id": SITE_ID,
            "site_code": "SITE_1",
            "site_name": "Main Site",
            "building_id": BUILDING_ID,
            "building_code": "BUILDING_A",
            "building_name": "Building A",
            "floor_id": FLOOR_ID,
            "floor_code": "FLOOR_1",
            "floor_name": "First Floor",
            "space_id": SPACE_ID,
            "space_code": "PLANT_ROOM",
            "space_name": "Plant Room",
        }
    ]


@pytest.fixture(autouse=True)
def mock_location_page_reads(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list_locations(
        *,
        portal_user_id: int,
    ) -> list[dict]:
        assert portal_user_id == 500
        return hierarchy_rows()

    monkeypatch.setattr(
        "src.main.list_accessible_physical_locations",
        fake_list_locations,
    )


def test_location_administration_get_renders_hierarchy_and_forms(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.get("/administration/locations")

    assert response.status_code == 200
    assert "Accessible hierarchy" in response.text
    assert "Main Site" in response.text
    assert "Building A" in response.text
    assert "First Floor" in response.text
    assert "Plant Room" in response.text
    assert "Create building" in response.text
    assert "Create floor" in response.text
    assert "Create space" in response.text


@pytest.mark.parametrize(
    (
        "location_type",
        "parent_id",
        "name",
        "code",
        "service_name",
        "expected_arguments",
        "entity_type",
        "entity_id",
    ),
    [
        (
            "BUILDING",
            SITE_ID,
            "Building B",
            "IGNORED_CLIENT_BUILDING",
            "create_building",
            {
                "portal_user_id": 500,
                "site_id": str(SITE_ID),
                "name": "Building B",
                "code": "BUILDING_B",
            },
            "BUILDING",
            BUILDING_ID,
        ),
        (
            "FLOOR",
            BUILDING_ID,
            "Second Floor",
            "IGNORED_CLIENT_FLOOR",
            "create_floor",
            {
                "portal_user_id": 500,
                "building_id": str(BUILDING_ID),
                "name": "Second Floor",
                "code": "SECOND_FLOOR",
            },
            "FLOOR",
            FLOOR_ID,
        ),
        (
            "SPACE",
            FLOOR_ID,
            "Office",
            "IGNORED_CLIENT_SPACE",
            "create_space",
            {
                "portal_user_id": 500,
                "floor_id": str(FLOOR_ID),
                "name": "Office",
                "code": "OFFICE",
            },
            "SPACE",
            SPACE_ID,
        ),
    ],
)
def test_location_administration_creates_each_location_type(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    location_type: str,
    parent_id: UUID,
    name: str,
    code: str,
    service_name: str,
    expected_arguments: dict,
    entity_type: str,
    entity_id: UUID,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_create(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": entity_type,
            "entity_id": str(entity_id),
            f"{entity_type.lower()}_id": str(entity_id),
            "lifecycle_status": "ACTIVE",
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "66666666-6666-4666-8666-666666666666"
            ),
        }

    monkeypatch.setattr(
        f"src.main.{service_name}",
        fake_create,
    )

    response = portal_client.post(
        "/administration/locations",
        data={
            "location_type": location_type,
            "parent_id": str(parent_id),
            "location_name": name,
            "location_code": code,
        },
    )

    assert response.status_code == 201
    assert f"{entity_type.title()} created" in response.text
    assert str(entity_id) in response.text
    assert captured == expected_arguments


def test_location_administration_rejects_unknown_type(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        "/administration/locations",
        data={
            "location_type": "CAMPUS",
            "parent_id": str(SITE_ID),
            "location_name": "Campus",
            "location_code": "CAMPUS",
        },
    )

    assert response.status_code == 400
    assert "Select a valid location type." in response.text


def test_location_administration_rejects_invalid_parent(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        "/administration/locations",
        data={
            "location_type": "BUILDING",
            "parent_id": "",
            "location_name": "Building B",
            "location_code": "BUILDING_B",
        },
    )

    assert response.status_code == 400
    assert "Site is required." in response.text


def test_location_administration_handles_database_error(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    async def fake_create_building(**kwargs):
        raise UniqueViolation(
            "Building code BUILDING_A already exists."
        )

    monkeypatch.setattr(
        "src.main.create_building",
        fake_create_building,
    )

    response = portal_client.post(
        "/administration/locations",
        data={
            "location_type": "BUILDING",
            "parent_id": str(SITE_ID),
            "location_name": "Building A",
            "location_code": "BUILDING_A",
        },
    )

    assert response.status_code == 409
    assert "database rejected the location request" in response.text.lower()
