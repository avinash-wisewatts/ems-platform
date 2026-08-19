"""Route tests for the Asset onboarding step.

All database-backed repositories and persistence operations are replaced with
deterministic test doubles. The production FastAPI lifespan is not entered.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("11112222-3333-4444-8555-666677778888")
ORGANIZATION_ID = UUID("22223333-4444-4555-8666-777788889999")
SITE_ID = UUID("33334444-5555-4666-8777-888899990000")
DEVICE_ID = UUID("44445555-6666-4777-8888-999900001111")
CATEGORY_ID = UUID("55556666-7777-4888-8999-000011112222")
ASSET_TYPE_ID = UUID("66667777-8888-4999-8000-111122223333")
ASSET_ID = UUID("77778888-9999-4000-8111-222233334444")

OTHER_ORGANIZATION_ID = UUID(
    "88889999-0000-4111-8222-333344445555"
)
OTHER_SITE_ID = UUID("99990000-1111-4222-8333-444455556666")
OTHER_ASSET_ID = UUID("aaaa1111-2222-4333-8444-555566667777")
CHILD_ASSET_ID = UUID("bbbb2222-3333-4444-8555-666677778888")
INACTIVE_ASSET_ID = UUID(
    "cccc3333-4444-4555-8666-777788889999"
)


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=305,
            username="asset.operator@example.com",
            display_name="Asset Test Operator",
            role_code="OPERATOR",

            organization_id=(
                "11111111-1111-1111-1111-111111111111"
            ),
            access_scope_mode="ORGANIZATION",
            site_ids=(),
        ),
        status=AuthenticationStatus.AUTHENTICATED,
    )


def login_operator(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_authenticate(
        username: str,
        password: str,
    ) -> AuthenticationResult:
        return successful_result()

    monkeypatch.setattr(
        "src.main.authenticate_portal_user",
        fake_authenticate,
    )

    response = portal_client.post(
        "/login",
        data={
            "username": "asset.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/asset",
        },
    )

    assert response.status_code == 303


def create_new_device_draft(
    *,
    include_asset: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "CREATE_NEW",
            "name": "New Organization",
            "code": "NEW_ORGANIZATION",
        },
        "site": {
            "mode": "CREATE_NEW",
            "name": "New Site",
            "code": "NEW_SITE",
        },
        "location": {
            "mode": "SITE_ONLY",
        },
        "gateway": {
            "mode": "CREATE_NEW",
            "name": "New Gateway",
            "external_id": "NEW_GATEWAY",
        },
        "device": {
            "mode": "CREATE_NEW",
            "existing_device_id": None,
            "name": "New Energy Meter",
            "external_id": "NEW_ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
        },
    }

    if include_asset:
        payload["asset"] = {
            "mode": "CREATE_NEW",
            "existing_asset_id": None,
            "name": "Restored Chiller",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "metadata": {
                "operational_notes": "Restored operational notes",
            },
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def existing_device_draft(
    *,
    include_asset: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "USE_EXISTING",
            "existing_organization_id": str(ORGANIZATION_ID),
        },
        "site": {
            "mode": "USE_EXISTING",
            "existing_site_id": str(SITE_ID),
        },
        "location": {
            "mode": "SITE_ONLY",
        },
        "gateway": {
            "mode": "USE_EXISTING",
            "existing_gateway_id": str(
                UUID("dddd4444-5555-4666-8777-888899990000")
            ),
        },
        "device": {
            "mode": "USE_EXISTING",
            "existing_device_id": str(DEVICE_ID),
        },
    }

    if include_asset:
        payload["asset"] = {
            "mode": "USE_EXISTING",
            "existing_asset_id": str(ASSET_ID),
            "name": None,
            "asset_type_id": None,

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "metadata": {},
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def install_visible_draft(
    monkeypatch: pytest.MonkeyPatch,
    draft_record: dict | None,
) -> None:
    async def fake_get_visible_draft(
        request,
        draft_token: UUID,
    ) -> dict | None:
        assert draft_token == DRAFT_TOKEN
        return draft_record

    monkeypatch.setattr(
        "src.main.get_visible_onboarding_draft",
        fake_get_visible_draft,
    )


def asset_types() -> list[dict]:
    return [
        {
            "id": ASSET_TYPE_ID,
            "name": "Chiller",
            "description": "Water-cooled chiller",
        }
    ]


def device_categories() -> list[dict]:
    return [
        {
            "id": CATEGORY_ID,
            "name": "Energy Meter",
            "description": "Electrical energy meter",
        }
    ]


def devices() -> list[dict]:
    return [
        {
            "id": DEVICE_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "organization_name": "Existing Organization",
            "gateway_id": UUID(
                "dddd4444-5555-4666-8777-888899990000"
            ),
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "site_name": "Existing Site",
            "gateway_external_id": "EXISTING_GATEWAY",
            "gateway_name": "Existing Gateway",
            "device_model_id": UUID(
                "eeee5555-6666-4777-8888-999900001111"
            ),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_category_id": CATEGORY_ID,
            "device_category_name": "Energy Meter",
            "profile_id": UUID(
                "ffff6666-7777-4888-8999-000011112222"
            ),
            "profile_code": "ENISCOPE_V4",
            "profile_name": "Eniscope Version 4",
            "external_id": "EXISTING_DEVICE",
            "device_name": "Existing Energy Meter",
            "serial_number": None,
            "firmware_version": "4.1",
            "protocol": "MQTT",
        }
    ]


def assets() -> list[dict]:
    return [
        {
            "id": ASSET_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "space_id": None,
            "parent_asset_id": None,
            "asset_type_id": ASSET_TYPE_ID,

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "asset_type_name": "Chiller",
            "asset_name": "Existing Chiller",
            "asset_external_id": "TEST_ASSET",
            "status": "active",
        },
        {
            "id": OTHER_ASSET_ID,
            "organization_id": OTHER_ORGANIZATION_ID,
            "organization_code": "OTHER_ORG",
            "site_id": OTHER_SITE_ID,
            "site_code": "OTHER_SITE",
            "space_id": None,
            "parent_asset_id": None,
            "asset_type_id": ASSET_TYPE_ID,

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "asset_type_name": "Chiller",
            "asset_name": "Other Tenant Chiller",
            "asset_external_id": "TEST_ASSET",
            "status": "active",
        },
        {
            "id": CHILD_ASSET_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "space_id": None,
            "parent_asset_id": ASSET_ID,
            "asset_type_id": ASSET_TYPE_ID,

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "asset_type_name": "Chiller",
            "asset_name": "Child Asset",
            "asset_external_id": "TEST_ASSET",
            "status": "active",
        },
        {
            "id": INACTIVE_ASSET_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "space_id": None,
            "parent_asset_id": None,
            "asset_type_id": ASSET_TYPE_ID,

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "asset_type_name": "Chiller",
            "asset_name": "Inactive Asset",
            "asset_external_id": "TEST_ASSET",
            "status": "inactive",
        },
    ]


def install_asset_catalogs(
    monkeypatch: pytest.MonkeyPatch,
    *,
    asset_type_rows: list[dict] | None = None,
    category_rows: list[dict] | None = None,
    device_rows: list[dict] | None = None,
    asset_rows: list[dict] | None = None,
) -> None:
    async def fake_list_asset_types(site_id: str | None = None) -> list[dict]:
        return (
            asset_types()
            if asset_type_rows is None
            else asset_type_rows
        )

    async def fake_list_device_categories() -> list[dict]:
        return (
            device_categories()
            if category_rows is None
            else category_rows
        )

    async def fake_list_devices() -> list[dict]:
        return devices() if device_rows is None else device_rows

    async def fake_list_assets() -> list[dict]:
        return assets() if asset_rows is None else asset_rows

    monkeypatch.setattr(
        "src.main.list_asset_types",
        fake_list_asset_types,
    )
    monkeypatch.setattr(
        "src.main.list_device_categories",
        fake_list_device_categories,
    )
    monkeypatch.setattr(
        "src.main.list_devices",
        fake_list_devices,
    )
    monkeypatch.setattr(
        "src.main.list_assets",
        fake_list_assets,
    )


def test_asset_get_rejects_invalid_draft_token(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        "/onboarding/asset?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_asset_get_returns_not_found_for_invisible_draft(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, None)

    async def fake_list_organizations() -> list[dict]:
        return []

    monkeypatch.setattr(
        "src.main.list_organizations",
        fake_list_organizations,
    )

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 404
    assert (
        "The onboarding draft was not found or has expired."
        in response.text
    )


@pytest.mark.parametrize(
    ("payload", "expected_path"),
    [
        ({}, "/onboarding/organization"),
        (
            {"organization": {"mode": "CREATE_NEW"}},
            "/onboarding/site",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
            },
            "/onboarding/location",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
                "location": {"mode": "SITE_ONLY"},
            },
            "/onboarding/gateway",
        ),
        (
            {
                "organization": {"mode": "CREATE_NEW"},
                "site": {"mode": "CREATE_NEW"},
                "location": {"mode": "SITE_ONLY"},
                "gateway": {"mode": "CREATE_NEW"},
            },
            "/onboarding/device",
        ),
    ],
)
def test_asset_get_redirects_to_missing_prerequisite(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
    payload: dict,
    expected_path: str,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        {
            "draft_token": DRAFT_TOKEN,
            "payload": payload,
        },
    )

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"{expected_path}?draft={DRAFT_TOKEN}"
    )


def test_asset_get_renders_create_new_device_context(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "New Energy Meter" in response.text
    assert "NEW_ENERGY_METER" in response.text
    assert "Device category: Energy Meter" in response.text
    assert "Primary Meter" in response.text
    assert "Secondary Meter" in response.text
    assert "Chiller" in response.text


def test_asset_get_filters_assets_by_tenant_site_root_and_status(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Energy Meter" in response.text
    assert "EXISTING_DEVICE" in response.text
    assert "Existing Chiller" in response.text
    assert "Other Tenant Chiller" not in response.text
    assert "Child Asset" not in response.text
    assert "Inactive Asset" not in response.text


def test_asset_get_restores_saved_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(include_asset=True),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Chiller" in response.text
    assert str(ASSET_TYPE_ID) in response.text
    assert "Restored operational notes" in response.text
    assert "PRIMARY_METER" in response.text


def test_asset_get_redirects_when_existing_device_disappears(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch, device_rows=[])

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )


def test_asset_get_redirects_when_new_device_category_disappears(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch, category_rows=[])

    response = portal_client.get(
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )


def test_asset_post_create_new_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    captured: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        captured.update(
            {
                "draft_token": draft_token,
                "step": step,
                "step_payload": step_payload,
                "next_step": next_step,
            }
        )
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "existing_asset_id": "",
            "asset_name": "  Chiller 1  ",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "  primary_meter  ",
            "operational_notes": (
                "  270 TR water-cooled chiller  "
            ),
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/review?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": DRAFT_TOKEN,
        "step": "asset",
        "step_payload": {
            "mode": "CREATE_NEW",
            "existing_asset_id": None,
            "name": "Chiller 1",
            "external_id": "CHILLER_1",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "metadata": {
                "operational_notes": (
                    "270 TR water-cooled chiller"
                )
            },
            "lifecycle_status": "ACTIVE",
            "parent_asset_id": None,
        },
        "next_step": "review",
    }


def test_asset_post_use_existing_saves_identity_and_relationship(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    async def fake_validate_relationship(**kwargs):
        assert kwargs["asset_id"] == str(ASSET_ID)
        assert kwargs["relationship_type"] == "SECONDARY_METER"
        assert kwargs["device_id"] == str(DEVICE_ID)
        return {"valid": True}

    monkeypatch.setattr(
        "src.main.validate_asset_relationship_availability",
        fake_validate_relationship,
    )

    captured_payload: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": str(ASSET_ID),
            "asset_name": "Discarded",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "SECONDARY_METER",
            "operational_notes": "Discarded",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING",
        "existing_asset_id": str(ASSET_ID),
        "name": None,
        "external_id": None,
        "asset_type_id": None,

        "metering_requirement": None,
        "relationship_type": "SECONDARY_METER",
        "metadata": {},
        "lifecycle_status": None,
        "parent_asset_id": None,
    }


def test_asset_post_rejects_existing_asset_for_new_parents(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        },
    )

    assert response.status_code == 422
    assert (
        "An existing asset can only be selected when both the "
        "organization and site already exist."
        in response.text
    )


def test_asset_post_rejects_unknown_existing_asset(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    unknown_asset_id = UUID(
        "dddd1111-2222-4333-8444-555566667777"
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": str(unknown_asset_id),
            "relationship_type": "PRIMARY_METER",
        },
    )

    assert response.status_code == 422
    assert "The selected asset does not exist." in response.text


def test_asset_post_rejects_cross_tenant_asset(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "USE_EXISTING",
            "existing_asset_id": str(OTHER_ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected asset does not belong to the chosen "
        "organization and site."
        in response.text
    )


def test_asset_post_rejects_unknown_asset_type(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch, asset_type_rows=[])

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "asset_name": "Chiller 1",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "operational_notes": "",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected asset type does not exist."
        in response.text
    )


def test_asset_post_rejects_invalid_relationship_for_category(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "asset_name": "Chiller 1",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "TEMPERATURE_SENSOR",
            "operational_notes": "",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected relationship is not valid for device "
        "category Energy Meter."
        in response.text
    )


def test_asset_post_rejects_unconfigured_device_category(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)

    draft = create_new_device_draft()
    draft["payload"]["device"]["device_category_id"] = str(
        CATEGORY_ID
    )

    install_visible_draft(monkeypatch, draft)
    install_asset_catalogs(
        monkeypatch,
        category_rows=[
            {
                "id": CATEGORY_ID,
                "name": "Unsupported Device Category",
                "description": None,
            }
        ],
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "asset_name": "Unsupported Asset",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "operational_notes": "",
        },
    )

    assert response.status_code == 422
    assert (
        "No asset relationship rules are configured for device "
        "category Unsupported Device Category."
        in response.text
    )


def test_asset_post_validation_error_preserves_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "asset_name": "Preserved Chiller",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": "not-a-uuid",

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "operational_notes": "Preserved operational notes",
        },
    )

    assert response.status_code == 422
    assert "Preserved Chiller" in response.text
    assert "Preserved operational notes" in response.text
    assert "PRIMARY_METER" in response.text
    assert "Select an asset type." in response.text


def test_asset_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced asset persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "asset_name": "Database Failure Chiller",
            "asset_external_id": "TEST_ASSET",
            "asset_type_id": str(ASSET_TYPE_ID),

            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "operational_notes": "Database failure notes",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Chiller" in response.text
    assert "Database failure notes" in response.text


def test_asset_post_create_new_rejects_existing_primary_meter_device(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_device_draft(),
    )
    install_asset_catalogs(monkeypatch)

    validation_calls: list[dict] = []
    save_called = False

    async def fake_validate_relationship(**kwargs):
        validation_calls.append(kwargs)
        return {
            "valid": False,
            "code": "DEVICE_PRIMARY_METER_ASSIGNED",
            "message": (
                "This device is already the primary meter "
                "for another asset."
            ),
        }

    async def fake_save_owned_step(*args, **kwargs):
        nonlocal save_called
        save_called = True
        raise AssertionError(
            "The draft must not advance when relationship "
            "validation fails."
        )

    monkeypatch.setattr(
        "src.main.validate_asset_relationship_availability",
        fake_validate_relationship,
    )
    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/asset",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "asset_mode": "CREATE_NEW",
            "existing_asset_id": "",
            "asset_name": "Home Lights",
            "asset_external_id": "HOME_LIGHTS",
            "asset_type_id": str(ASSET_TYPE_ID),
            "metering_requirement": "DIRECT_METER_REQUIRED",
            "relationship_type": "PRIMARY_METER",
            "operational_notes": "",
        },
    )

    assert response.status_code == 422
    assert save_called is False
    assert validation_calls == [
        {
            "actor_portal_user_id": 305,
            "asset_id": None,
            "relationship_type": "PRIMARY_METER",
            "device_id": str(DEVICE_ID),
        }
    ]
    assert (
        "This device is already the primary meter "
        "for another asset."
        in response.text
    )



def test_relationship_validation_reports_primary_meter_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, existing_device_draft())

    async def fake_validate(**kwargs):
        assert kwargs["actor_portal_user_id"] == 305
        assert kwargs["asset_id"] == str(ASSET_ID)
        assert kwargs["relationship_type"] == "PRIMARY_METER"
        assert kwargs["device_id"] == str(DEVICE_ID)
        return {
            "valid": False,
            "code": "PRIMARY_METER_EXISTS",
            "message": "This asset already has a primary meter. Choose another relationship type.",
        }

    monkeypatch.setattr(
        "src.main.validate_asset_relationship_availability",
        fake_validate,
    )

    response = portal_client.get(
        "/onboarding/asset/relationship-validation",
        params={
            "draft": str(DRAFT_TOKEN),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        },
    )

    assert response.status_code == 409
    assert response.json()["code"] == "PRIMARY_METER_EXISTS"


def test_relationship_validation_reports_exact_duplicate(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, existing_device_draft())

    async def fake_validate(**kwargs):
        assert kwargs["actor_portal_user_id"] == 305
        assert kwargs["asset_id"] == str(ASSET_ID)
        assert kwargs["relationship_type"] == "PRIMARY_METER"
        assert kwargs["device_id"] == str(DEVICE_ID)
        return {
            "valid": False,
            "code": "RELATIONSHIP_ALREADY_EXISTS",
            "message": (
                "The selected device already has this relationship "
                "with the selected asset."
            ),
        }

    monkeypatch.setattr(
        "src.main.validate_asset_relationship_availability",
        fake_validate,
    )

    response = portal_client.get(
        "/onboarding/asset/relationship-validation",
        params={
            "draft": str(DRAFT_TOKEN),
            "asset_id": str(ASSET_ID),
            "relationship_type": "PRIMARY_METER",
        },
    )

    assert response.status_code == 409
    assert (
        response.json()["code"]
        == "RELATIONSHIP_ALREADY_EXISTS"
    )
    assert "already has this relationship" in (
        response.json()["message"]
    )



def test_relationship_validation_accepts_available_relationship(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(monkeypatch, create_new_device_draft())

    async def fake_validate(**kwargs):
        assert kwargs["device_id"] is None
        return {"valid": True}

    monkeypatch.setattr(
        "src.main.validate_asset_relationship_availability",
        fake_validate,
    )

    response = portal_client.get(
        "/onboarding/asset/relationship-validation",
        params={
            "draft": str(DRAFT_TOKEN),
            "asset_id": str(ASSET_ID),
            "relationship_type": "TEMPERATURE_SENSOR",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"valid": True}
