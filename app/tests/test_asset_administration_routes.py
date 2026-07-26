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
ASSET_TYPE_ID = UUID(
    "33333333-3333-4333-8333-333333333333"
)
PARENT_ASSET_ID = UUID(
    "44444444-4444-4444-8444-444444444444"
)
BUILDING_ID = UUID(
    "55555555-5555-4555-8555-555555555555"
)
FLOOR_ID = UUID(
    "66666666-6666-4666-8666-666666666666"
)
SPACE_ID = UUID(
    "77777777-7777-4777-8777-777777777777"
)
NEW_ASSET_ID = UUID(
    "88888888-8888-4888-8888-888888888888"
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
            "next_path": "/administration/assets",
        },
    )

    assert response.status_code == 303


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


def asset_rows() -> list[dict]:
    return [
        {
            "organization_id": ORGANIZATION_ID,
            "organization_code": "ORG_1",
            "organization_name": "Organization One",
            "site_id": SITE_ID,
            "site_code": "SITE_1",
            "site_name": "Main Site",
            "asset_id": PARENT_ASSET_ID,
            "asset_name": "Plant",
            "asset_type_id": ASSET_TYPE_ID,
            "asset_type_name": "Plant",
            "parent_asset_id": None,
            "parent_asset_name": None,
            "building_id": BUILDING_ID,
            "building_name": "Building A",
            "floor_id": FLOOR_ID,
            "floor_name": "First Floor",
            "space_id": SPACE_ID,
            "space_name": "Plant Room",
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "coverage_status": "NOT_REQUIRED",
        }
    ]


@pytest.fixture(autouse=True)
def mock_asset_page_reads(
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
        return hierarchy_rows()

    async def fake_list_assets(
        *,
        portal_user_id: int,
    ) -> list[dict]:
        assert portal_user_id == 500
        return asset_rows()

    async def fake_list_asset_types() -> list[dict]:
        return [
            {
                "id": ASSET_TYPE_ID,
                "name": "Chiller",
                "description": None,
                "is_active": True,
            }
        ]

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )
    monkeypatch.setattr(
        "src.main.list_accessible_physical_locations",
        fake_list_locations,
    )
    monkeypatch.setattr(
        "src.main.list_accessible_assets",
        fake_list_assets,
    )
    monkeypatch.setattr(
        "src.main.list_asset_types",
        fake_list_asset_types,
    )


def test_asset_administration_get_renders_inventory_and_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.get("/administration/assets")

    assert response.status_code == 200
    assert "Create asset" in response.text
    assert "Organization One" in response.text
    assert "Main Site" in response.text
    assert "Plant" in response.text
    assert "Chiller" in response.text
    assert "NOT_REQUIRED" in response.text


def test_asset_administration_creates_asset_with_optional_links(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_create_asset(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": "ASSET",
            "entity_id": str(NEW_ASSET_ID),
            "asset_id": str(NEW_ASSET_ID),
            "lifecycle_status": "ACTIVE",
            "commissioning_status": "INCOMPLETE",
            "validation_warnings": [],
            "blocking_conditions": [
                "MISSING_DIRECT_METER"
            ],
            "audit_transaction_id": (
                "99999999-9999-4999-8999-999999999999"
            ),
        }

    monkeypatch.setattr(
        "src.main.create_asset",
        fake_create_asset,
    )

    response = portal_client.post(
        "/administration/assets",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "asset_location_site_id": str(SITE_ID),
            "asset_name": "Main Chiller",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "DIRECT_METER_REQUIRED",
            "parent_asset_id": str(PARENT_ASSET_ID),
            "asset_location_building_id": str(BUILDING_ID),
            "asset_location_floor_id": str(FLOOR_ID),
            "asset_location_space_id": str(SPACE_ID),
        },
    )

    assert response.status_code == 201
    assert "Asset created" in response.text
    assert str(NEW_ASSET_ID) in response.text
    assert "MISSING_DIRECT_METER" in response.text

    assert captured == {
        "portal_user_id": 500,
        "organization_id": str(ORGANIZATION_ID),
        "site_id": str(SITE_ID),
        "asset_name": "Main Chiller",
        "asset_type_id": str(ASSET_TYPE_ID),
        "lifecycle_status": "ACTIVE",
        "metering_requirement": "DIRECT_METER_REQUIRED",
        "parent_asset_id": str(PARENT_ASSET_ID),
        "building_id": str(BUILDING_ID),
        "floor_id": str(FLOOR_ID),
        "space_id": str(SPACE_ID),
    }


def test_asset_administration_allows_asset_without_optional_links(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_create_asset(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": "ASSET",
            "entity_id": str(NEW_ASSET_ID),
            "asset_id": str(NEW_ASSET_ID),
            "lifecycle_status": "DRAFT",
            "commissioning_status": "NOT_REQUIRED",
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "99999999-9999-4999-8999-999999999999"
            ),
        }

    monkeypatch.setattr(
        "src.main.create_asset",
        fake_create_asset,
    )

    response = portal_client.post(
        "/administration/assets",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "asset_location_site_id": str(SITE_ID),
            "asset_name": "Unmetered Asset",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "DRAFT",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": "",
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 201
    assert captured["asset_type_id"] == str(ASSET_TYPE_ID)
    assert captured["parent_asset_id"] is None
    assert captured["building_id"] is None
    assert captured["floor_id"] is None
    assert captured["space_id"] is None


def test_asset_administration_rejects_invalid_hierarchy(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        "/administration/assets",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "asset_location_site_id": str(SITE_ID),
            "asset_name": "Invalid Asset",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": "",
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": str(SPACE_ID),
        },
    )

    assert response.status_code == 400
    assert "selected space requires its floor" in response.text


