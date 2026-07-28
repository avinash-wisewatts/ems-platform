"""Route tests for the Device onboarding step.

All database-backed repositories and persistence operations are replaced with
deterministic test doubles. The production FastAPI lifespan is not entered.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("10101010-1010-4010-8010-101010101010")
ORGANIZATION_ID = UUID("20202020-2020-4020-8020-202020202020")
SITE_ID = UUID("30303030-3030-4030-8030-303030303030")
GATEWAY_ID = UUID("40404040-4040-4040-8040-404040404040")
OTHER_GATEWAY_ID = UUID("50505050-5050-4050-8050-505050505050")

DEVICE_ID = UUID("60606060-6060-4060-8060-606060606060")
INCOMPLETE_DEVICE_ID = UUID(
    "70707070-7070-4070-8070-707070707070"
)
OTHER_DEVICE_ID = UUID("80808080-8080-4080-8080-808080808080")

CATEGORY_ID = UUID("90909090-9090-4090-8090-909090909090")
OTHER_CATEGORY_ID = UUID(
    "abababab-abab-4bab-8bab-abababababab"
)
PROFILE_ID = UUID("bcbcbcbc-bcbc-4cbc-8cbc-bcbcbcbcbcbc")


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=304,
            username="device.operator@example.com",
            display_name="Device Test Operator",
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
            "username": "device.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/device",
        },
    )

    assert response.status_code == 303


def create_new_gateway_draft(
    *,
    include_device: bool = False,
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
            "existing_gateway_id": None,
            "name": "New Gateway",
            "external_id": "NEW_GATEWAY",
            "vendor": "Eniscope",
            "model": "Eniscope Gateway",
            "protocol": "MQTT",
        },
    }

    if include_device:
        payload["device"] = {
            "mode": "CREATE_NEW",
            "existing_device_id": None,
            "name": "Restored Energy Meter",
            "external_id": "RESTORED_ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
            "model_vendor": "Eniscope",
            "model": "Eniscope Energy Meter",
            "protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "firmware_version": "4.2",
            "identifier": {
                "type": "MQTT_UID",
                "value": "80:34:28:16:09:eb:00:01",
            },
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def existing_gateway_draft(
    *,
    include_device: bool = False,
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
            "existing_gateway_id": str(GATEWAY_ID),
        },
    }

    if include_device:
        payload["device"] = {
            "mode": "USE_EXISTING",
            "existing_device_id": str(DEVICE_ID),
            "identifier": {
                "type": "MQTT_UID",
                "value": "80:34:28:16:09:eb:00:01",
            },
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


def device_categories() -> list[dict]:
    return [
        {
            "id": CATEGORY_ID,
            "name": "Energy Meter",
            "description": "Electrical energy meter",
        },
        {
            "id": OTHER_CATEGORY_ID,
            "name": "Environmental Sensor",
            "description": "Environmental telemetry sensor",
        },
    ]


def device_profiles(
    *,
    compatible_category_ids: list[UUID] | None = None,
) -> list[dict]:
    return [
        {
            "id": PROFILE_ID,
            "profile_code": "ENISCOPE_V4",
            "profile_name": "Eniscope Version 4",
            "manufacturer": "Eniscope",
            "model": "Energy Meter",
            "firmware_version": None,
            "description": "Eniscope telemetry profile",
            "device_category_ids": (
                compatible_category_ids
                if compatible_category_ids is not None
                else [CATEGORY_ID]
            ),
            "device_category_names": ["Energy Meter"],
        }
    ]


def all_devices() -> list[dict]:
    return [
        {
            "id": DEVICE_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "organization_name": "Existing Organization",
            "gateway_id": GATEWAY_ID,
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "site_name": "Existing Site",
            "gateway_external_id": "EXISTING_GATEWAY",
            "gateway_name": "Existing Gateway",
            "device_model_id": UUID(
                "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"
            ),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_category_id": CATEGORY_ID,
            "device_category_name": "Energy Meter",
            "profile_id": PROFILE_ID,
            "profile_code": "ENISCOPE_V4",
            "profile_name": "Eniscope Version 4",
            "external_id": "EXISTING_DEVICE",
            "device_name": "Existing Energy Meter",
            "serial_number": None,
            "firmware_version": "4.1",
            "protocol": "MQTT",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
        {
            "id": INCOMPLETE_DEVICE_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "organization_name": "Existing Organization",
            "gateway_id": GATEWAY_ID,
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "site_name": "Existing Site",
            "gateway_external_id": "EXISTING_GATEWAY",
            "gateway_name": "Existing Gateway",
            "device_model_id": None,
            "device_vendor": None,
            "device_model": None,
            "device_category_id": None,
            "device_category_name": None,
            "profile_id": None,
            "profile_code": None,
            "profile_name": None,
            "external_id": "INCOMPLETE_DEVICE",
            "device_name": "Incomplete Device",
            "serial_number": None,
            "firmware_version": None,
            "protocol": "MQTT",
            "identifier_type": None,
            "identifier_value": None,
        },
        {
            "id": OTHER_DEVICE_ID,
            "organization_id": ORGANIZATION_ID,
            "organization_code": "EXISTING_ORG",
            "organization_name": "Existing Organization",
            "gateway_id": OTHER_GATEWAY_ID,
            "site_id": SITE_ID,
            "site_code": "EXISTING_SITE",
            "site_name": "Existing Site",
            "gateway_external_id": "OTHER_GATEWAY",
            "gateway_name": "Other Gateway",
            "device_model_id": UUID(
                "dededede-dede-4ede-8ede-dededededede"
            ),
            "device_vendor": "Other Vendor",
            "device_model": "Other Meter",
            "device_category_id": CATEGORY_ID,
            "device_category_name": "Energy Meter",
            "profile_id": PROFILE_ID,
            "profile_code": "ENISCOPE_V4",
            "profile_name": "Eniscope Version 4",
            "external_id": "OTHER_DEVICE",
            "device_name": "Other Gateway Device",
            "serial_number": None,
            "firmware_version": None,
            "protocol": "MQTT",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:02",
        },
    ]


def install_device_catalogs(
    monkeypatch: pytest.MonkeyPatch,
    *,
    categories: list[dict] | None = None,
    profiles: list[dict] | None = None,
    devices: list[dict] | None = None,
) -> None:
    async def fake_list_gateways() -> list[dict]:
        return [
            {
                "id": GATEWAY_ID,
                "organization_id": ORGANIZATION_ID,
                "site_id": SITE_ID,
                "gateway_name": "Existing Gateway",
                "external_id": "EXISTING_GATEWAY",
            }
        ]

    async def fake_list_devices() -> list[dict]:
        return all_devices() if devices is None else devices

    async def fake_list_categories() -> list[dict]:
        return (
            device_categories()
            if categories is None
            else categories
        )

    async def fake_list_models() -> list[dict]:
        return [
            {
                "id": UUID(
                    "efefefef-efef-4fef-8fef-efefefefefef"
                ),
                "vendor": "Eniscope",
                "model": "Eniscope Energy Meter",
                "device_type": "ENERGY_METER",
                "created_at": None,
                "device_category_id": CATEGORY_ID,
                "device_category_name": "Energy Meter",
            }
        ]

    async def fake_list_profiles() -> list[dict]:
        return (
            device_profiles()
            if profiles is None
            else profiles
        )

    monkeypatch.setattr(
        "src.main.list_gateways",
        fake_list_gateways,
    )
    monkeypatch.setattr(
        "src.main.list_devices",
        fake_list_devices,
    )
    monkeypatch.setattr(
        "src.main.list_device_categories",
        fake_list_categories,
    )
    monkeypatch.setattr(
        "src.main.list_device_models",
        fake_list_models,
    )
    monkeypatch.setattr(
        "src.main.list_device_profiles",
        fake_list_profiles,
    )


def test_device_get_rejects_invalid_draft_token(
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
        "/onboarding/device?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_device_get_returns_not_found_for_invisible_draft(
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
        f"/onboarding/device?draft={DRAFT_TOKEN}"
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
    ],
)
def test_device_get_redirects_to_missing_prerequisite(
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
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"{expected_path}?draft={DRAFT_TOKEN}"
    )


def test_device_get_renders_create_new_context_and_catalogs(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "New Gateway" in response.text
    assert "NEW_GATEWAY" in response.text
    assert "Energy Meter" in response.text
    assert "Eniscope Energy Meter" in response.text
    assert "ENISCOPE_V4" in response.text
    assert "New gateway or no existing devices" in response.text


def test_device_get_filters_incomplete_and_other_gateway_devices(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Gateway" in response.text
    assert "Existing Energy Meter" in response.text
    assert "EXISTING_DEVICE" in response.text
    assert "Incomplete Device" not in response.text
    assert "INCOMPLETE_DEVICE" not in response.text
    assert "Other Gateway Device" not in response.text
    assert "OTHER_DEVICE" not in response.text
    assert 'id="existing_identifier_type"' in response.text
    assert 'readonly' in response.text
    assert 'data-identifier-type="MQTT_UID"' in response.text
    assert 'data-identifier-value="80:34:28:16:09:eb:00:01"' in response.text
    assert 'name="identifier_type"' not in response.text.split(
        'id="existing_identifier_type"', 1
    )[1].split('id="create_device_fields"', 1)[0]


def test_device_get_restores_saved_device_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(include_device=True),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.get(
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Energy Meter" in response.text
    assert "RESTORED_ENERGY_METER" in response.text
    assert "Eniscope Energy Meter" in response.text
    assert "ENISCOPE_V4" in response.text
    assert "4.2" in response.text
    assert "80:34:28:16:09:eb:00:01" in response.text


def test_device_post_create_new_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

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
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "existing_device_id": "",
            "device_name": "  Chiller Energy Meter  ",
            "device_external_id": "  chiller_energy_meter  ",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "  Eniscope  ",
            "device_model": "  Eniscope Energy Meter  ",
            "device_protocol": "  mqtt  ",
            "profile_code": "  eniscope_v4  ",
            "firmware_version": "  4.2  ",
            "identifier_type": "  mqtt_uid  ",
            "identifier_value": "80:34:28:16:09:EB:00:01",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/asset?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": DRAFT_TOKEN,
        "step": "device",
        "step_payload": {
            "mode": "CREATE_NEW",
            "existing_device_id": None,
            "name": "Chiller Energy Meter",
            "external_id": "CHILLER_ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
            "model_vendor": "Eniscope",
            "model": "Eniscope Energy Meter",
            "protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "firmware_version": "4.2",
            "identifier": {
                "type": "MQTT_UID",
                "value": "80:34:28:16:09:eb:00:01",
            },
        },
        "next_step": "asset",
    }


def test_device_post_use_existing_uses_stored_identity_and_ignores_tampering(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

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
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(DEVICE_ID),
            "identifier_type": "FORGED_TYPE",
            "identifier_value": "forged-value",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING",
        "existing_device_id": str(DEVICE_ID),
        "name": None,
        "external_id": None,
        "device_category_id": None,
        "model_vendor": None,
        "model": None,
        "protocol": None,
        "profile_code": None,
        "firmware_version": None,
        "identifier": {
            "type": "MQTT_UID",
            "value": "80:34:28:16:09:eb:00:01",
        },
    }


def test_device_post_rejects_existing_device_for_new_gateway(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(DEVICE_ID),
            "identifier_type": "",
            "identifier_value": "",
        },
    )

    assert response.status_code == 422
    assert (
        "An existing device can only be selected when the "
        "gateway already exists."
        in response.text
    )


def test_device_post_rejects_unknown_existing_device(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    unknown_device_id = UUID(
        "cacacaca-caca-4aca-8aca-cacacacacaca"
    )

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(unknown_device_id),
            "identifier_type": "",
            "identifier_value": "",
        },
    )

    assert response.status_code == 422
    assert "The selected device does not exist." in response.text


def test_device_post_rejects_device_from_another_gateway(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "USE_EXISTING",
            "existing_device_id": str(OTHER_DEVICE_ID),
            "identifier_type": "",
            "identifier_value": "",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected device does not belong to the chosen gateway."
        in response.text
    )


def test_device_post_rejects_unknown_category(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch, categories=[])

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "device_name": "Energy Meter",
            "device_external_id": "ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected device category does not exist."
        in response.text
    )


def test_device_post_rejects_unknown_profile(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch, profiles=[])

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "device_name": "Energy Meter",
            "device_external_id": "ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected telemetry profile does not exist."
        in response.text
    )


def test_device_post_rejects_incompatible_profile(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(
        monkeypatch,
        profiles=device_profiles(
            compatible_category_ids=[OTHER_CATEGORY_ID]
        ),
    )

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "device_name": "Energy Meter",
            "device_external_id": "ENERGY_METER",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
    )

    assert response.status_code == 422
    assert (
        "The selected telemetry profile is not compatible "
        "with the chosen device category."
        in response.text
    )


def test_device_post_validation_error_preserves_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "device_name": "Preserved Device",
            "device_external_id": "INVALID-ID",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "Preserved Vendor",
            "device_model": "Preserved Model",
            "device_protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "firmware_version": "4.5",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
    )

    assert response.status_code == 422
    assert "Preserved Device" in response.text
    assert "INVALID-ID" in response.text
    assert "Preserved Vendor" in response.text
    assert "Preserved Model" in response.text
    assert "4.5" in response.text
    assert "Device external ID" in response.text


def test_device_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_gateway_draft(),
    )
    install_device_catalogs(monkeypatch)

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced device persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/device",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "device_mode": "CREATE_NEW",
            "device_name": "Database Failure Device",
            "device_external_id": "DATABASE_FAILURE_DEVICE",
            "device_category_id": str(CATEGORY_ID),
            "device_vendor": "Eniscope",
            "device_model": "Eniscope Energy Meter",
            "device_protocol": "MQTT",
            "profile_code": "ENISCOPE_V4",
            "firmware_version": "",
            "identifier_type": "MQTT_UID",
            "identifier_value": "80:34:28:16:09:eb:00:01",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Device" in response.text
    assert "DATABASE_FAILURE_DEVICE" in response.text
