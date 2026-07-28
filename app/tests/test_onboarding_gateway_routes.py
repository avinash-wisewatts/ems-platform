"""Route tests for the Gateway onboarding step.

All database-backed lookups and persistence calls are replaced with
deterministic test doubles. The production FastAPI lifespan is not entered.
"""

from uuid import UUID

import pytest
from psycopg.errors import DatabaseError

from src.auth.models import AuthenticatedPortalUser
from src.auth.security import AuthenticationStatus
from src.auth.service import AuthenticationResult


DRAFT_TOKEN = UUID("12121212-1212-4212-8212-121212121212")
ORGANIZATION_ID = UUID("23232323-2323-4232-8232-232323232323")
SITE_ID = UUID("34343434-3434-4343-8343-343434343434")
GATEWAY_ID = UUID("45454545-4545-4454-8454-454545454545")

OTHER_ORGANIZATION_ID = UUID(
    "56565656-5656-4565-8565-565656565656"
)
OTHER_SITE_ID = UUID("67676767-6767-4676-8676-676767676767")
OTHER_GATEWAY_ID = UUID(
    "78787878-7878-4787-8787-787878787878"
)


def successful_result() -> AuthenticationResult:
    return AuthenticationResult(
        authenticated=True,
        user=AuthenticatedPortalUser(
            portal_user_id=303,
            username="gateway.operator@example.com",
            display_name="Gateway Test Operator",
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
            "username": "gateway.operator@example.com",
            "password": "valid-password",
            "next_path": "/onboarding/gateway",
        },
    )

    assert response.status_code == 303


def create_new_parent_draft(
    *,
    include_gateway: bool = False,
) -> dict:
    payload = {
        "organization": {
            "mode": "CREATE_NEW",
            "existing_organization_id": None,
            "name": "New Organization",
            "code": "NEW_ORGANIZATION",
        },
        "site": {
            "mode": "CREATE_NEW",
            "existing_site_id": None,
            "name": "New Site",
            "code": "NEW_SITE",
        },
        "location": {
            "mode": "SITE_ONLY",
            "existing_space_id": None,
        },
    }

    if include_gateway:
        payload["gateway"] = {
            "mode": "CREATE_NEW",
            "existing_gateway_id": None,
            "name": "Restored Gateway",
            "external_id": "RESTORED_GATEWAY",
            "vendor": "Restored Vendor",
            "model": "Restored Model",
            "protocol": "HTTP API",
        }

    return {
        "draft_token": DRAFT_TOKEN,
        "payload": payload,
    }