def test_asset_administration_preserves_form_on_database_error(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    async def fake_create_asset(**kwargs):
        raise UniqueViolation(
            "Asset already exists."
        )

    monkeypatch.setattr(
        "src.main.create_asset",
        fake_create_asset,
    )

    response = portal_client.post(
        "/administration/assets",
        data={
            "organization_id": str(ORGANIZATION_ID),
            "asset_location_site_id": str(SITE_ID),
            "asset_name": "Main Chiller",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "DIRECT_METER_REQUIRED",
            "parent_asset_id": "",
            "asset_location_building_id": str(BUILDING_ID),
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 409
    assert "Main Chiller" in response.text
    assert "DIRECT_METER_REQUIRED" in response.text
    assert "database rejected the asset request" in response.text.lower()


def test_asset_administration_updates_asset(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_update_asset(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": "ASSET",
            "entity_id": str(NEW_ASSET_ID),
            "asset_id": str(NEW_ASSET_ID),
            "lifecycle_status": "INACTIVE",
            "commissioning_status": "NOT_STARTED",
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "99999999-9999-4999-8999-999999999999"
            ),
        }

    monkeypatch.setattr(
        "src.main.update_asset",
        fake_update_asset,
    )

    response = portal_client.post(
        f"/administration/assets/{PARENT_ASSET_ID}",
        data={
            "asset_name": "Updated Plant",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "INACTIVE",
            "metering_requirement": "DIRECT_METER_REQUIRED",
            "parent_asset_id": "",
            "asset_location_site_id": str(SITE_ID),
            "asset_location_building_id": str(BUILDING_ID),
            "asset_location_floor_id": str(FLOOR_ID),
            "asset_location_space_id": str(SPACE_ID),
        },
    )

    assert response.status_code == 200
    assert captured == {
        "portal_user_id": 500,
        "asset_id": str(PARENT_ASSET_ID),
        "asset_name": "Updated Plant",
        "asset_type_id": str(ASSET_TYPE_ID),
        "lifecycle_status": "INACTIVE",
        "metering_requirement": "DIRECT_METER_REQUIRED",
        "parent_asset_id": None,
        "building_id": str(BUILDING_ID),
        "floor_id": str(FLOOR_ID),
        "space_id": str(SPACE_ID),
    }


def test_asset_administration_derives_immutable_ownership(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    captured: dict = {}

    async def fake_update_asset(**kwargs) -> dict:
        captured.update(kwargs)

        return {
            "success": True,
            "entity_type": "ASSET",
            "entity_id": str(PARENT_ASSET_ID),
            "asset_id": str(PARENT_ASSET_ID),
            "lifecycle_status": "ACTIVE",
            "commissioning_status": "COMMISSIONED",
            "validation_warnings": [],
            "blocking_conditions": [],
            "audit_transaction_id": (
                "99999999-9999-4999-8999-999999999999"
            ),
        }

    monkeypatch.setattr(
        "src.main.update_asset",
        fake_update_asset,
    )

    response = portal_client.post(
        f"/administration/assets/{PARENT_ASSET_ID}",
        data={
            "organization_id": (
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
            ),
            "site_id": (
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
            ),
            "asset_name": "Plant",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": "",
            "asset_location_site_id": str(SITE_ID),
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 200
    assert "organization_id" not in captured
    assert "site_id" not in captured


def test_asset_administration_rejects_self_parent(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        f"/administration/assets/{PARENT_ASSET_ID}",
        data={
            "asset_name": "Plant",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": str(PARENT_ASSET_ID),
            "asset_location_site_id": str(SITE_ID),
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 400
    assert "cannot be its own parent" in response.text.lower()


def test_asset_administration_surfaces_activation_block(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    async def fake_update_asset(**kwargs):
        raise UniqueViolation(
            "Use the controlled commissioning action to activate an asset."
        )

    monkeypatch.setattr(
        "src.main.update_asset",
        fake_update_asset,
    )

    response = portal_client.post(
        f"/administration/assets/{PARENT_ASSET_ID}",
        data={
            "asset_name": "Plant",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "ACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": "",
            "asset_location_site_id": str(SITE_ID),
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 409
    assert "database rejected the asset update" in response.text.lower()


def test_asset_administration_returns_404_for_inaccessible_asset(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_platform_admin(portal_client, monkeypatch)

    response = portal_client.post(
        "/administration/assets/"
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        data={
            "asset_name": "Hidden Asset",
            "asset_type_id": str(ASSET_TYPE_ID),
            "lifecycle_status": "INACTIVE",
            "metering_requirement": "NOT_REQUIRED",
            "parent_asset_id": "",
            "asset_location_site_id": str(SITE_ID),
            "asset_location_building_id": "",
            "asset_location_floor_id": "",
            "asset_location_space_id": "",
        },
    )

    assert response.status_code == 404