def existing_parent_draft(
    *,
    include_gateway: bool = False,
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
            "existing_space_id": None,
        },
    }

    if include_gateway:
        payload["gateway"] = {
            "mode": "USE_EXISTING",
            "existing_gateway_id": str(GATEWAY_ID),
            "name": None,
            "external_id": None,
            "vendor": None,
            "model": None,
            "protocol": None,
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


def install_gateway_lists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_list_sites(request) -> list[dict]:
        return [
            {
                "id": SITE_ID,
                "organization_id": ORGANIZATION_ID,
                "site_code": "EXISTING_SITE",
                "site_name": "Existing Site",
            },
            {
                "id": OTHER_SITE_ID,
                "organization_id": OTHER_ORGANIZATION_ID,
                "site_code": "OTHER_SITE",
                "site_name": "Other Site",
            },
        ]

    async def fake_list_gateways() -> list[dict]:
        return [
            {
                "id": GATEWAY_ID,
                "organization_id": ORGANIZATION_ID,
                "organization_code": "EXISTING_ORG",
                "organization_name": "Existing Organization",
                "site_id": SITE_ID,
                "site_code": "EXISTING_SITE",
                "site_name": "Existing Site",
                "space_id": None,
                "space_code": None,
                "space_name": None,
                "gateway_model_id": UUID(
                    "89898989-8989-4898-8898-898989898989"
                ),
                "gateway_vendor": "Eniscope",
                "gateway_model": "Eniscope Gateway",
                "gateway_protocol": "MQTT",
                "external_id": "EXISTING_GATEWAY",
                "gateway_name": "Existing Gateway",
            },
            {
                "id": OTHER_GATEWAY_ID,
                "organization_id": OTHER_ORGANIZATION_ID,
                "organization_code": "OTHER_ORG",
                "organization_name": "Other Organization",
                "site_id": OTHER_SITE_ID,
                "site_code": "OTHER_SITE",
                "site_name": "Other Site",
                "space_id": None,
                "space_code": None,
                "space_name": None,
                "gateway_model_id": None,
                "gateway_vendor": "Other Vendor",
                "gateway_model": "Other Model",
                "gateway_protocol": "HTTP API",
                "external_id": "OTHER_GATEWAY",
                "gateway_name": "Other Gateway",
            },
        ]

    async def fake_list_gateway_models() -> list[dict]:
        return [
            {
                "id": UUID(
                    "90909090-9090-4909-8909-909090909090"
                ),
                "vendor": "Eniscope",
                "model": "Eniscope Gateway",
                "protocol": "MQTT",
                "created_at": None,
            }
        ]

    monkeypatch.setattr("src.main.list_sites_for_request", fake_list_sites)
    monkeypatch.setattr("src.main.list_gateways", fake_list_gateways)
    monkeypatch.setattr(
        "src.main.list_gateway_models",
        fake_list_gateway_models,
    )


def test_gateway_get_rejects_invalid_draft_token(
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
        "/onboarding/gateway?draft=not-a-uuid"
    )

    assert response.status_code == 400
    assert "The onboarding draft token is invalid." in response.text


def test_gateway_get_returns_not_found_for_invisible_draft(
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
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
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
            {
                "organization": {
                    "mode": "CREATE_NEW",
                }
            },
            "/onboarding/site",
        ),
        (
            {
                "organization": {
                    "mode": "CREATE_NEW",
                },
                "site": {
                    "mode": "CREATE_NEW",
                },
            },
            "/onboarding/location",
        ),
    ],
)
def test_gateway_get_redirects_to_missing_prerequisite(
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
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"{expected_path}?draft={DRAFT_TOKEN}"
    )


def test_gateway_get_renders_create_new_context_and_models(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.get(
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "New Site" in response.text
    assert "NEW_SITE" in response.text
    assert "Eniscope Gateway" in response.text
    assert "New site or no existing gateways" in response.text


def test_gateway_get_filters_existing_gateways_by_tenant_and_site(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.get(
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Existing Site" in response.text
    assert "Existing Gateway" in response.text
    assert "EXISTING_GATEWAY" in response.text
    assert "Other Gateway" not in response.text
    assert "OTHER_GATEWAY" not in response.text



def test_gateway_get_restores_saved_values(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(include_gateway=True),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.get(
        f"/onboarding/gateway?draft={DRAFT_TOKEN}"
    )

    assert response.status_code == 200
    assert "Restored Gateway" in response.text
    assert "Restored Vendor" in response.text
    assert "Restored Model" in response.text
    assert "HTTP API" in response.text
    assert 'name="gateway_external_id"' not in response.text

def test_gateway_post_create_new_saves_and_redirects(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

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
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "CREATE_NEW",
            "existing_gateway_id": "",
            "gateway_name": "  Chiller Gateway  ",
            "gateway_external_id": "  chiller_gateway  ",
            "gateway_vendor": "  Eniscope  ",
            "gateway_model": "  Eniscope Gateway  ",
            "gateway_protocol": "  mqtt  ",
        },
    )

    assert response.status_code == 303
    assert response.headers["location"] == (
        f"/onboarding/device?draft={DRAFT_TOKEN}"
    )

    assert captured == {
        "draft_token": DRAFT_TOKEN,
        "step": "gateway",
        "step_payload": {
            "mode": "CREATE_NEW",
            "existing_gateway_id": None,
            "name": "Chiller Gateway",
            "external_id": "CHILLER_GATEWAY",
            "vendor": "Eniscope",
            "model": "Eniscope Gateway",
            "protocol": "MQTT",
        },
        "next_step": "device",
    }


def test_gateway_post_use_existing_saves_only_identity(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    captured_payload: dict = {}

    async def fake_save_owned_step(
        request,
        *,
        draft_token: UUID,
        step: str,
        step_payload: dict,
        next_step: str,
    ) -> UUID:
        assert draft_token == DRAFT_TOKEN
        assert step == "gateway"
        assert next_step == "device"
        captured_payload.update(step_payload)
        return DRAFT_TOKEN

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": str(GATEWAY_ID),
            "gateway_name": "Discarded",
            "gateway_external_id": "DISCARDED",
            "gateway_vendor": "Discarded",
            "gateway_model": "Discarded",
            "gateway_protocol": "MQTT",
        },
    )

    assert response.status_code == 303
    assert captured_payload == {
        "mode": "USE_EXISTING",
        "existing_gateway_id": str(GATEWAY_ID),
        "name": None,
        "external_id": None,
        "vendor": None,
        "model": None,
        "protocol": None,
    }


def test_gateway_post_rejects_existing_gateway_for_new_parents(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": str(GATEWAY_ID),
        },
    )

    assert response.status_code == 422
    assert (
        "An existing gateway can only be selected when both the "
        "organization and site already exist."
        in response.text
    )


def test_gateway_post_rejects_unknown_gateway(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    unknown_gateway_id = UUID(
        "91919191-9191-4919-8919-919191919191"
    )

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": str(unknown_gateway_id),
        },
    )

    assert response.status_code == 422
    assert "The selected gateway does not exist." in response.text


def test_gateway_post_rejects_cross_tenant_gateway(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        existing_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "USE_EXISTING",
            "existing_gateway_id": str(OTHER_GATEWAY_ID),
        },
    )

    assert response.status_code == 422
    assert (
        "The selected gateway does not belong to the chosen "
        "organization and site."
        in response.text
    )



def test_gateway_post_validation_error_preserves_form(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "CREATE_NEW",
            "existing_gateway_id": "",
            "gateway_name": "Preserved Gateway",
            "gateway_external_id": "FORGED-CLIENT-ID",
            "gateway_vendor": "Preserved Vendor",
            "gateway_model": "Preserved Model",
            "gateway_protocol": "COAP",
        },
    )

    assert response.status_code == 422
    assert "Preserved Gateway" in response.text
    assert "Preserved Vendor" in response.text
    assert "Preserved Model" in response.text
    assert "supported cloud uplink protocol" in response.text
    assert "FORGED-CLIENT-ID" not in response.text
    assert 'name="gateway_external_id"' not in response.text

def test_gateway_post_database_failure_returns_controlled_conflict(
    portal_client,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    login_operator(portal_client, monkeypatch)
    install_visible_draft(
        monkeypatch,
        create_new_parent_draft(),
    )
    install_gateway_lists(monkeypatch)

    async def fake_save_owned_step(*args, **kwargs):
        raise DatabaseError("forced gateway persistence failure")

    monkeypatch.setattr(
        "src.main.save_owned_onboarding_draft_step",
        fake_save_owned_step,
    )

    response = portal_client.post(
        "/onboarding/gateway",
        data={
            "draft_token": str(DRAFT_TOKEN),
            "gateway_mode": "CREATE_NEW",
            "existing_gateway_id": "",
            "gateway_name": "Database Failure Gateway",
            "gateway_external_id": "DATABASE_FAILURE_GATEWAY",
            "gateway_vendor": "Eniscope",
            "gateway_model": "Eniscope Gateway",
            "gateway_protocol": "MQTT",
        },
    )

    assert response.status_code == 409
    assert (
        "The database rejected the onboarding draft."
        in response.text
    )
    assert "Database Failure Gateway" in response.text
    assert "DATABASE_FAILURE_GATEWAY" not in response.text
    assert 'name="gateway_external_id"' not in response.text
